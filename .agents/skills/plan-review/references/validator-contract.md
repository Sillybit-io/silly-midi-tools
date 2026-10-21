# Validator contract

Read this file when you write or check the machine-readable parts of a plan: the Evidence index, a review round's Gate record, or a Build record. The validator is `scripts/validate-plan.ts` in this skill's directory. It uses Bun or Node built-ins only.

```text
bun <plan-review-base>/scripts/validate-plan.ts <plan> [--review [--resume]] [--root <project>] [--json]
```

In this repository, `bun run validate-plan <plan> ...` runs the same code.

## What the result means

| Exit | Meaning |
| --- | --- |
| 0 | The requested record is structurally consistent. This is not approval. |
| 1 | Invalid structure, inconsistent evidence, or unexpected drift. |
| 2 | Invalid arguments or unreadable input, including a missing snapshot. |

`--json` prints one object: `schemaVersion`, `validationMode` (`plan`, `review`, or `resume`), `errors`, `gaps`, `planDigest`, `sourceDigests`, `expectedVerdict`, `recordedVerdict`, `gateRecordDigest`, `gateEligible`, `resumeEligible`, `nextTodo`, `activeTodo`, `recoveryRequired`, `unresolvedAction`, `requiredRechecks`, `reconcileBoxes`, `drift`, and `exitCode`.

- `gateEligible` is true only in review mode, for a complete, consistent OKAY on the current plan and current source bytes.
- `resumeEligible` is true only in resume mode, after the baseline, the unchanged spec, the live approval, the receipt chain, and the current state all check out. Resume mode always reports `gateEligible: false`.
- A well-formed REJECT or INCOMPLETE round exits 0 and is not eligible. A blocked build receipt exits 0 and is not eligible.

The validator never edits files, calls a model, fetches a URL, or runs a command from a plan. It checks shape, identity, arithmetic, and agreement. It cannot prove that a reviewer read the code or that a flow works.

## Canonical spec digest

The spec digest identifies the plan's instructions. To compute it:

1. Normalize CRLF and CR to LF. Drop one final empty line.
2. Remove the frontmatter lines that start with `status:` or `review_round:`.
3. Remove every top-level section titled `Review`, `Build`, or `Result review`, from its level-2 heading to the next level-2 heading. Headings inside code fences do not count.
4. Outside code fences, replace each line `- [x] Done` or `- [ ] Open` with `- [ ] Open`.
5. Join the kept lines with LF, add one final LF, and take the SHA-256 of the UTF-8 bytes.

Any change to a task, decision, dependency, or acceptance criterion changes the digest. Progress and appended records do not.

## Canonical JSON

Every digest of a JSON value hashes its canonical JSON. Object keys are sorted, there is no whitespace, and non-ASCII characters are written as themselves, not as `\u` escapes. Numbers are integers. The SHA-256 is taken over the UTF-8 bytes. In JavaScript this is `JSON.stringify` of a key-sorted value. In Python it is `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`. Python's default, `ensure_ascii=True`, gives a different digest for any record that holds a non-ASCII character.

## Plan grammar

- **Frontmatter:** exactly `title`, `request`, `source`, `date`, `status`, `tier`, `intent`, `branch`, `ui`, `review`, `review_round`.
- **Top-level sections, in order:** TL;DR, Scope, Research, Questions, Design, Verification strategy, Execution strategy, Todos, Final verification wave, Success criteria, Review. Build and Result review may follow.
- **Scope subsections:** Affected users, Ideal state, IS / GAP ledger, Risks, Must have, Must NOT have, Coverage, Critical flows, Baseline, Evidence index.
- **Identifiers:** gap rows start with `G<n>`. Must have bullets start `- MH<n>:` and Must NOT have bullets start `- MN<n>:`.
- **Questions:** `### Product` before `### Technical`, neither empty.
- **Design:** a `mermaid` fence whose first line starts with `flowchart`, `sequenceDiagram`, or `stateDiagram`, or the line `Diagram: omitted — <reason>`.
- **Todos:** `### T<n> — <title>`, T0 first. The first line is `- [ ] Open` or `- [x] Done`. The fields are `Do`, `Must not`, `Closes gap`, `Depends on`, `References`, `Acceptance`, `QA scenario`, and `Commit`. Every gap is closed by a todo other than T0, and every todo other than T0 closes a gap.
- **Waves:** `- Wave <n>: T<a>, T<b> — <note>`. Waves count up from 1. T0 runs alone first. A dependency must sit in an earlier wave. Cycles, same-wave dependencies, and missing producers are errors.
- **Final wave:** `### F1 —` through `### F4 —` in order, each with a box. With `ui: yes`, `### Automated UI QA` is the last gate.
- **Success criteria:** every gap has a row, and a named todo closes it.
- **Citations in prose:** every backticked `path:line` or `path:start-end`, and a shorthand `:line` after a path on the same line, must fall inside an Evidence index citation for that path. Fenced code and the Review, Build, and Result review sections are not scanned.

A `draft` plan needs only the frontmatter, the section headings, Scope, Questions, and a valid Evidence index. Its frontier and pending coverage may be open.

## Evidence index

One fenced `json` object under `### Evidence index`. The heading may hold several fenced `json` blocks instead: the validator merges them (arrays concatenate, nested objects merge one level deep, other later keys replace earlier ones), and a duplicate citation or flow id across blocks is an error. A `planned` or `reviewed` plan may not contain a skeleton placeholder line, `<!-- todo: ... -->` (error `PLACEHOLDER`).

```json
{
  "schemaVersion": 1,
  "citations": [
    { "id": "C1", "kind": "source", "path": "src/app.ts", "startLine": 10, "endLine": 12,
      "excerpt": "export function start() {", "sha256": "<64 hex>" },
    { "id": "C2", "kind": "planned", "path": "src/new.ts", "createdBy": "T2" },
    { "id": "C3", "kind": "self" },
    { "id": "C4", "kind": "external", "url": "https://example.com/docs/v2", "version": "2.1",
      "accessed": "2026-09-29", "excerpt": "<quoted contract>", "obligation": "MH1" }
  ],
  "coverage": [
    { "id": "V1", "paths": ["src/app.ts"], "searches": ["rg -n start src"], "producers": ["src/app.ts"],
      "consumers": ["src/cli.ts"], "citationIds": ["C1"], "state": "inspected" }
  ],
  "frontier": [],
  "flows": [
    { "id": "FL1", "requirementIds": ["MH1"], "todoIds": ["T1"], "evidenceIds": ["C1"],
      "entry": "cli start", "startingState": "clean install", "effects": ["write config", "register hook"],
      "recovery": "restore config from backup", "counterexample": "failure after the config write" }
  ],
  "baseline": { "revision": "<commit>", "dirty": [], "checks": [{ "command": "bun test", "exit": 0, "result": "12 passed" }] }
}
```

- A `source` excerpt must equal the cited lines after trimming leading and trailing whitespace and normalizing line endings. Internal whitespace must match. The `sha256` covers the whole file, so the excerpt tolerance cannot hide drift.
- Paths are project-relative. Absolute paths, `..`, and symlinks that resolve outside the project are errors.
- A `planned` path must not exist yet, unless the plan already has a Build section. Existing code cannot be relabelled as planned to avoid reading it.
- Coverage `state` is `inspected` (needs at least one citation), `excluded` (needs a boundary `reason`), or `pending`. Pending rows and a non-empty `frontier` are allowed only in a draft.
- An empty `flows` list needs `noRuntimeFlowReason`.

## Gate record

Each review round ends with one fenced `json` object under `#### Gate record`:

```json
{
  "schemaVersion": 1,
  "round": 2,
  "planDigest": "<canonical spec digest>",
  "repository": { "revision": "<commit>", "dirty": ["docs/plans/x.md"] },
  "sources": [{ "path": "src/app.ts", "sha256": "<64 hex>" }],
  "evidence": [
    { "id": "P1", "kind": "probe", "command": "bun test x", "inputs": "fixture A", "exit": 1,
      "result": "hook printed {}", "omissions": "no network" },
    { "id": "Q1", "kind": "planned-qa", "command": "bun test y" }
  ],
  "obligations": [
    { "id": "O1", "targets": ["MH1", "T1.start", "T1.acceptance", "T1.qa"], "evidenceIds": ["C1", "P1"],
      "observed": "<actual result>", "plannedQa": "Q1", "status": "verified" }
  ],
  "flows": [{ "id": "FL1", "status": "verified", "counterexample": "failure after the config write", "evidenceIds": ["P1"] }],
  "checks": { "A": { "status": "verified", "evidenceIds": ["C1"], "observed": "<result>" } },
  "blockers": [],
  "verdict": "OKAY"
}
```

`checks` holds A through J. Evidence kinds are `source`, `probe`, `documentation`, `plan-inspection`, and `planned-qa`. Evidence ids may also name Evidence index citations.

**Required targets.** Every one needs a required obligation (`required` omitted or `true`): each `MH<n>` and `MN<n>`; `T<n>.start`, `T<n>.acceptance`, and `T<n>.qa` for every todo; `dep:T<a>:T<b>` for every dependency; `F<n>.acceptance` for every final gate; `flow:<id>` for every Evidence index flow; `contract:<id>` for every external citation; and `check:A` through `check:J`. Setting `required: false` does not cover a target.

**Evidence rules.** A verified or contradicted obligation cites evidence. Evidence of kind `planned-qa`, or a `planned` citation, alone cannot support it: a future test is not evidence. Every contradicted obligation is named by a blocker with `location`, `failure`, `evidenceIds`, and `fix`.

**Expected verdict**, in this order:

1. Any contradicted required obligation, flow, or check gives REJECT.
2. Otherwise, any uncovered target, unverified obligation, or missing or unverified flow or check gives INCOMPLETE.
3. Otherwise, OKAY.

The recorded verdict must equal the expected verdict. OKAY sets `status: reviewed`. REJECT and INCOMPLETE set `status: planned`. The rendered round must agree with the JSON: the `**Verdict:** PLAN-REVIEW: ...` line and its blocker count; a `**Scope:**` line containing `<v>/<r> required obligations verified` and `<v>/<r> critical flows verified`; the last row of the history table; and one `#### Coverage and evidence` row per obligation id, with the same status in its last cell. `planDigest` must equal the current spec digest, and every `sources` entry must match the current file bytes. `gateRecordDigest` is the SHA-256 of the gate record's canonical JSON.

## Build record and snapshots

`plan-builder` appends `## Build` with one fenced `json` object under `### Build record`:

```json
{
  "schemaVersion": 1,
  "runId": "2026-09-29-feature-r1",
  "runDir": "silly-skills/plan-builds/2026-09-29-feature-r1",
  "repository": { "kind": "git", "rootCommits": ["<commit>"], "branch": "feat/x" },
  "baseRevision": "<commit>",
  "approval": { "specDigest": "<digest>", "round": 2, "verdict": "OKAY", "gateRecordDigest": "<digest>" },
  "baseline": { "snapshot": "silly-skills/plan-builds/2026-09-29-feature-r1/baseline", "manifestSha256": "<digest>", "stateDigest": "<digest>" },
  "skill": { "name": "plan-builder", "version": "0.1.0", "sha256": "<digest>" },
  "receipts": []
}
```

A snapshot is a directory with `manifest.json` and `objects/<sha256>` raw bytes. In a git project its location is relative to the Git directory: resolve it with `git rev-parse --git-path <snapshot>`. An absolute location is used as given. The manifest has `schemaVersion: 1`, `kind: "silly-skills.build-state"`, `runId`, `repository`, `baseRevision`, `headRevision`, `approvedSpecDigest`, `plan` (`path`, `sha256`, `specDigest`), `administrative` (`plan`, `reports`), `includes`, `stateDigest`, and `paths`.

Each `paths` entry has a `path` and three layers: `head`, `index`, and `worktree`. A layer is `{"state": "absent"}`, `{"state": "unavailable"}` (HEAD and index outside git), or `{"state": "file" | "symlink", "mode", "length", "sha256"}`. A symlink layer stores the link target, never the target's contents. The path set is the union of HEAD, the index (`git ls-files --stage -z`), non-ignored untracked files, every walked `includes` path, and every path of the snapshots the capture carried forward. It keeps deleted, restored, and newly ignored paths as `absent` or retained entries.

`stateDigest` is the SHA-256 of the canonical JSON `{"headRevision": ..., "paths": [...]}`. Declared report paths are left out. The plan's working-tree layer is replaced by `{"state": "plan", "specDigest": ...}`, so appending a receipt is not drift. Paths sort by UTF-8 bytes.

A receipt:

```json
{
  "seq": 3, "todo": "T1", "event": "pass", "state": "passed", "prev": "<digest of receipt 2>",
  "before": { "snapshot": "...", "manifestSha256": "...", "stateDigest": "..." },
  "after": { "snapshot": "...", "manifestSha256": "...", "stateDigest": "..." },
  "changedPaths": ["src/app.ts [worktree]"],
  "checks": [{ "id": "acceptance", "command": "bun test", "exit": 0, "expectedExit": 0, "passed": true, "observed": "12 passed" }],
  "prerequisites": [{ "targets": ["T2.start"], "sources": [{ "path": "src/app.ts", "sha256": "..." }], "status": "holds", "observed": "..." }],
  "commit": { "sha": "<commit>" },
  "note": ""
}
```

`changedPaths` lists, as `<path> [<layer>]`, every path and layer whose entry differs between the before and after manifests, and is empty when there is no after snapshot. It compares raw layers, so the plan appears whenever a receipt or a box was written between the two snapshots; only `stateDigest` normalizes the plan. `event` is `start`, `checkpoint`, `pass`, `block`, or `recovery`. `state` is `active`, `passed`, or `blocked`. `prev` is the SHA-256 of the previous receipt's canonical JSON, or `null` for the first receipt. A todo with no commit records `{"none": "<reason>"}`.

## Resume rules

`--review --resume` passes only when all of these hold:

- The current spec digest equals `approval.specDigest`.
- The live plan is `status: reviewed`, its latest round is `approval.round`, that round's gate record digest equals `approval.gateRecordDigest`, and its verdict is OKAY. A later REJECT, INCOMPLETE, or superseding round blocks resume.
- The baseline and every receipt snapshot exist, match their recorded manifest digests, and verify: every object's length and digest, and the recomputed `stateDigest`. The baseline's repository matches the Build record and the current project.
- The archived gate record's sources and the Evidence index citations match the baseline bytes, not the current files.
- The receipts chain: sequential `seq`, correct `prev`, and each `before` equals the previous end state. One todo is active at a time. A todo starts only after its dependencies passed.
- A `pass` receipt records checks that all passed. For `Commit: yes`, it names the commit, and its after-state HEAD equals that commit.
- Every `- [x] Done` box has a passed receipt. A passed receipt with an Open box is listed in `reconcileBoxes`; set the box without repeating the work.
- The current project state equals the last receipt's end state. Otherwise the result lists `drift`, sets `recoveryRequired: true`, and names the `unresolvedAction`.
- No recorded prerequisite recheck for a pending todo says `fails`. Pending todos whose referenced paths changed get `requiredRechecks`. Record those rechecks in that todo's start receipt.

`nextTodo` is the active todo, or else the first todo without a passed receipt in T0-then-wave order, or else the first open final gate. A `recovery` receipt records observed effects after drift, or after effects that began before a start receipt. It makes its todo active.

## Error codes

| Code | Meaning |
| --- | --- |
| FRONTMATTER, SECTION, QUESTIONS, DESIGN, PLACEHOLDER | Plan shape |
| REQUIREMENT_ID, GAP_MAP, SUCCESS_MAP | Identifiers and gap mapping |
| TODO, DEPENDENCY, WAVE, FINAL_WAVE | Todos, dependency graph, waves, and gates |
| LEGACY_FORMAT, EVIDENCE_INDEX | Missing or malformed Evidence index |
| CITATION, EXCERPT, CITATION_DRIFT, PATH, PLANNED_EXISTS, UNINDEXED_CITATION | Citations |
| COVERAGE, FRONTIER, FLOW, BASELINE | Investigation record |
| GATE_RECORD, GATE_EVIDENCE, GATE_BLOCKER, PLANNED_QA_AS_EVIDENCE, VERDICT, STATUS, RENDERED_MISMATCH | Review round |
| STALE_REVIEW, SOURCE_DRIFT | The review no longer matches the current plan or sources |
| BUILD_RECORD, SNAPSHOT_MISSING, SNAPSHOT_CORRUPT, REPOSITORY_MISMATCH, APPROVAL_BASELINE_MISMATCH | Build record and snapshots |
| SPEC_CHANGED, APPROVAL_CHANGED | The approval a build started from no longer holds |
| RECEIPT_CHAIN, RECEIPT_ORDER, DEPENDENCY_ORDER, PASS_WITHOUT_CHECKS, COMMIT, DONE_WITHOUT_RECEIPT | Receipts |
| STATE_DRIFT, PREREQUISITE_FAILED | The current state or a premise no longer matches the record |
| UNREADABLE | The plan cannot be read |
