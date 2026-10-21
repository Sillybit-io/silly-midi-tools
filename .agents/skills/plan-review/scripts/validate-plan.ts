#!/usr/bin/env bun
/**
 * validate-plan — structural and identity checks for plan-writer plans,
 * plan-review gate records, and plan-builder resume state.
 *
 * Bundled with the plan-review skill so an installed copy works without this
 * repository. Uses Bun/Node built-ins only. It never edits files, invokes a
 * model, fetches a URL, or runs a command taken from a plan. The only
 * subprocesses are fixed, read-only git commands.
 *
 * Usage:
 *   bun validate-plan.ts <plan> [--review [--resume]] [--root <project>] [--json]
 *
 * Exit codes: 0 — the requested record is structurally consistent (this is not
 * approval; read gateEligible or resumeEligible); 1 — invalid structure,
 * inconsistent evidence, or unexpected drift; 2 — invalid arguments or an
 * unreadable input, including a missing snapshot.
 *
 * The grammar is documented in ../references/validator-contract.md.
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readdirSync, readFileSync, readlinkSync, realpathSync } from "node:fs";
import { isAbsolute, join, resolve, sep } from "node:path";

export const SCHEMA_VERSION = 1;

export const FRONTMATTER_KEYS = [
  "title",
  "request",
  "source",
  "date",
  "status",
  "tier",
  "intent",
  "branch",
  "ui",
  "review",
  "review_round",
] as const;

export const SECTIONS = [
  "TL;DR",
  "Scope",
  "Research",
  "Questions",
  "Design",
  "Verification strategy",
  "Execution strategy",
  "Todos",
  "Final verification wave",
  "Success criteria",
  "Review",
] as const;

const TRAILING_SECTIONS = ["Build", "Result review"] as const;
const EXCLUDED_FROM_SPEC = new Set(["Review", "Build", "Result review"]);

export const SCOPE_SUBSECTIONS = [
  "Affected users",
  "Ideal state",
  "IS / GAP ledger",
  "Risks",
  "Must have",
  "Must NOT have",
  "Coverage",
  "Critical flows",
  "Baseline",
  "Evidence index",
] as const;

export const TODO_FIELDS = [
  "Do",
  "Must not",
  "Closes gap",
  "Depends on",
  "References",
  "Acceptance",
  "QA scenario",
  "Commit",
] as const;

export const CHECK_LETTERS = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"] as const;
const EVIDENCE_KINDS = ["source", "probe", "documentation", "plan-inspection", "planned-qa"] as const;
const OBLIGATION_STATUSES = ["verified", "contradicted", "unverified"] as const;
const VERDICTS = ["OKAY", "REJECT", "INCOMPLETE"] as const;
const RECEIPT_EVENTS = ["start", "checkpoint", "pass", "block", "recovery"] as const;

export type Verdict = (typeof VERDICTS)[number];
export type Mode = "plan" | "review" | "resume";

export type Finding = { code: string; file: string; line: number; message: string };

export type ValidationResult = {
  schemaVersion: 1;
  validationMode: Mode;
  plan: string;
  errors: Finding[];
  gaps: string[];
  planDigest: string | null;
  sourceDigests: Record<string, string | null>;
  expectedVerdict: Verdict | null;
  recordedVerdict: Verdict | null;
  gateRecordDigest: string | null;
  gateEligible: boolean;
  resumeEligible: boolean;
  nextTodo: string | null;
  activeTodo: string | null;
  recoveryRequired: boolean;
  unresolvedAction: string | null;
  requiredRechecks: { todo: string; paths: string[] }[];
  reconcileBoxes: string[];
  drift: string[];
  exitCode: 0 | 1 | 2;
};

/* ── small helpers ─────────────────────────────────────────────────────────── */

export function sha256(data: string | Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

/** JSON with recursively sorted keys and no whitespace. Matches Python's
 * json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False). */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = sortKeys((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

function byteCompare(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function strArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

class UnreadableInput extends Error {}
export class UnsupportedState extends Error {}

/* ── markdown scanning ─────────────────────────────────────────────────────── */

type Line = { text: string; no: number; fenced: boolean; fenceMarker: boolean; fenceInfo: string };

export function scanLines(text: string): Line[] {
  const raw = text.replace(/\r\n?/g, "\n").split("\n");
  if (raw.length > 0 && raw[raw.length - 1] === "") raw.pop();
  const lines: Line[] = [];
  let fenceChar = "";
  let fenceLen = 0;
  for (let i = 0; i < raw.length; i++) {
    const text_ = raw[i];
    const m = /^\s*(`{3,}|~{3,})(.*)$/.exec(text_);
    if (m) {
      if (fenceLen === 0) {
        fenceChar = m[1][0];
        fenceLen = m[1].length;
        lines.push({ text: text_, no: i + 1, fenced: false, fenceMarker: true, fenceInfo: m[2].trim() });
        continue;
      }
      if (m[1][0] === fenceChar && m[1].length >= fenceLen) {
        fenceLen = 0;
        lines.push({ text: text_, no: i + 1, fenced: false, fenceMarker: true, fenceInfo: "" });
        continue;
      }
    }
    lines.push({ text: text_, no: i + 1, fenced: fenceLen > 0, fenceMarker: false, fenceInfo: "" });
  }
  return lines;
}

/**
 * Canonical spec digest: excludes the frontmatter `status` and `review_round`
 * lines and the top-level Review, Build, and Result review sections, and
 * normalizes CRLF plus todo/gate checkbox progress. Headings inside code fences
 * never start or end a section.
 */
export function canonicalSpecDigest(text: string): string {
  const lines = scanLines(text);
  const out: string[] = [];
  let inFrontmatter = false;
  let skip = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === 0 && line.text.trimEnd() === "---") {
      inFrontmatter = true;
      out.push(line.text);
      continue;
    }
    if (inFrontmatter) {
      if (line.text.trimEnd() === "---") inFrontmatter = false;
      else if (/^(status|review_round):/.test(line.text)) continue;
      out.push(line.text);
      continue;
    }
    if (!line.fenced && !line.fenceMarker) {
      const h = /^## (.+?)\s*$/.exec(line.text);
      if (h) skip = EXCLUDED_FROM_SPEC.has(h[1]);
    }
    if (skip) continue;
    if (!line.fenced && !line.fenceMarker && /^- \[[ xX]\] (Open|Done)\s*$/.test(line.text)) {
      out.push("- [ ] Open");
      continue;
    }
    out.push(line.text);
  }
  return sha256(`${out.join("\n")}\n`);
}

type Section = { title: string; start: number; end: number; headingLine: number };

/** Headings of the given level outside fences, with [start, end) line indexes. */
function sectionsOf(lines: Line[], level: number, from = 0, to = lines.length): Section[] {
  const prefix = `${"#".repeat(level)} `;
  const out: Section[] = [];
  for (let i = from; i < to; i++) {
    const line = lines[i];
    if (line.fenced || line.fenceMarker) continue;
    if (!line.text.startsWith(prefix)) continue;
    if (out.length > 0) out[out.length - 1].end = i;
    out.push({ title: line.text.slice(prefix.length).trim(), start: i + 1, end: to, headingLine: line.no });
  }
  // A lower-level heading closes the section too.
  for (const section of out) {
    for (let i = section.start; i < section.end; i++) {
      const line = lines[i];
      if (line.fenced || line.fenceMarker) continue;
      const h = /^(#{1,6}) /.exec(line.text);
      if (h && h[1].length < level) {
        section.end = i;
        break;
      }
    }
  }
  return out;
}

function tableRows(lines: Line[], from: number, to: number): { cells: string[]; no: number }[] {
  const rows: { cells: string[]; no: number }[] = [];
  for (let i = from; i < to; i++) {
    const line = lines[i];
    if (line.fenced || line.fenceMarker) continue;
    const t = line.text.trim();
    if (!t.startsWith("|") || !t.endsWith("|")) continue;
    const inner = t.slice(1, -1);
    const cells: string[] = [];
    let cur = "";
    for (let j = 0; j < inner.length; j++) {
      if (inner[j] === "\\" && inner[j + 1] === "|") {
        cur += "|";
        j++;
      } else if (inner[j] === "|") {
        cells.push(cur.trim());
        cur = "";
      } else cur += inner[j];
    }
    cells.push(cur.trim());
    if (cells.every((c) => /^:?-{3,}:?$/.test(c))) continue;
    rows.push({ cells, no: line.no });
  }
  return rows;
}

function fencedJson(
  lines: Line[],
  from: number,
  to: number,
): { value: unknown; no: number; raw: string } | { error: string; no: number } | null {
  for (let i = from; i < to; i++) {
    const line = lines[i];
    if (!line.fenceMarker || line.fenceInfo !== "json") continue;
    const body: string[] = [];
    let j = i + 1;
    for (; j < to && !lines[j].fenceMarker; j++) body.push(lines[j].text);
    const raw = body.join("\n");
    try {
      return { value: JSON.parse(raw), no: line.no, raw };
    } catch (error) {
      return { error: (error as Error).message, no: line.no };
    }
  }
  return null;
}

/** Merges every fenced json block in the range into one object, so a writer can
 * append one small block per entry. Arrays concatenate, nested objects merge one
 * level deep, and any other later value replaces an earlier one. A single block
 * is returned as it is. */
function fencedJsonBlocks(
  lines: Line[],
  from: number,
  to: number,
): { value: unknown; no: number } | { error: string; no: number } | null {
  const blocks: unknown[] = [];
  let first = 0;
  for (let i = from; i < to; i++) {
    const line = lines[i];
    if (!line.fenceMarker || line.fenceInfo !== "json") continue;
    const found = fencedJson(lines, i, to);
    if (found === null) break;
    if ("error" in found) return found;
    if (blocks.length === 0) first = found.no;
    blocks.push(found.value);
    const close = lines.findIndex((l, k) => k > i && l.fenceMarker && k < to);
    if (close < 0) break;
    i = close;
  }
  if (blocks.length === 0) return null;
  if (blocks.length === 1) return { value: blocks[0], no: first };
  const merged: Record<string, unknown> = {};
  for (const block of blocks) {
    if (!isObject(block)) return { error: "every Evidence index block must be a JSON object", no: first };
    for (const [key, next] of Object.entries(block)) {
      const prev = merged[key];
      if (Array.isArray(prev) && Array.isArray(next)) merged[key] = [...prev, ...next];
      else if (isObject(prev) && isObject(next)) {
        const inner: Record<string, unknown> = { ...prev };
        for (const [k, v] of Object.entries(next)) {
          inner[k] = Array.isArray(inner[k]) && Array.isArray(v) ? [...(inner[k] as unknown[]), ...v] : v;
        }
        merged[key] = inner;
      } else merged[key] = next;
    }
  }
  return { value: merged, no: first };
}

/* ── plan model ────────────────────────────────────────────────────────────── */

export type Todo = {
  id: string;
  title: string;
  line: number;
  box: "Open" | "Done" | null;
  fields: Record<string, string>;
  closes: string[];
  dependsOn: string[];
  references: string[];
  commit: boolean;
};

export type ParsedPlan = {
  text: string;
  lines: Line[];
  frontmatter: Record<string, string>;
  frontmatterLine: Record<string, number>;
  frontmatterEnd: number;
  sections: Section[];
  todos: Todo[];
  finals: { id: string; line: number; box: "Open" | "Done" | null }[];
  waves: { wave: number; todos: string[]; line: number }[];
  gaps: { id: string; line: number }[];
  mustHave: { id: string; line: number }[];
  mustNotHave: { id: string; line: number }[];
  success: { gaps: string[]; todos: string[]; line: number }[];
  evidenceIndex: { value: unknown; no: number } | { error: string; no: number } | null;
  citations: { path: string; start: number; end: number; line: number }[];
};

function section(plan: ParsedPlan, title: string): Section | undefined {
  return plan.sections.find((s) => s.title === title);
}

export function parsePlan(text: string): ParsedPlan {
  const lines = scanLines(text);
  const frontmatter: Record<string, string> = {};
  const frontmatterLine: Record<string, number> = {};
  let frontmatterEnd = 0;
  if (lines[0]?.text.trimEnd() === "---") {
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].text.trimEnd() === "---") {
        frontmatterEnd = i + 1;
        break;
      }
      const m = /^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/.exec(lines[i].text);
      if (m) {
        let value = m[2].trim();
        if (value.length >= 2 && ((value[0] === '"' && value.endsWith('"')) || (value[0] === "'" && value.endsWith("'")))) {
          value = value.slice(1, -1);
        }
        if (m[1] in frontmatter) frontmatterLine[`duplicate:${m[1]}`] = i + 1;
        frontmatter[m[1]] = value;
        frontmatterLine[m[1]] = i + 1;
      }
    }
  }
  const sections = sectionsOf(lines, 2, frontmatterEnd);

  const plan: ParsedPlan = {
    text,
    lines,
    frontmatter,
    frontmatterLine,
    frontmatterEnd,
    sections,
    todos: [],
    finals: [],
    waves: [],
    gaps: [],
    mustHave: [],
    mustNotHave: [],
    success: [],
    evidenceIndex: null,
    citations: [],
  };

  const scope = section(plan, "Scope");
  if (scope) {
    const subs = sectionsOf(lines, 3, scope.start, scope.end);
    const ledger = subs.find((s) => s.title === "IS / GAP ledger");
    if (ledger) {
      for (const row of tableRows(lines, ledger.start, ledger.end)) {
        const m = /^G\d+$/.exec(row.cells[0] ?? "");
        if (m) plan.gaps.push({ id: m[0], line: row.no });
      }
    }
    const ids = (title: string, prefix: string) => {
      const sub = subs.find((s) => s.title === title);
      const out: { id: string; line: number }[] = [];
      if (!sub) return out;
      for (let i = sub.start; i < sub.end; i++) {
        const line = lines[i];
        if (line.fenced || line.fenceMarker || !line.text.startsWith("- ")) continue;
        const m = new RegExp(`^- (${prefix}\\d+)(?::| —)`).exec(line.text);
        out.push({ id: m ? m[1] : "", line: line.no });
      }
      return out;
    };
    plan.mustHave = ids("Must have", "MH");
    plan.mustNotHave = ids("Must NOT have", "MN");
    const index = subs.find((s) => s.title === "Evidence index");
    if (index) plan.evidenceIndex = fencedJsonBlocks(lines, index.start, index.end);
  }

  const todos = section(plan, "Todos");
  if (todos) {
    for (const sub of sectionsOf(lines, 3, todos.start, todos.end)) {
      const m = /^(T\d+) — (.+)$/.exec(sub.title);
      if (!m) continue;
      const todo: Todo = {
        id: m[1],
        title: m[2],
        line: sub.headingLine,
        box: null,
        fields: {},
        closes: [],
        dependsOn: [],
        references: [],
        commit: false,
      };
      let first = true;
      for (let i = sub.start; i < sub.end; i++) {
        const line = lines[i];
        if (line.fenced || line.fenceMarker || line.text.trim() === "") continue;
        if (first) {
          first = false;
          const box = /^- \[( |x)\] (Open|Done)$/.exec(line.text.trimEnd());
          if (box) {
            todo.box = box[1] === "x" && box[2] === "Done" ? "Done" : box[1] === " " && box[2] === "Open" ? "Open" : null;
            continue;
          }
        }
        const f = /^- ([A-Za-z][A-Za-z ]*?): (.*)$/.exec(line.text);
        if (f && (TODO_FIELDS as readonly string[]).includes(f[1])) todo.fields[f[1]] = f[2].trim();
      }
      const closes = todo.fields["Closes gap"] ?? "";
      todo.closes = /^none\.?$/i.test(closes) ? [] : closes.match(/\bG\d+\b/g) ?? [];
      const deps = todo.fields["Depends on"] ?? "";
      todo.dependsOn = /^none\.?$/i.test(deps) ? [] : deps.match(/\bT\d+\b/g) ?? [];
      todo.commit = /^yes\b/i.test(todo.fields.Commit ?? "");
      todo.references = [...(todo.fields.References ?? "").matchAll(/`([^`]+)`/g)].map((r) => r[1]);
      plan.todos.push(todo);
    }
  }

  const finals = section(plan, "Final verification wave");
  if (finals) {
    for (const sub of sectionsOf(lines, 3, finals.start, finals.end)) {
      const m = /^(F\d+) — /.exec(sub.title);
      if (!m) continue;
      let box: "Open" | "Done" | null = null;
      for (let i = sub.start; i < sub.end; i++) {
        if (lines[i].text.trim() === "") continue;
        const b = /^- \[( |x)\] (Open|Done)$/.exec(lines[i].text.trimEnd());
        if (b) box = b[2] as "Open" | "Done";
        break;
      }
      plan.finals.push({ id: m[1], line: sub.headingLine, box });
    }
  }

  const execution = section(plan, "Execution strategy");
  if (execution) {
    for (let i = execution.start; i < execution.end; i++) {
      const line = lines[i];
      if (line.fenced || line.fenceMarker) continue;
      const m = /^- Wave (\d+): (.+)$/.exec(line.text);
      if (!m) continue;
      const head = m[2].split(/\s+[—(]/)[0];
      plan.waves.push({ wave: Number(m[1]), todos: head.match(/\bT\d+\b/g) ?? [], line: line.no });
    }
  }

  const success = section(plan, "Success criteria");
  if (success) {
    for (const row of tableRows(lines, success.start, success.end)) {
      const gaps = row.cells[0]?.match(/\bG\d+\b/g) ?? [];
      if (gaps.length === 0) continue;
      plan.success.push({ gaps, todos: row.cells[1]?.match(/\bT\d+\b/g) ?? [], line: row.no });
    }
  }

  // Backticked `path:line[-line]` citations in the spec, outside fences and
  // outside the Review, Build, and Result review sections.
  for (const s of sections) {
    if (EXCLUDED_FROM_SPEC.has(s.title)) continue;
    for (let i = s.start - 1; i < s.end; i++) {
      const line = lines[i];
      if (!line || line.fenced || line.fenceMarker) continue;
      let last = "";
      for (const token of line.text.matchAll(/`([^`]+)`/g)) {
        const full = /^([^\s:`]+):(\d+)(?:-(\d+))?$/.exec(token[1]);
        const short = /^:(\d+)(?:-(\d+))?$/.exec(token[1]);
        if (full && /[./]/.test(full[1]) && !/^[a-z]+:\/\//i.test(token[1])) {
          last = full[1];
          plan.citations.push({ path: full[1], start: Number(full[2]), end: Number(full[3] ?? full[2]), line: line.no });
        } else if (short && last) {
          plan.citations.push({ path: last, start: Number(short[1]), end: Number(short[2] ?? short[1]), line: line.no });
        }
      }
    }
  }
  return plan;
}

/* ── path safety and file access ───────────────────────────────────────────── */

/** Resolves a repository-relative path, rejecting traversal and symlink escape. */
export function safeResolve(root: string, rel: string): { abs: string } | { error: string } {
  if (rel === "" || rel.includes("\0")) return { error: "empty or NUL path" };
  if (isAbsolute(rel) || /^[A-Za-z]:[\\/]/.test(rel)) return { error: `absolute path '${rel}'` };
  if (rel.split(/[\\/]/).some((part) => part === "..")) return { error: `path '${rel}' traverses outside the project` };
  const abs = resolve(root, rel);
  if (existsSync(abs)) {
    let realRoot: string;
    let realAbs: string;
    try {
      realRoot = realpathSync(root);
      realAbs = realpathSync(abs);
    } catch {
      return { error: `path '${rel}' is unreadable` };
    }
    if (realAbs !== realRoot && !realAbs.startsWith(realRoot + sep)) {
      return { error: `path '${rel}' resolves outside the project through a symlink` };
    }
  }
  return { abs };
}

function readBytes(abs: string): Buffer | null {
  try {
    return readFileSync(abs);
  } catch {
    return null;
  }
}

function excerptMatches(content: string, start: number, end: number, excerpt: string): boolean {
  const lines = content.replace(/\r\n?/g, "\n").split("\n");
  if (start < 1 || end < start || end > lines.length) return false;
  return lines.slice(start - 1, end).join("\n").trim() === excerpt.replace(/\r\n?/g, "\n").trim();
}

function lineCount(content: string): number {
  const lines = content.replace(/\r\n?/g, "\n").split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines.length;
}

/* ── build-state inventory (D4) ────────────────────────────────────────────── */

export type Layer =
  | { state: "absent" }
  | { state: "unavailable" }
  | { state: "file" | "symlink"; mode: string; length: number; sha256: string };

export type PathRow = { path: string; head: Layer; index: Layer; worktree: Layer };
export type StateBody = { headRevision: string | null; paths: PathRow[] };

function git(root: string, args: string[], input?: string): { code: number; out: Buffer; err: string } {
  const p = spawnSync("git", args, {
    cwd: root,
    input,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_CONFIG_NOSYSTEM: "1" },
    maxBuffer: 1024 * 1024 * 1024,
  });
  return { code: p.status ?? 1, out: p.stdout ?? Buffer.alloc(0), err: p.stderr?.toString() ?? "" };
}

export function isGitRoot(root: string): boolean {
  const p = git(root, ["rev-parse", "--show-toplevel"]);
  if (p.code !== 0) return false;
  try {
    return realpathSync(p.out.toString().trim()) === realpathSync(root);
  } catch {
    return false;
  }
}

function splitNul(buf: Buffer): Buffer[] {
  const out: Buffer[] = [];
  let start = 0;
  for (let i = 0; i < buf.length; i++) {
    if (buf[i] === 0) {
      if (i > start) out.push(buf.subarray(start, i));
      start = i + 1;
    }
  }
  if (start < buf.length) out.push(buf.subarray(start));
  return out;
}

function walkInclude(root: string, rel: string, found: Set<string>): void {
  const abs = join(root, rel);
  let st;
  try {
    st = lstatSync(abs);
  } catch {
    found.add(rel);
    return;
  }
  if (!st.isDirectory()) {
    found.add(rel);
    return;
  }
  for (const entry of readdirSync(abs, { withFileTypes: true })) {
    const child = `${rel}/${entry.name}`;
    if (entry.isDirectory()) walkInclude(root, child, found);
    else found.add(child);
  }
}

function walkAll(root: string, rel: string, found: Set<string>): void {
  const abs = rel === "" ? root : join(root, rel);
  for (const entry of readdirSync(abs, { withFileTypes: true })) {
    if (rel === "" && entry.name === ".git") continue;
    const child = rel === "" ? entry.name : `${rel}/${entry.name}`;
    if (entry.isDirectory()) walkAll(root, child, found);
    else found.add(child);
  }
}

/**
 * Reads HEAD, index, and working-tree layers for the union of tracked, staged,
 * non-ignored untracked, carried, and explicitly included paths. Read-only:
 * uses `git ls-tree`, `git ls-files`, and `git cat-file --batch`, which apply
 * no filters or text conversion.
 */
export function inventoryState(
  root: string,
  options: { carry?: string[]; include?: string[] } = {},
): { body: StateBody; blobs: Map<string, Buffer>; git: boolean } {
  const blobs = new Map<string, Buffer>();
  const put = (data: Buffer, mode: string): Layer => {
    const digest = sha256(data);
    blobs.set(digest, data);
    return { state: mode === "120000" ? "symlink" : "file", mode, length: data.length, sha256: digest };
  };
  const inGit = isGitRoot(root);
  const head = new Map<string, [string, string]>();
  const index = new Map<string, [string, string]>();
  const extra = new Set<string>(options.carry ?? []);
  let headRevision: string | null = null;
  const objects = new Map<string, Buffer>();

  if (inGit) {
    const rev = git(root, ["rev-parse", "--verify", "-q", "HEAD"]);
    headRevision = rev.code === 0 ? rev.out.toString().trim() : null;
    if (headRevision) {
      for (const row of splitNul(git(root, ["ls-tree", "-r", "-z", "--full-tree", "HEAD"]).out)) {
        const tab = row.indexOf(9);
        const [mode, kind, oid] = row.subarray(0, tab).toString().split(" ");
        const path = row.subarray(tab + 1).toString("utf8");
        if (kind !== "blob") throw new UnsupportedState(`HEAD entry ${path} is a ${kind}; submodules are unsupported`);
        head.set(path, [mode, oid]);
        objects.set(oid, Buffer.alloc(0));
      }
    }
    for (const row of splitNul(git(root, ["ls-files", "--stage", "-z"]).out)) {
      const tab = row.indexOf(9);
      const [mode, oid, stage] = row.subarray(0, tab).toString().split(" ");
      const path = row.subarray(tab + 1).toString("utf8");
      if (stage !== "0") throw new UnsupportedState(`index entry ${path} is unmerged (stage ${stage})`);
      if (mode === "160000") throw new UnsupportedState(`index entry ${path} is a submodule`);
      index.set(path, [mode, oid]);
      objects.set(oid, Buffer.alloc(0));
    }
    if (objects.size > 0) {
      const oids = [...objects.keys()];
      const batch = git(root, ["cat-file", "--batch"], `${oids.join("\n")}\n`).out;
      let pos = 0;
      for (const oid of oids) {
        const nl = batch.indexOf(10, pos);
        const header = batch.subarray(pos, nl).toString().split(" ");
        if (header.length !== 3 || header[0] !== oid || header[1] !== "blob") {
          throw new Error(`git cat-file returned an unexpected header for ${oid}`);
        }
        const size = Number(header[2]);
        objects.set(oid, Buffer.from(batch.subarray(nl + 1, nl + 1 + size)));
        pos = nl + 1 + size + 1;
      }
    }
    for (const p of splitNul(git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).out)) {
      extra.add(p.toString("utf8"));
    }
  } else {
    walkAll(root, "", extra);
  }
  for (const inc of options.include ?? []) walkInclude(root, inc, extra);

  const all = new Set<string>([...head.keys(), ...index.keys(), ...extra]);
  const paths = [...all].sort(byteCompare);
  const rows: PathRow[] = [];
  for (const path of paths) {
    const parts = path.split("/");
    if (isAbsolute(path) || parts.includes("..") || parts[0] === ".git") {
      throw new UnsupportedState(`path escapes the project or enters .git: ${path}`);
    }
    const abs = join(root, path);
    let worktree: Layer;
    let st;
    try {
      st = lstatSync(abs);
    } catch {
      st = null;
    }
    if (st === null) worktree = { state: "absent" };
    else if (st.isSymbolicLink()) worktree = put(Buffer.from(readlinkSync(abs, { encoding: "buffer" })), "120000");
    else if (st.isFile()) worktree = put(readFileSync(abs), st.mode & 0o111 ? "100755" : "100644");
    else if (st.isDirectory()) throw new UnsupportedState(`${path} is a directory where a file entry is recorded`);
    else throw new UnsupportedState(`${path} is not a regular file or symlink`);
    const layer = (map: Map<string, [string, string]>): Layer => {
      if (!inGit) return { state: "unavailable" };
      const entry = map.get(path);
      return entry ? put(objects.get(entry[1]) as Buffer, entry[0]) : { state: "absent" };
    };
    rows.push({ path, head: layer(head), index: layer(index), worktree });
  }
  return { body: { headRevision, paths: rows }, blobs, git: inGit };
}

/**
 * State identity used for receipt-chain equality. The plan's working-tree
 * bytes are replaced by its canonical spec digest, and declared report
 * payloads are excluded, so progress and report appends are not drift.
 */
export function stateDigest(
  body: StateBody,
  planRel: string,
  readBlob: (digest: string) => Buffer,
  reports: string[] = [],
): string {
  const skip = new Set(reports);
  const entries: unknown[] = [];
  for (const row of body.paths) {
    if (skip.has(row.path)) continue;
    if (row.path === planRel && row.worktree.state === "file") {
      const spec = canonicalSpecDigest(readBlob(row.worktree.sha256).toString("utf8"));
      entries.push({ ...row, worktree: { state: "plan", specDigest: spec } });
    } else entries.push(row);
  }
  return sha256(canonicalJson({ headRevision: body.headRevision, paths: entries }));
}

export type Manifest = {
  schemaVersion: number;
  kind: string;
  runId: string;
  repository: unknown;
  baseRevision: string | null;
  headRevision: string | null;
  approvedSpecDigest: string;
  plan: { path: string; sha256: string; specDigest: string };
  administrative: { plan: string; reports: string[] };
  includes?: string[];
  stateDigest: string;
  paths: PathRow[];
};

/** Reads and fully verifies a snapshot directory. Throws UnreadableInput when
 * it is missing and Error when it is corrupt. */
export function verifySnapshot(dir: string): { manifest: Manifest; manifestSha256: string } {
  const raw = readBytes(join(dir, "manifest.json"));
  if (raw === null) throw new UnreadableInput(`snapshot manifest is missing: ${dir}`);
  let manifest: Manifest;
  try {
    manifest = JSON.parse(raw.toString("utf8"));
  } catch {
    throw new Error("snapshot manifest is not valid JSON");
  }
  if (manifest.schemaVersion !== 1 || manifest.kind !== "silly-skills.build-state" || !Array.isArray(manifest.paths)) {
    throw new Error("snapshot manifest has an unknown schema");
  }
  const cache = new Map<string, Buffer>();
  const readBlob = (digest: string): Buffer => {
    if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error(`invalid object name ${digest}`);
    const cached = cache.get(digest);
    if (cached) return cached;
    const data = readBytes(join(dir, "objects", digest));
    if (data === null) throw new Error(`snapshot object ${digest} is missing`);
    if (sha256(data) !== digest) throw new Error(`snapshot object ${digest} is corrupt`);
    cache.set(digest, data);
    return data;
  };
  for (const row of manifest.paths) {
    for (const layer of [row.head, row.index, row.worktree]) {
      if (layer.state === "file" || layer.state === "symlink") {
        const data = readBlob(layer.sha256);
        if (data.length !== layer.length) throw new Error(`snapshot object for ${row.path} has the wrong length`);
      }
    }
  }
  const recomputed = stateDigest(manifest, manifest.administrative?.plan ?? "", readBlob, manifest.administrative?.reports ?? []);
  if (recomputed !== manifest.stateDigest) throw new Error("snapshot stateDigest does not match its paths");
  return { manifest, manifestSha256: sha256(raw) };
}

export function readSnapshotBlob(dir: string, digest: string): Buffer {
  const data = readFileSync(join(dir, "objects", digest));
  if (sha256(data) !== digest) throw new Error(`snapshot object ${digest} is corrupt`);
  return data;
}

/** Resolves a snapshot location recorded in a Build record. */
export function resolveSnapshot(root: string, location: string, inGit: boolean): string {
  if (isAbsolute(location)) return location;
  if (inGit) {
    const p = git(root, ["rev-parse", "--git-path", location]);
    if (p.code === 0) return resolve(root, p.out.toString().trim());
  }
  return resolve(root, location);
}

function layerEqual(a: Layer | undefined, b: Layer | undefined): boolean {
  return canonicalJson(a ?? { state: "absent" }) === canonicalJson(b ?? { state: "absent" });
}

export function diffStates(a: StateBody, b: StateBody, ignore: string[] = []): string[] {
  const ra = new Map(a.paths.map((r) => [r.path, r]));
  const rb = new Map(b.paths.map((r) => [r.path, r]));
  const skip = new Set(ignore);
  const out: string[] = [];
  if (a.headRevision !== b.headRevision) out.push(`HEAD ${a.headRevision ?? "none"} → ${b.headRevision ?? "none"}`);
  for (const path of [...new Set([...ra.keys(), ...rb.keys()])].sort(byteCompare)) {
    if (skip.has(path)) continue;
    for (const layer of ["head", "index", "worktree"] as const) {
      if (!layerEqual(ra.get(path)?.[layer], rb.get(path)?.[layer])) out.push(`${path} [${layer}]`);
    }
  }
  return out;
}

/* ── validation ────────────────────────────────────────────────────────────── */

type Context = {
  file: string;
  root: string;
  errors: Finding[];
  gaps: string[];
};

function err(ctx: Context, code: string, line: number, message: string): void {
  ctx.errors.push({ code, file: ctx.file, line, message });
}

function validateStructure(ctx: Context, plan: ParsedPlan): void {
  const fm = plan.frontmatter;
  if (plan.frontmatterEnd === 0) {
    err(ctx, "FRONTMATTER", 1, "plan must start with a '---' frontmatter block");
    return;
  }
  for (const key of Object.keys(plan.frontmatterLine)) {
    if (key.startsWith("duplicate:")) err(ctx, "FRONTMATTER", plan.frontmatterLine[key], `duplicate key '${key.slice(10)}'`);
  }
  for (const key of FRONTMATTER_KEYS) {
    if (!(key in fm)) err(ctx, "FRONTMATTER", 1, `missing frontmatter key '${key}'`);
  }
  for (const key of Object.keys(fm)) {
    if (!(FRONTMATTER_KEYS as readonly string[]).includes(key)) {
      err(ctx, "FRONTMATTER", plan.frontmatterLine[key], `unknown frontmatter key '${key}'`);
    }
  }
  const enums: Record<string, RegExp> = {
    source: /^(chat|ticket:\S+)$/,
    date: /^\d{4}-\d{2}-\d{2}$/,
    status: /^(draft|planned|reviewed)$/,
    tier: /^(standard|architecture)$/,
    intent: /^(refactor|build|change|architecture|research)$/,
    ui: /^(yes|no)$/,
    review: /^(required|optional)$/,
    review_round: /^\d+$/,
  };
  for (const [key, re] of Object.entries(enums)) {
    if (key in fm && !re.test(fm[key])) err(ctx, "FRONTMATTER", plan.frontmatterLine[key], `invalid value '${fm[key]}' for '${key}'`);
  }

  const titles = plan.sections.map((s) => s.title);
  const expected = [...SECTIONS];
  let at = 0;
  for (const s of plan.sections) {
    if ((TRAILING_SECTIONS as readonly string[]).includes(s.title)) continue;
    if (!(SECTIONS as readonly string[]).includes(s.title)) {
      err(ctx, "SECTION", s.headingLine, `unknown top-level section '${s.title}'`);
      continue;
    }
    const idx = expected.indexOf(s.title as (typeof SECTIONS)[number]);
    if (idx < at) err(ctx, "SECTION", s.headingLine, `section '${s.title}' is out of order`);
    at = Math.max(at, idx + 1);
  }
  for (const title of SECTIONS) {
    if (!titles.includes(title)) err(ctx, "SECTION", 1, `missing section '## ${title}'`);
    else if (titles.filter((t) => t === title).length > 1) err(ctx, "SECTION", 1, `section '## ${title}' appears more than once`);
  }

  const scope = section(plan, "Scope");
  if (scope) {
    const subs = sectionsOf(plan.lines, 3, scope.start, scope.end).map((s) => s.title);
    for (const title of SCOPE_SUBSECTIONS) {
      if (!subs.includes(title)) err(ctx, "SECTION", scope.headingLine, `Scope is missing '### ${title}'`);
    }
  }
  const status = fm.status;
  const seen = new Set<string>();
  for (const [list, prefix] of [
    [plan.mustHave, "MH"],
    [plan.mustNotHave, "MN"],
  ] as const) {
    for (const item of list) {
      if (item.id === "") err(ctx, "REQUIREMENT_ID", item.line, `bullet has no ${prefix}<n> identifier`);
      else if (seen.has(item.id)) err(ctx, "REQUIREMENT_ID", item.line, `duplicate identifier ${item.id}`);
      seen.add(item.id);
    }
  }
  const gapIds = new Set<string>();
  for (const gap of plan.gaps) {
    if (gapIds.has(gap.id)) err(ctx, "GAP_MAP", gap.line, `duplicate gap ${gap.id}`);
    gapIds.add(gap.id);
  }

  const questions = section(plan, "Questions");
  if (questions) {
    const subs = sectionsOf(plan.lines, 3, questions.start, questions.end);
    const product = subs.findIndex((s) => s.title === "Product");
    const technical = subs.findIndex((s) => s.title === "Technical");
    if (product === -1 || technical === -1 || product > technical) {
      err(ctx, "QUESTIONS", questions.headingLine, "Questions needs '### Product' before '### Technical'");
    }
    for (const sub of subs.filter((s) => s.title === "Product" || s.title === "Technical")) {
      const bullets = plan.lines.slice(sub.start, sub.end).filter((l) => !l.fenced && l.text.startsWith("- "));
      if (bullets.length === 0) err(ctx, "QUESTIONS", sub.headingLine, `'### ${sub.title}' is empty`);
    }
  }

  if (status === "draft") return;

  for (const line of plan.lines) {
    if (!line.fenced && !line.fenceMarker && /^<!-- todo: .* -->\s*$/.test(line.text)) {
      err(ctx, "PLACEHOLDER", line.no, "a skeleton placeholder is still in the plan; fill the slot or remove the line");
    }
  }

  const design = section(plan, "Design");
  if (design) {
    const body = plan.lines.slice(design.start, design.end);
    const mermaidStart = body.findIndex((l) => l.fenceMarker && l.fenceInfo === "mermaid");
    const omitted = body.some((l) => !l.fenced && l.text.startsWith("Diagram: omitted —"));
    if (mermaidStart !== -1) {
      const firstCode = body.slice(mermaidStart + 1).find((l) => l.text.trim() !== "");
      if (!firstCode || !/^\s*(flowchart|sequenceDiagram|stateDiagram)/.test(firstCode.text)) {
        err(ctx, "DESIGN", design.headingLine, "mermaid diagram must start with flowchart, sequenceDiagram, or stateDiagram");
      }
    } else if (!omitted) {
      err(ctx, "DESIGN", design.headingLine, "Design needs a mermaid block or 'Diagram: omitted — <reason>'");
    }
  }

  // Todos.
  const todoIds = new Set<string>();
  if (plan.todos.length === 0) err(ctx, "TODO", section(plan, "Todos")?.headingLine ?? 1, "no todos found");
  if (plan.todos.length > 0 && plan.todos[0].id !== "T0") err(ctx, "TODO", plan.todos[0].line, "T0 must be the first todo");
  for (const todo of plan.todos) {
    if (todoIds.has(todo.id)) err(ctx, "TODO", todo.line, `duplicate todo ${todo.id}`);
    todoIds.add(todo.id);
    if (todo.box === null) err(ctx, "TODO", todo.line, `${todo.id} must start with '- [ ] Open' or '- [x] Done'`);
    for (const field of TODO_FIELDS) {
      if (!todo.fields[field]) err(ctx, "TODO", todo.line, `${todo.id} is missing '- ${field}:'`);
    }
    for (const gap of todo.closes) {
      if (!gapIds.has(gap)) err(ctx, "GAP_MAP", todo.line, `${todo.id} closes unknown gap ${gap}`);
    }
    if (todo.id !== "T0" && todo.closes.length === 0) err(ctx, "GAP_MAP", todo.line, `${todo.id} closes no gap`);
  }
  for (const gap of gapIds) {
    if (!plan.todos.some((t) => t.id !== "T0" && t.closes.includes(gap))) {
      err(ctx, "GAP_MAP", plan.gaps.find((g) => g.id === gap)?.line ?? 1, `gap ${gap} is not closed by any todo`);
    }
  }
  for (const todo of plan.todos) {
    for (const dep of todo.dependsOn) {
      if (!todoIds.has(dep)) err(ctx, "DEPENDENCY", todo.line, `${todo.id} depends on missing producer ${dep}`);
      if (dep === todo.id) err(ctx, "DEPENDENCY", todo.line, `${todo.id} depends on itself`);
    }
  }
  const cycle = findCycle(plan.todos);
  if (cycle) err(ctx, "DEPENDENCY", 1, `dependency cycle: ${cycle.join(" → ")}`);

  // Waves.
  const waveOf = new Map<string, number>([["T0", 0]]);
  let lastWave = 0;
  for (const wave of plan.waves) {
    if (wave.wave !== lastWave + 1) err(ctx, "WAVE", wave.line, `Wave ${wave.wave} is out of sequence`);
    lastWave = wave.wave;
    for (const id of wave.todos) {
      if (id === "T0") err(ctx, "WAVE", wave.line, "T0 runs alone before wave 1");
      else if (waveOf.has(id)) err(ctx, "WAVE", wave.line, `${id} appears in more than one wave`);
      else if (!todoIds.has(id)) err(ctx, "WAVE", wave.line, `wave lists unknown todo ${id}`);
      waveOf.set(id, wave.wave);
    }
  }
  for (const todo of plan.todos) {
    if (!waveOf.has(todo.id)) {
      err(ctx, "WAVE", todo.line, `${todo.id} is not placed in any wave`);
      continue;
    }
    for (const dep of todo.dependsOn) {
      const a = waveOf.get(todo.id) as number;
      const b = waveOf.get(dep);
      if (b === undefined) continue;
      if (b === a) err(ctx, "WAVE", todo.line, `${todo.id} depends on ${dep} in the same wave`);
      else if (b > a) err(ctx, "WAVE", todo.line, `${todo.id} depends on ${dep}, which runs in a later wave`);
    }
  }

  // Final wave.
  const finalIds = plan.finals.map((f) => f.id);
  for (const [i, id] of ["F1", "F2", "F3", "F4"].entries()) {
    if (finalIds[i] !== id) {
      err(ctx, "FINAL_WAVE", section(plan, "Final verification wave")?.headingLine ?? 1, `final wave must list F1–F4 in order; expected ${id} at position ${i + 1}`);
      break;
    }
  }
  for (const final of plan.finals) {
    if (final.box === null) err(ctx, "FINAL_WAVE", final.line, `${final.id} must start with '- [ ] Open' or '- [x] Done'`);
  }
  if (fm.ui === "yes") {
    const finals = section(plan, "Final verification wave");
    const subs = finals ? sectionsOf(plan.lines, 3, finals.start, finals.end) : [];
    if (subs.length === 0 || subs[subs.length - 1].title !== "Automated UI QA") {
      err(ctx, "FINAL_WAVE", finals?.headingLine ?? 1, "ui: yes requires '### Automated UI QA' as the last gate");
    }
  }

  // Success criteria map.
  const listed = new Set<string>();
  for (const row of plan.success) {
    for (const gap of row.gaps) {
      listed.add(gap);
      if (!gapIds.has(gap)) err(ctx, "SUCCESS_MAP", row.line, `success row names unknown gap ${gap}`);
      for (const id of row.todos) {
        const todo = plan.todos.find((t) => t.id === id);
        if (!todo) err(ctx, "SUCCESS_MAP", row.line, `success row names unknown todo ${id}`);
      }
      if (row.todos.length > 0 && !row.todos.some((id) => plan.todos.find((t) => t.id === id)?.closes.includes(gap))) {
        err(ctx, "SUCCESS_MAP", row.line, `none of ${row.todos.join(", ")} closes ${gap}`);
      }
    }
  }
  for (const gap of gapIds) {
    if (!listed.has(gap)) err(ctx, "SUCCESS_MAP", section(plan, "Success criteria")?.headingLine ?? 1, `gap ${gap} has no success criteria row`);
  }
}

function findCycle(todos: Todo[]): string[] | null {
  const deps = new Map(todos.map((t) => [t.id, t.dependsOn]));
  const state = new Map<string, number>();
  const stack: string[] = [];
  const visit = (id: string): string[] | null => {
    if (state.get(id) === 2) return null;
    if (state.get(id) === 1) return [...stack.slice(stack.indexOf(id)), id];
    state.set(id, 1);
    stack.push(id);
    for (const dep of deps.get(id) ?? []) {
      if (!deps.has(dep)) continue;
      const found = visit(dep);
      if (found) return found;
    }
    stack.pop();
    state.set(id, 2);
    return null;
  };
  for (const todo of todos) {
    const found = visit(todo.id);
    if (found) return found;
  }
  return null;
}

type Citation = Record<string, unknown> & { id: string; kind: string };

type SourceReader = (path: string) => Buffer | null;

/** Checks the Evidence index. `reader` supplies the bytes the citations must
 * match: the current files, or the baseline snapshot on resume. */
function validateEvidenceIndex(
  ctx: Context,
  plan: ParsedPlan,
  reader: SourceReader,
  options: { planned: "strict" | "lenient" },
): Map<string, Citation> {
  const citations = new Map<string, Citation>();
  const index = plan.evidenceIndex;
  const status = plan.frontmatter.status;
  if (index === null) {
    err(ctx, "LEGACY_FORMAT", 1, "no fenced json under '### Evidence index'; upgrade the plan with plan-writer 0.5.0 and review it again");
    return citations;
  }
  if ("error" in index) {
    err(ctx, "EVIDENCE_INDEX", index.no, `Evidence index is not valid JSON: ${index.error}`);
    return citations;
  }
  const value = index.value;
  const line = index.no;
  if (!isObject(value)) {
    err(ctx, "EVIDENCE_INDEX", line, "Evidence index must be a JSON object");
    return citations;
  }
  if (value.schemaVersion !== SCHEMA_VERSION) {
    err(ctx, "EVIDENCE_INDEX", line, `unknown Evidence index schemaVersion ${String(value.schemaVersion)}`);
    return citations;
  }
  for (const key of ["citations", "coverage", "frontier", "flows", "baseline"]) {
    if (!(key in value)) err(ctx, "EVIDENCE_INDEX", line, `Evidence index is missing '${key}'`);
  }
  const todoIds = new Set(plan.todos.map((t) => t.id));
  const requirementIds = new Set([...plan.mustHave, ...plan.mustNotHave].map((r) => r.id));
  for (const raw of Array.isArray(value.citations) ? value.citations : []) {
    if (!isObject(raw) || typeof raw.id !== "string" || typeof raw.kind !== "string") {
      err(ctx, "CITATION", line, "each citation needs a string id and kind");
      continue;
    }
    const c = raw as Citation;
    if (citations.has(c.id)) err(ctx, "CITATION", line, `duplicate citation id ${c.id}`);
    citations.set(c.id, c);
    if (c.kind === "source") {
      const path = str(c.path);
      const start = Number(c.startLine);
      const end = Number(c.endLine);
      const safe = safeResolve(ctx.root, path);
      if ("error" in safe) {
        err(ctx, "PATH", line, `citation ${c.id}: ${safe.error}`);
        continue;
      }
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) {
        err(ctx, "CITATION", line, `citation ${c.id} has an invalid line range`);
        continue;
      }
      if (typeof c.excerpt !== "string" || c.excerpt.trim() === "" || !/^[0-9a-f]{64}$/.test(str(c.sha256))) {
        err(ctx, "CITATION", line, `citation ${c.id} needs a literal excerpt and a sha256`);
        continue;
      }
      const bytes = reader(path);
      if (bytes === null) {
        err(ctx, "CITATION", line, `citation ${c.id}: source ${path} is missing or unreadable`);
        continue;
      }
      const content = bytes.toString("utf8");
      if (end > lineCount(content)) err(ctx, "CITATION", line, `citation ${c.id}: ${path} has no line ${end}`);
      else if (!excerptMatches(content, start, end, c.excerpt)) {
        err(ctx, "EXCERPT", line, `citation ${c.id}: excerpt does not match ${path}:${start}-${end}`);
      }
      if (sha256(bytes) !== c.sha256) {
        err(ctx, "CITATION_DRIFT", line, `citation ${c.id}: ${path} changed since it was cited (sha256 differs)`);
      }
    } else if (c.kind === "planned") {
      const path = str(c.path);
      const safe = safeResolve(ctx.root, path);
      if ("error" in safe) err(ctx, "PATH", line, `citation ${c.id}: ${safe.error}`);
      if (!todoIds.has(str(c.createdBy))) err(ctx, "CITATION", line, `planned citation ${c.id} names unknown producer '${str(c.createdBy)}'`);
      if (options.planned === "strict" && !("error" in safe) && reader(path) !== null) {
        err(ctx, "PLANNED_EXISTS", line, `planned citation ${c.id}: ${path} already exists; cite and read it as a source`);
      }
    } else if (c.kind === "external") {
      if (!/^https?:\/\//.test(str(c.url))) err(ctx, "CITATION", line, `external citation ${c.id} needs an http(s) url`);
      for (const key of ["version", "accessed", "excerpt", "obligation"]) {
        if (!str(c[key]) && !Array.isArray(c[key])) err(ctx, "CITATION", line, `external citation ${c.id} is missing '${key}'`);
      }
    } else if (c.kind !== "self") {
      err(ctx, "CITATION", line, `citation ${c.id} has unknown kind '${c.kind}'`);
    }
  }

  // Every backticked path:line reference must sit inside an indexed source citation.
  const sources = [...citations.values()].filter((c) => c.kind === "source" || c.kind === "planned");
  for (const ref of plan.citations) {
    const covered = sources.some(
      (c) =>
        str(c.path) === ref.path &&
        (c.kind === "planned" || (Number(c.startLine) <= ref.start && ref.end <= Number(c.endLine))),
    );
    if (!covered) err(ctx, "UNINDEXED_CITATION", ref.line, `\`${ref.path}:${ref.start}${ref.end !== ref.start ? `-${ref.end}` : ""}\` has no Evidence index citation covering it`);
  }

  for (const raw of Array.isArray(value.coverage) ? value.coverage : []) {
    if (!isObject(raw) || typeof raw.id !== "string") {
      err(ctx, "COVERAGE", line, "each coverage row needs a string id");
      continue;
    }
    const state = str(raw.state);
    if (!["inspected", "excluded", "pending"].includes(state)) err(ctx, "COVERAGE", line, `coverage ${raw.id} has invalid state '${state}'`);
    for (const key of ["paths", "searches", "producers", "consumers", "citationIds"]) {
      if (!Array.isArray(raw[key])) err(ctx, "COVERAGE", line, `coverage ${raw.id} needs a '${key}' array`);
    }
    if (state === "excluded" && !str(raw.reason)) err(ctx, "COVERAGE", line, `coverage ${raw.id} is excluded without a boundary reason`);
    if (state === "inspected" && strArray(raw.citationIds).length === 0) err(ctx, "COVERAGE", line, `coverage ${raw.id} is inspected but cites no evidence`);
    for (const id of strArray(raw.citationIds)) {
      if (!citations.has(id)) err(ctx, "COVERAGE", line, `coverage ${raw.id} cites unknown citation ${id}`);
    }
    if (state === "pending" && status !== "draft") err(ctx, "COVERAGE", line, `coverage ${raw.id} is still pending in a ${status} plan`);
  }
  const frontier = Array.isArray(value.frontier) ? value.frontier : [];
  for (const item of frontier) {
    if (!isObject(item) || !str(item.reason) || !str(item.nextAction)) {
      err(ctx, "FRONTIER", line, "each frontier item needs 'reason' and 'nextAction'");
    }
  }
  if (frontier.length > 0 && status !== "draft") {
    err(ctx, "FRONTIER", line, `investigation frontier has ${frontier.length} open item(s); a ${status} plan needs an empty frontier`);
  }
  const flows = Array.isArray(value.flows) ? value.flows : [];
  const flowIds = new Set<string>();
  for (const raw of flows) {
    if (!isObject(raw) || typeof raw.id !== "string") {
      err(ctx, "FLOW", line, "each flow needs a string id");
      continue;
    }
    if (flowIds.has(raw.id)) err(ctx, "FLOW", line, `duplicate flow ${raw.id}`);
    flowIds.add(raw.id);
    for (const key of ["entry", "startingState", "recovery", "counterexample"]) {
      if (!str(raw[key])) err(ctx, "FLOW", line, `flow ${raw.id} is missing '${key}'`);
    }
    if (strArray(raw.effects).length === 0) err(ctx, "FLOW", line, `flow ${raw.id} needs ordered 'effects'`);
    for (const id of strArray(raw.requirementIds)) {
      if (!requirementIds.has(id)) err(ctx, "FLOW", line, `flow ${raw.id} names unknown requirement ${id}`);
    }
    for (const id of strArray(raw.todoIds)) {
      if (!todoIds.has(id)) err(ctx, "FLOW", line, `flow ${raw.id} names unknown todo ${id}`);
    }
    for (const id of strArray(raw.evidenceIds)) {
      if (!citations.has(id)) err(ctx, "FLOW", line, `flow ${raw.id} names unknown citation ${id}`);
    }
  }
  if (flows.length === 0 && !str(value.noRuntimeFlowReason)) {
    err(ctx, "FLOW", line, "an empty flows list needs 'noRuntimeFlowReason'");
  }
  const baseline = value.baseline;
  if (!isObject(baseline)) err(ctx, "BASELINE", line, "baseline must be an object");
  else {
    if (!str(baseline.revision) && baseline.nonGit !== true) err(ctx, "BASELINE", line, "baseline needs a revision or nonGit: true");
    if (!Array.isArray(baseline.dirty)) err(ctx, "BASELINE", line, "baseline needs a 'dirty' array");
    const checks = Array.isArray(baseline.checks) ? baseline.checks : null;
    if (!checks) err(ctx, "BASELINE", line, "baseline needs a 'checks' array");
    for (const check of checks ?? []) {
      if (!isObject(check) || !str(check.command) || typeof check.exit !== "number" || !str(check.result)) {
        err(ctx, "BASELINE", line, "each baseline check needs command, numeric exit, and result");
      }
    }
  }
  return citations;
}

export function evidenceFlows(plan: ParsedPlan): string[] {
  const index = plan.evidenceIndex;
  if (!index || "error" in index || !isObject(index.value) || !Array.isArray(index.value.flows)) return [];
  return index.value.flows.filter(isObject).map((f) => str(f.id)).filter(Boolean);
}

/** The review targets every gate record must cover. */
export function requiredTargets(plan: ParsedPlan, citations: Map<string, Citation>): string[] {
  const out: string[] = [];
  for (const r of [...plan.mustHave, ...plan.mustNotHave]) if (r.id) out.push(r.id);
  for (const todo of plan.todos) {
    out.push(`${todo.id}.start`, `${todo.id}.acceptance`, `${todo.id}.qa`);
    for (const dep of todo.dependsOn) out.push(`dep:${todo.id}:${dep}`);
  }
  for (const final of plan.finals) out.push(`${final.id}.acceptance`);
  for (const flow of evidenceFlows(plan)) out.push(`flow:${flow}`);
  for (const c of citations.values()) if (c.kind === "external") out.push(`contract:${c.id}`);
  for (const letter of CHECK_LETTERS) out.push(`check:${letter}`);
  return out;
}

type Round = { number: number; start: number; end: number; headingLine: number };

function reviewRounds(plan: ParsedPlan): Round[] {
  const review = section(plan, "Review");
  if (!review) return [];
  return sectionsOf(plan.lines, 3, review.start, review.end)
    .map((s) => {
      const m = /^Round (\d+)$/.exec(s.title);
      return m ? { number: Number(m[1]), start: s.start, end: s.end, headingLine: s.headingLine } : null;
    })
    .filter((r): r is Round => r !== null);
}

export function latestGateRecord(plan: ParsedPlan): {
  round: Round;
  record: Record<string, unknown> | null;
  error: string | null;
  line: number;
} | null {
  const rounds = reviewRounds(plan);
  if (rounds.length === 0) return null;
  const round = rounds[rounds.length - 1];
  const gate = sectionsOf(plan.lines, 4, round.start, round.end).find((s) => s.title === "Gate record");
  if (!gate) return { round, record: null, error: "the latest round has no '#### Gate record'", line: round.headingLine };
  const json = fencedJson(plan.lines, gate.start, gate.end);
  if (!json) return { round, record: null, error: "'#### Gate record' has no fenced json object", line: gate.headingLine };
  if ("error" in json) return { round, record: null, error: `gate record is not valid JSON: ${json.error}`, line: json.no };
  if (!isObject(json.value)) return { round, record: null, error: "gate record must be a JSON object", line: json.no };
  return { round, record: json.value, error: null, line: json.no };
}

type ReviewOutcome = {
  expected: Verdict | null;
  recorded: Verdict | null;
  digest: string | null;
  sources: Record<string, string | null>;
  eligible: boolean;
};

function validateReview(
  ctx: Context,
  plan: ParsedPlan,
  citations: Map<string, Citation>,
  currentDigest: string,
  reader: SourceReader,
): ReviewOutcome {
  const outcome: ReviewOutcome = { expected: null, recorded: null, digest: null, sources: {}, eligible: false };
  const latest = latestGateRecord(plan);
  if (!latest) {
    err(ctx, "GATE_RECORD", section(plan, "Review")?.headingLine ?? 1, "no '### Round <n>' in '## Review'");
    return outcome;
  }
  if (!latest.record) {
    err(ctx, "GATE_RECORD", latest.line, latest.error ?? "missing gate record");
    return outcome;
  }
  const g = latest.record;
  const line = latest.line;
  outcome.digest = sha256(canonicalJson(g));
  for (const key of ["schemaVersion", "round", "planDigest", "repository", "sources", "obligations", "flows", "checks", "blockers", "verdict"]) {
    if (!(key in g)) err(ctx, "GATE_RECORD", line, `gate record is missing '${key}'`);
  }
  if (g.schemaVersion !== SCHEMA_VERSION) err(ctx, "GATE_RECORD", line, `unknown gate record schemaVersion ${String(g.schemaVersion)}`);
  if (g.round !== latest.round.number) err(ctx, "GATE_RECORD", line, `gate record round ${String(g.round)} does not match heading Round ${latest.round.number}`);
  if (String(g.round) !== plan.frontmatter.review_round) {
    err(ctx, "GATE_RECORD", plan.frontmatterLine.review_round ?? 1, `review_round ${plan.frontmatter.review_round} does not match the latest round ${String(g.round)}`);
  }
  if (g.planDigest !== currentDigest) {
    err(ctx, "STALE_REVIEW", line, `gate record planDigest ${str(g.planDigest).slice(0, 12)} does not match the current spec ${currentDigest.slice(0, 12)}`);
  }
  const recorded = (VERDICTS as readonly string[]).includes(str(g.verdict)) ? (g.verdict as Verdict) : null;
  if (!recorded) err(ctx, "GATE_RECORD", line, `verdict must be one of ${VERDICTS.join(", ")}`);
  outcome.recorded = recorded;

  for (const s of Array.isArray(g.sources) ? g.sources : []) {
    if (!isObject(s) || !str(s.path) || !/^[0-9a-f]{64}$/.test(str(s.sha256))) {
      err(ctx, "GATE_RECORD", line, "each gate source needs a path and sha256");
      continue;
    }
    const bytes = "error" in safeResolve(ctx.root, str(s.path)) ? null : reader(str(s.path));
    const current = bytes === null ? null : sha256(bytes);
    outcome.sources[str(s.path)] = current;
    if (current !== s.sha256) {
      err(ctx, "SOURCE_DRIFT", line, `reviewed source ${str(s.path)} ${current === null ? "is missing" : "changed after the review"}`);
    }
  }

  // Evidence entries.
  const evidence = new Map<string, Record<string, unknown>>();
  for (const e of Array.isArray(g.evidence) ? g.evidence : []) {
    if (!isObject(e) || !str(e.id) || !(EVIDENCE_KINDS as readonly string[]).includes(str(e.kind))) {
      err(ctx, "GATE_EVIDENCE", line, `each evidence entry needs an id and a kind (${EVIDENCE_KINDS.join(", ")})`);
      continue;
    }
    if (evidence.has(str(e.id)) || citations.has(str(e.id))) err(ctx, "GATE_EVIDENCE", line, `duplicate evidence id ${str(e.id)}`);
    evidence.set(str(e.id), e);
    const need: Record<string, string[]> = {
      probe: ["command", "inputs", "result", "omissions"],
      source: ["path", "sha256"],
      documentation: ["url", "version"],
      "plan-inspection": ["location"],
      "planned-qa": ["command"],
    };
    for (const key of need[str(e.kind)]) {
      if (!str(e[key])) err(ctx, "GATE_EVIDENCE", line, `${str(e.kind)} evidence ${str(e.id)} is missing '${key}'`);
    }
    if (e.kind === "probe" && typeof e.exit !== "number") err(ctx, "GATE_EVIDENCE", line, `probe evidence ${str(e.id)} needs a numeric exit`);
  }
  const kindOf = (id: string): string | null => {
    const e = evidence.get(id);
    if (e) return str(e.kind);
    const c = citations.get(id);
    if (!c) return null;
    return c.kind === "planned" ? "planned-qa" : c.kind === "external" ? "documentation" : c.kind === "self" ? "plan-inspection" : "source";
  };

  // Obligations.
  const covered = new Set<string>();
  const obligationStatus = new Map<string, string>();
  let required = 0;
  let verified = 0;
  let contradicted = 0;
  let unverified = 0;
  for (const o of Array.isArray(g.obligations) ? g.obligations : []) {
    if (!isObject(o) || !str(o.id)) {
      err(ctx, "GATE_RECORD", line, "each obligation needs an id");
      continue;
    }
    const id = str(o.id);
    if (obligationStatus.has(id)) err(ctx, "GATE_RECORD", line, `duplicate obligation ${id}`);
    const status = str(o.status);
    if (!(OBLIGATION_STATUSES as readonly string[]).includes(status)) err(ctx, "GATE_RECORD", line, `obligation ${id} has invalid status '${status}'`);
    obligationStatus.set(id, status);
    const isRequired = o.required !== false;
    if (strArray(o.targets).length === 0) err(ctx, "GATE_RECORD", line, `obligation ${id} names no targets`);
    if (!str(o.observed)) err(ctx, "GATE_RECORD", line, `obligation ${id} has no observed result`);
    if (!isRequired) continue;
    required++;
    for (const t of strArray(o.targets)) covered.add(t);
    if (status === "verified") verified++;
    if (status === "contradicted") contradicted++;
    if (status === "unverified") unverified++;
    const ids = strArray(o.evidenceIds);
    if (status === "verified" || status === "contradicted") {
      if (ids.length === 0) err(ctx, "GATE_EVIDENCE", line, `obligation ${id} is ${status} without evidence`);
      const kinds = ids.map((e) => {
        const k = kindOf(e);
        if (k === null) err(ctx, "GATE_EVIDENCE", line, `obligation ${id} cites unknown evidence ${e}`);
        return k;
      });
      if (ids.length > 0 && kinds.every((k) => k === "planned-qa")) {
        err(ctx, "PLANNED_QA_AS_EVIDENCE", line, `obligation ${id} is ${status} using only planned QA; a future test is not evidence`);
      }
    }
  }
  const targets = requiredTargets(plan, citations);
  const uncovered = targets.filter((t) => !covered.has(t));
  for (const t of uncovered) ctx.gaps.push(`required target ${t} has no required obligation`);

  // Flows and checks.
  const planFlows = evidenceFlows(plan);
  const gateFlows = new Map<string, Record<string, unknown>>();
  for (const f of Array.isArray(g.flows) ? g.flows : []) {
    if (!isObject(f) || !str(f.id)) {
      err(ctx, "GATE_RECORD", line, "each gate flow needs an id");
      continue;
    }
    gateFlows.set(str(f.id), f);
    if (!planFlows.includes(str(f.id))) err(ctx, "GATE_RECORD", line, `gate flow ${str(f.id)} is not a plan flow`);
    if (!str(f.counterexample)) err(ctx, "GATE_RECORD", line, `gate flow ${str(f.id)} records no counterexample`);
  }
  let flowsVerified = 0;
  let flowsContradicted = 0;
  for (const id of planFlows) {
    const f = gateFlows.get(id);
    if (!f) ctx.gaps.push(`critical flow ${id} has no gate record entry`);
    else if (f.status === "verified") flowsVerified++;
    else if (f.status === "contradicted") flowsContradicted++;
    else ctx.gaps.push(`critical flow ${id} is ${str(f.status) || "unset"}`);
  }
  const checks = isObject(g.checks) ? g.checks : {};
  let checksContradicted = 0;
  for (const letter of CHECK_LETTERS) {
    const c = checks[letter];
    if (!isObject(c)) {
      ctx.gaps.push(`check ${letter} has no result`);
      continue;
    }
    if (c.status === "contradicted") checksContradicted++;
    else if (c.status !== "verified") ctx.gaps.push(`check ${letter} is ${str(c.status) || "unset"}`);
    if (!str(c.observed)) err(ctx, "GATE_RECORD", line, `check ${letter} has no observed result`);
  }
  if (unverified > 0) ctx.gaps.push(`${unverified} required obligation(s) unverified`);

  // Blockers.
  const blockers = Array.isArray(g.blockers) ? g.blockers : [];
  const linked = new Set<string>();
  for (const b of blockers) {
    if (!isObject(b) || !str(b.id)) {
      err(ctx, "GATE_BLOCKER", line, "each blocker needs an id");
      continue;
    }
    for (const key of ["location", "failure", "fix"]) {
      if (!str(b[key])) err(ctx, "GATE_BLOCKER", line, `blocker ${str(b.id)} is missing '${key}'`);
    }
    if (strArray(b.evidenceIds).length === 0) err(ctx, "GATE_BLOCKER", line, `blocker ${str(b.id)} cites no evidence`);
    for (const e of strArray(b.evidenceIds)) {
      if (kindOf(e) === null) err(ctx, "GATE_BLOCKER", line, `blocker ${str(b.id)} cites unknown evidence ${e}`);
    }
    for (const o of strArray(b.obligationIds)) {
      if (obligationStatus.get(o) !== "contradicted") err(ctx, "GATE_BLOCKER", line, `blocker ${str(b.id)} names ${o}, which is not a contradicted obligation`);
      linked.add(o);
    }
  }
  for (const [id, status] of obligationStatus) {
    if (status === "contradicted" && !linked.has(id)) err(ctx, "GATE_BLOCKER", line, `contradicted obligation ${id} has no detailed blocker`);
  }

  let expected: Verdict;
  if (contradicted + flowsContradicted + checksContradicted > 0) expected = "REJECT";
  else if (ctx.gaps.length > 0) expected = "INCOMPLETE";
  else expected = "OKAY";
  outcome.expected = expected;
  if (recorded && recorded !== expected) {
    err(ctx, "VERDICT", line, `recorded verdict ${recorded} but the ledger supports ${expected}${ctx.gaps.length ? ` (${ctx.gaps.slice(0, 3).join("; ")})` : ""}`);
  }
  if (recorded === "REJECT" && blockers.length === 0) err(ctx, "GATE_BLOCKER", line, "REJECT needs at least one blocker");
  if (recorded !== "REJECT" && blockers.length > 0) err(ctx, "GATE_BLOCKER", line, `${recorded ?? "this"} verdict must not list blockers`);
  const status = plan.frontmatter.status;
  if (recorded === "OKAY" && status !== "reviewed") err(ctx, "STATUS", plan.frontmatterLine.status ?? 1, "an OKAY round must set status: reviewed");
  if (recorded && recorded !== "OKAY" && status !== "planned") err(ctx, "STATUS", plan.frontmatterLine.status ?? 1, `a ${recorded} round must set status: planned`);

  // Rendered verdict, scope counts, history, and ledger.
  const body = plan.lines.slice(latest.round.start, latest.round.end).filter((l) => !l.fenced && !l.fenceMarker);
  const verdictLine = body.find((l) => l.text.startsWith("**Verdict:**"));
  const rendered = verdictLine ? /PLAN-REVIEW: (OKAY|INCOMPLETE|REJECT \((\d+) blockers?\))/.exec(verdictLine.text) : null;
  if (!rendered) err(ctx, "RENDERED_MISMATCH", latest.round.headingLine, "round has no '**Verdict:** PLAN-REVIEW: ...' line");
  else {
    const v = rendered[1].startsWith("REJECT") ? "REJECT" : rendered[1];
    if (v !== recorded) err(ctx, "RENDERED_MISMATCH", verdictLine?.no ?? 1, `rendered verdict ${v} differs from gate record ${recorded ?? "none"}`);
    if (rendered[2] && Number(rendered[2]) !== blockers.length) {
      err(ctx, "RENDERED_MISMATCH", verdictLine?.no ?? 1, `rendered blocker count ${rendered[2]} differs from ${blockers.length} gate blockers`);
    }
  }
  const scopeLine = body.find((l) => l.text.startsWith("**Scope:**"));
  const obligationsCount = scopeLine ? /(\d+)\/(\d+) required obligations verified/.exec(scopeLine.text) : null;
  const flowsCount = scopeLine ? /(\d+)\/(\d+) critical flows verified/.exec(scopeLine.text) : null;
  if (!obligationsCount || Number(obligationsCount[1]) !== verified || Number(obligationsCount[2]) !== required) {
    err(ctx, "RENDERED_MISMATCH", scopeLine?.no ?? latest.round.headingLine, `Scope must state ${verified}/${required} required obligations verified`);
  }
  if (!flowsCount || Number(flowsCount[1]) !== flowsVerified || Number(flowsCount[2]) !== planFlows.length) {
    err(ctx, "RENDERED_MISMATCH", scopeLine?.no ?? latest.round.headingLine, `Scope must state ${flowsVerified}/${planFlows.length} critical flows verified`);
  }
  const review = section(plan, "Review") as Section;
  const firstRound = reviewRounds(plan)[0];
  const history = tableRows(plan.lines, review.start, firstRound ? firstRound.start - 1 : review.end).filter((r) => /^\d+$/.test(r.cells[0] ?? ""));
  const last = history[history.length - 1];
  if (!last || Number(last.cells[0]) !== latest.round.number || !(last.cells[2] ?? "").startsWith(recorded ?? "?")) {
    err(ctx, "RENDERED_MISMATCH", last?.no ?? review.headingLine, `history table's last round must be ${latest.round.number} with verdict ${recorded ?? "?"}`);
  }
  const ledger = sectionsOf(plan.lines, 4, latest.round.start, latest.round.end).find((s) => s.title === "Coverage and evidence");
  if (!ledger) err(ctx, "RENDERED_MISMATCH", latest.round.headingLine, "round has no '#### Coverage and evidence' ledger");
  else {
    const rows = tableRows(plan.lines, ledger.start, ledger.end).filter((r) => r.cells.length >= 2 && !/^ID\b/.test(r.cells[0]));
    const renderedStatus = new Map(rows.map((r) => [r.cells[0].split(/\s+/)[0], r.cells[r.cells.length - 1]]));
    for (const [id, status] of obligationStatus) {
      if (!renderedStatus.has(id)) err(ctx, "RENDERED_MISMATCH", ledger.headingLine, `obligation ${id} is missing from the rendered ledger`);
      else if (renderedStatus.get(id) !== status) err(ctx, "RENDERED_MISMATCH", ledger.headingLine, `rendered status of ${id} is '${renderedStatus.get(id)}', gate record says '${status}'`);
    }
    for (const id of renderedStatus.keys()) {
      if (!obligationStatus.has(id)) err(ctx, "RENDERED_MISMATCH", ledger.headingLine, `rendered ledger row ${id} is not in the gate record`);
    }
  }
  outcome.eligible = expected === "OKAY" && recorded === "OKAY";
  return outcome;
}

/* ── resume (D2/D4) ────────────────────────────────────────────────────────── */

type Receipt = Record<string, unknown> & {
  seq: number;
  todo: string;
  event: string;
  state: string;
  prev: string | null;
  before: { snapshot: string; manifestSha256: string; stateDigest: string };
  after: { snapshot: string; manifestSha256: string; stateDigest: string } | null;
};

export function buildRecord(plan: ParsedPlan): { value: unknown; no: number } | { error: string; no: number } | null {
  const build = section(plan, "Build");
  if (!build) return null;
  const sub = sectionsOf(plan.lines, 3, build.start, build.end).find((s) => s.title === "Build record");
  if (!sub) return { error: "'## Build' has no '### Build record'", no: build.headingLine };
  return fencedJson(plan.lines, sub.start, sub.end) ?? { error: "'### Build record' has no fenced json", no: sub.headingLine };
}

type ResumeOutcome = {
  eligible: boolean;
  nextTodo: string | null;
  activeTodo: string | null;
  recoveryRequired: boolean;
  unresolvedAction: string | null;
  requiredRechecks: { todo: string; paths: string[] }[];
  reconcileBoxes: string[];
  drift: string[];
  exit2: boolean;
};

function executionOrder(plan: ParsedPlan): string[] {
  const order = plan.todos.some((t) => t.id === "T0") ? ["T0"] : [];
  for (const wave of [...plan.waves].sort((a, b) => a.wave - b.wave)) {
    for (const id of wave.todos) if (!order.includes(id)) order.push(id);
  }
  for (const todo of plan.todos) if (!order.includes(todo.id)) order.push(todo.id);
  return order;
}

function validateResume(ctx: Context, plan: ParsedPlan, planRel: string, currentDigest: string, inGit: boolean): ResumeOutcome {
  const out: ResumeOutcome = {
    eligible: false,
    nextTodo: null,
    activeTodo: null,
    recoveryRequired: false,
    unresolvedAction: null,
    requiredRechecks: [],
    reconcileBoxes: [],
    drift: [],
    exit2: false,
  };
  const record = buildRecord(plan);
  if (!record) {
    err(ctx, "BUILD_RECORD", 1, "--resume needs a '## Build' section with a Build record");
    out.exit2 = true;
    return out;
  }
  if ("error" in record) {
    err(ctx, "BUILD_RECORD", record.no, record.error);
    return out;
  }
  const b = record.value;
  const line = record.no;
  if (!isObject(b) || b.schemaVersion !== SCHEMA_VERSION) {
    err(ctx, "BUILD_RECORD", line, "Build record must be an object with schemaVersion 1");
    return out;
  }
  const approval = isObject(b.approval) ? b.approval : {};
  const baselineRef = isObject(b.baseline) ? b.baseline : {};
  const receipts = (Array.isArray(b.receipts) ? b.receipts : []) as Receipt[];

  // Spec and live approval.
  let blocked = false;
  if (approval.specDigest !== currentDigest) {
    err(ctx, "SPEC_CHANGED", line, "the plan's canonical spec differs from the approved spec; start a new review and a new build run");
    blocked = true;
  }
  const latest = latestGateRecord(plan);
  const liveDigest = latest?.record ? sha256(canonicalJson(latest.record)) : null;
  if (plan.frontmatter.status !== "reviewed" || !latest?.record || latest.round.number !== approval.round || liveDigest !== approval.gateRecordDigest || latest.record.verdict !== "OKAY") {
    err(ctx, "APPROVAL_CHANGED", line, "the live review no longer matches the approval this build started from; get an explicit re-reviewed handoff before continuing");
    blocked = true;
  }

  // Baseline snapshot.
  const snapshots = new Map<string, { manifest: Manifest; dir: string }>();
  const load = (ref: unknown, label: string): { manifest: Manifest; dir: string } | null => {
    if (!isObject(ref) || !str(ref.snapshot)) {
      err(ctx, "BUILD_RECORD", line, `${label} has no snapshot reference`);
      return null;
    }
    const key = str(ref.snapshot);
    const dir = resolveSnapshot(ctx.root, key, inGit);
    let loaded = snapshots.get(key);
    if (!loaded) {
      try {
        const v = verifySnapshot(dir);
        if (v.manifestSha256 !== ref.manifestSha256) {
          err(ctx, "SNAPSHOT_CORRUPT", line, `${label}: manifest ${key} does not match its recorded digest`);
          return null;
        }
        loaded = { manifest: v.manifest, dir };
        snapshots.set(key, loaded);
      } catch (error) {
        if (error instanceof UnreadableInput) {
          err(ctx, "SNAPSHOT_MISSING", line, `${label}: ${(error as Error).message}`);
          out.exit2 = true;
        } else err(ctx, "SNAPSHOT_CORRUPT", line, `${label}: ${(error as Error).message}`);
        return null;
      }
    }
    if (loaded.manifest.stateDigest !== ref.stateDigest) {
      err(ctx, "SNAPSHOT_CORRUPT", line, `${label}: snapshot state ${loaded.manifest.stateDigest.slice(0, 12)} differs from the recorded ${str(ref.stateDigest).slice(0, 12)}`);
    }
    return loaded;
  };
  const baseline = load(baselineRef, "baseline");
  if (!baseline) return out;
  if (canonicalJson(baseline.manifest.repository) !== canonicalJson(b.repository)) {
    err(ctx, "REPOSITORY_MISMATCH", line, "baseline snapshot belongs to a different repository than the Build record");
    blocked = true;
  }
  if (baseline.manifest.approvedSpecDigest !== approval.specDigest) {
    err(ctx, "REPOSITORY_MISMATCH", line, "baseline snapshot was captured for a different approved spec");
  }
  if (inGit) {
    const identity = gitRepositoryIdentity(ctx.root);
    const recorded = isObject(b.repository) ? strArray(b.repository.rootCommits).join(",") : "";
    if (recorded !== identity.rootCommits.join(",")) {
      err(ctx, "REPOSITORY_MISMATCH", line, "the Build record names a different repository than the current project");
      blocked = true;
    }
  }

  // The archived approval must describe the baseline bytes.
  const baselineRows = new Map(baseline.manifest.paths.map((r) => [r.path, r]));
  const baselineReader: SourceReader = (path) => {
    const row = baselineRows.get(path);
    if (!row || row.worktree.state !== "file") return null;
    return readSnapshotBlob(baseline.dir, row.worktree.sha256);
  };
  if (latest?.record) {
    for (const s of Array.isArray(latest.record.sources) ? latest.record.sources : []) {
      if (!isObject(s)) continue;
      const row = baselineRows.get(str(s.path));
      const digest = row && row.worktree.state === "file" ? row.worktree.sha256 : null;
      if (digest !== s.sha256) {
        err(ctx, "APPROVAL_BASELINE_MISMATCH", line, `approved source ${str(s.path)} does not match the baseline snapshot`);
        blocked = true;
      }
    }
  }
  const baseCtx: Context = { ...ctx, errors: [], gaps: [] };
  validateEvidenceIndex(baseCtx, plan, baselineReader, { planned: "lenient" });
  for (const e of baseCtx.errors) {
    if (["CITATION", "EXCERPT", "CITATION_DRIFT"].includes(e.code)) err(ctx, e.code, e.line, `against the baseline: ${e.message}`);
  }

  // Receipt chain.
  const todoById = new Map(plan.todos.map((t) => [t.id, t]));
  const passed = new Map<string, Receipt>();
  let prevEnd = { stateDigest: str(baselineRef.stateDigest), snapshot: str(baselineRef.snapshot) };
  let prevDigest: string | null = null;
  let active: string | null = null;
  let lastState = "passed";
  let lastNote = "";
  const changedByDone = new Map<string, number>();
  const rechecks: { targets: string[]; status: string; seq: number }[] = [];
  let prevManifest = baseline.manifest;
  for (let i = 0; i < receipts.length; i++) {
    const r = receipts[i];
    const label = `receipt ${i + 1}`;
    if (!isObject(r)) {
      err(ctx, "RECEIPT_CHAIN", line, `${label} is not an object`);
      continue;
    }
    if (r.seq !== i + 1) err(ctx, "RECEIPT_CHAIN", line, `${label} has seq ${String(r.seq)}`);
    if (r.prev !== prevDigest) err(ctx, "RECEIPT_CHAIN", line, `${label} does not chain to the previous receipt (tampered or reordered)`);
    prevDigest = sha256(canonicalJson(r));
    if (!(RECEIPT_EVENTS as readonly string[]).includes(r.event)) err(ctx, "RECEIPT_CHAIN", line, `${label} has unknown event '${String(r.event)}'`);
    if (!todoById.has(r.todo) && !/^F\d+$/.test(r.todo)) err(ctx, "RECEIPT_CHAIN", line, `${label} names unknown todo ${String(r.todo)}`);
    if (!isObject(r.before) || r.before.stateDigest !== prevEnd.stateDigest) {
      err(ctx, "RECEIPT_CHAIN", line, `${label} (${r.todo} ${r.event}) does not start from the previous recorded state`);
    }
    const beforeSnap = load(r.before, `${label} before`);
    const afterSnap = r.after ? load(r.after, `${label} after`) : null;
    if (r.event !== "start" && !r.after) err(ctx, "RECEIPT_CHAIN", line, `${label} (${r.event}) has no after state`);
    if (r.event === "start" || (r.event === "recovery" && active !== r.todo)) {
      // A recovery receipt for a todo that was not started records effects that
      // began before its start receipt; it makes that todo active.
      if (active && active !== r.todo) err(ctx, "RECEIPT_ORDER", line, `${label} starts ${r.todo} while ${active} is still active`);
      for (const dep of todoById.get(r.todo)?.dependsOn ?? []) {
        if (!passed.has(dep)) err(ctx, "DEPENDENCY_ORDER", line, `${r.todo} started before its dependency ${dep} passed`);
      }
      active = r.todo;
    } else if (r.todo !== active && !/^F\d+$/.test(r.todo)) {
      err(ctx, "RECEIPT_ORDER", line, `${label} records ${r.event} for ${r.todo}, which was not started`);
    }
    for (const p of Array.isArray(r.prerequisites) ? r.prerequisites : []) {
      if (isObject(p)) rechecks.push({ targets: strArray(p.targets), status: str(p.status), seq: r.seq });
    }
    const end = afterSnap ?? beforeSnap;
    if (end && afterSnap) {
      for (const d of diffStates(prevManifest, afterSnap.manifest, [planRel, ...(afterSnap.manifest.administrative?.reports ?? [])])) {
        const path = d.replace(/ \[(head|index|worktree)\]$/, "");
        changedByDone.set(path, r.seq);
      }
    }
    if (r.event === "pass") {
      const todo = todoById.get(r.todo);
      for (const dep of todo?.dependsOn ?? []) {
        if (!passed.has(dep)) err(ctx, "DEPENDENCY_ORDER", line, `${r.todo} passed before its dependency ${dep}`);
      }
      const checks = Array.isArray(r.checks) ? r.checks : [];
      if (checks.length === 0) err(ctx, "PASS_WITHOUT_CHECKS", line, `${label}: ${r.todo} passed without recorded checks`);
      for (const c of checks) {
        if (!isObject(c) || !str(c.command) || typeof c.exit !== "number") err(ctx, "PASS_WITHOUT_CHECKS", line, `${label}: each check needs a command and numeric exit`);
        else if (c.passed === false || (typeof c.expectedExit === "number" ? c.exit !== c.expectedExit : c.exit !== 0)) {
          err(ctx, "PASS_WITHOUT_CHECKS", line, `${label}: ${r.todo} passed with a failing check '${str(c.id) || str(c.command)}'`);
        }
      }
      if (todo?.commit) {
        const commit = isObject(r.commit) ? str(r.commit.sha) : "";
        if (!commit) err(ctx, "COMMIT", line, `${label}: ${r.todo} says Commit: yes but its passed receipt has no commit`);
        else if (afterSnap && afterSnap.manifest.headRevision !== commit) err(ctx, "COMMIT", line, `${label}: after-state HEAD is not the recorded commit ${commit.slice(0, 12)}`);
      }
      passed.set(r.todo, r);
      if (active === r.todo) active = null;
    }
    if (r.event === "block" && active === r.todo) active = null;
    lastState = r.state;
    lastNote = str(r.note);
    if (end) {
      prevEnd = { stateDigest: end.manifest.stateDigest, snapshot: str((r.after ?? r.before).snapshot) };
      prevManifest = end.manifest;
    }
  }

  // Boxes.
  for (const todo of plan.todos) {
    if (todo.box === "Done" && !passed.has(todo.id)) err(ctx, "DONE_WITHOUT_RECEIPT", todo.line, `${todo.id} is marked Done without a passed receipt`);
    if (todo.box === "Open" && passed.has(todo.id)) out.reconcileBoxes.push(todo.id);
  }

  // Current state against the last recorded state.
  const carry = new Set<string>();
  const includes = new Set<string>();
  for (const s of snapshots.values()) {
    for (const row of s.manifest.paths) carry.add(row.path);
    for (const inc of s.manifest.includes ?? []) includes.add(inc);
  }
  const reports = prevManifest.administrative?.reports ?? [];
  try {
    const inv = inventoryState(ctx.root, { carry: [...carry], include: [...includes] });
    const digest = stateDigest(inv.body, planRel, (d) => inv.blobs.get(d) as Buffer, reports);
    if (digest !== prevEnd.stateDigest) {
      out.drift = diffStates(prevManifest, inv.body, [planRel, ...reports]);
      if (out.drift.length === 0) out.drift = [`${planRel} [spec]`];
      out.recoveryRequired = true;
      out.unresolvedAction = `investigate unrecorded changes (${out.drift.slice(0, 5).join(", ")}${out.drift.length > 5 ? ", …" : ""}); rerun affected checks, then record a recovery receipt before advancing`;
      err(ctx, "STATE_DRIFT", line, `current project state differs from the last receipt: ${out.drift.slice(0, 10).join(", ")}`);
    }
  } catch (error) {
    err(ctx, "STATE_DRIFT", line, `cannot inventory the current project: ${(error as Error).message}`);
    out.recoveryRequired = true;
  }

  // Next todo, prerequisites.
  const order = executionOrder(plan);
  out.activeTodo = active;
  out.nextTodo = active ?? order.find((id) => !passed.has(id)) ?? plan.finals.find((f) => f.box !== "Done")?.id ?? null;
  for (const id of order) {
    if (passed.has(id)) continue;
    const todo = todoById.get(id);
    if (!todo) continue;
    const refPaths = todo.references.map((r) => r.replace(/:\d+(-\d+)?$/, "")).filter((p) => p !== "this file");
    const touched = refPaths.filter((p) => changedByDone.has(p));
    if (touched.length === 0) continue;
    const lastChange = Math.max(...touched.map((p) => changedByDone.get(p) as number));
    const done = rechecks.filter((r) => r.seq >= lastChange && r.targets.some((t) => t === id || t.startsWith(`${id}.`)));
    if (done.some((r) => r.status === "fails")) {
      err(ctx, "PREREQUISITE_FAILED", line, `a recorded recheck says ${id}'s prerequisites no longer hold; the plan needs a new review`);
      blocked = true;
    } else if (!done.some((r) => r.status === "holds")) out.requiredRechecks.push({ todo: id, paths: touched });
  }
  if (lastState === "blocked") {
    blocked = true;
    out.unresolvedAction = out.unresolvedAction ?? `the last receipt is blocked: ${lastNote || "no note"}`;
  }
  out.eligible = !blocked && ctx.errors.length === 0;
  return out;
}

export function gitRepositoryIdentity(root: string): { rootCommits: string[] } {
  const p = git(root, ["rev-list", "--max-parents=0", "HEAD"]);
  return { rootCommits: p.code === 0 ? p.out.toString().split(/\s+/).filter(Boolean).sort() : [] };
}

/* ── entry point ───────────────────────────────────────────────────────────── */

export type Options = { root?: string; review?: boolean; resume?: boolean };

export function validatePlan(planPath: string, options: Options = {}): ValidationResult {
  const root = resolve(options.root ?? process.cwd());
  const mode: Mode = options.resume ? "resume" : options.review ? "review" : "plan";
  const absPlan = resolve(root, planPath);
  const planRel = absPlan.startsWith(root + sep) ? absPlan.slice(root.length + 1).split(sep).join("/") : planPath;
  const result: ValidationResult = {
    schemaVersion: 1,
    validationMode: mode,
    plan: planRel,
    errors: [],
    gaps: [],
    planDigest: null,
    sourceDigests: {},
    expectedVerdict: null,
    recordedVerdict: null,
    gateRecordDigest: null,
    gateEligible: false,
    resumeEligible: false,
    nextTodo: null,
    activeTodo: null,
    recoveryRequired: false,
    unresolvedAction: null,
    requiredRechecks: [],
    reconcileBoxes: [],
    drift: [],
    exitCode: 0,
  };
  const ctx: Context = { file: planRel, root, errors: result.errors, gaps: result.gaps };
  const bytes = readBytes(absPlan);
  if (bytes === null) {
    err(ctx, "UNREADABLE", 0, `cannot read plan ${planPath}`);
    result.exitCode = 2;
    return result;
  }
  const text = bytes.toString("utf8");
  const plan = parsePlan(text);
  const digest = canonicalSpecDigest(text);
  result.planDigest = digest;
  validateStructure(ctx, plan);

  const currentReader: SourceReader = (path) => {
    const safe = safeResolve(root, path);
    return "error" in safe ? null : readBytes(safe.abs);
  };
  const hasBuild = section(plan, "Build") !== undefined;
  const citations =
    mode === "resume"
      ? validateEvidenceIndexQuiet(ctx, plan)
      : validateEvidenceIndex(ctx, plan, currentReader, { planned: hasBuild ? "lenient" : "strict" });
  for (const c of citations.values()) {
    if (c.kind === "source") result.sourceDigests[str(c.path)] = (() => {
      const b = currentReader(str(c.path));
      return b === null ? null : sha256(b);
    })();
  }

  if (mode === "review" || mode === "resume") {
    const reviewCtx = mode === "resume" ? { ...ctx, errors: [] as Finding[] } : ctx;
    const review = validateReview(reviewCtx, plan, citations, digest, currentReader);
    if (mode === "resume") {
      // Current-source drift is expected during a build; keep only record-shape errors.
      for (const e of reviewCtx.errors) {
        if (e.code !== "SOURCE_DRIFT" && e.code !== "STALE_REVIEW") ctx.errors.push(e);
      }
    }
    result.expectedVerdict = review.expected;
    result.recordedVerdict = review.recorded;
    result.gateRecordDigest = review.digest;
    Object.assign(result.sourceDigests, review.sources);
    if (mode === "review") result.gateEligible = review.eligible && result.errors.length === 0;
  }
  if (mode === "resume") {
    const inGit = isGitRoot(root);
    const resume = validateResume(ctx, plan, planRel, digest, inGit);
    result.resumeEligible = resume.eligible && result.errors.length === 0;
    result.nextTodo = resume.nextTodo;
    result.activeTodo = resume.activeTodo;
    result.recoveryRequired = resume.recoveryRequired;
    result.unresolvedAction = resume.unresolvedAction;
    result.requiredRechecks = resume.requiredRechecks;
    result.reconcileBoxes = resume.reconcileBoxes;
    result.drift = resume.drift;
    if (resume.exit2) {
      result.exitCode = 2;
      return result;
    }
  }
  result.exitCode = result.errors.length > 0 ? 1 : 0;
  return result;
}

/** Structure-only index check used on resume, where citations are checked
 * against the baseline snapshot instead of the current files. */
function validateEvidenceIndexQuiet(ctx: Context, plan: ParsedPlan): Map<string, Citation> {
  const quiet: Context = { ...ctx, errors: [], gaps: [] };
  const citations = validateEvidenceIndex(quiet, plan, () => Buffer.alloc(0), { planned: "lenient" });
  for (const e of quiet.errors) {
    if (!["CITATION", "EXCERPT", "CITATION_DRIFT"].includes(e.code)) ctx.errors.push(e);
  }
  return citations;
}

export const USAGE = `Usage: validate-plan <plan> [--review [--resume]] [--root <project>] [--json]

Checks a plan-writer plan (default), its latest plan-review gate record
(--review), or a plan-builder resume state (--review --resume).

  --review        Also check the latest '### Round <n>' gate record and report
                  gateEligible. Exit 0 is not approval: read gateEligible.
  --resume        With --review: verify the archived approval against the
                  build baseline and the receipt chain against the current
                  project, and report resumeEligible and nextTodo.
  --root <dir>    Project root for citations and snapshots. Default: cwd.
  --json          Print one JSON object instead of text findings.
  --help          Show this message.

Exit codes: 0 structurally consistent; 1 invalid structure, inconsistent
evidence, or unexpected drift; 2 invalid arguments or unreadable input.
Never edits files, calls a model, fetches a URL, or runs plan commands.`;

export function main(argv: string[], write: (text: string) => void = (t) => console.log(t)): number {
  let plan: string | null = null;
  let root: string | undefined;
  let review = false;
  let resume = false;
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      write(USAGE);
      return 0;
    }
    if (arg === "--review") review = true;
    else if (arg === "--resume") resume = true;
    else if (arg === "--json") json = true;
    else if (arg === "--root") {
      root = argv[++i];
      if (!root) {
        write("error: --root needs a directory");
        return 2;
      }
    } else if (arg.startsWith("-")) {
      write(`error: unknown argument '${arg}'\n${USAGE}`);
      return 2;
    } else if (plan === null) plan = arg;
    else {
      write(`error: unexpected argument '${arg}'`);
      return 2;
    }
  }
  if (plan === null) {
    write(`error: a plan path is required\n${USAGE}`);
    return 2;
  }
  if (resume && !review) {
    write("error: --resume requires --review");
    return 2;
  }
  let result: ValidationResult;
  try {
    result = validatePlan(plan, { root, review, resume });
  } catch (error) {
    write(`error: ${(error as Error).message}`);
    return 2;
  }
  if (json) write(JSON.stringify(result, null, 2));
  else {
    for (const e of result.errors) write(`ERROR[${e.code}] ${e.file}:${e.line} ${e.message}`);
    for (const g of result.gaps) write(`GAP ${g}`);
    const parts = [`${result.plan}: ${result.validationMode} mode`, `${result.errors.length} errors`];
    if (result.validationMode !== "plan") parts.push(`expected verdict ${result.expectedVerdict ?? "none"}`, `gateEligible ${result.gateEligible}`);
    if (result.validationMode === "resume") parts.push(`resumeEligible ${result.resumeEligible}`, `next ${result.nextTodo ?? "none"}`);
    write(parts.join("; "));
  }
  return result.exitCode;
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
