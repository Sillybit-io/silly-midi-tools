# Evidence index

Read this file when you write `### Evidence index` under Scope, and again before you set `status: planned`. The index is one fenced `json` object. The validator bundled with `plan-review` checks it: run `bun <plan-review-base>/scripts/validate-plan.ts <plan> --root <project>`, where `<plan-review-base>` is the installed `plan-review` skill directory. The full grammar is that skill's `references/validator-contract.md`.

## Shape

```json
{
  "schemaVersion": 1,
  "citations": [],
  "coverage": [],
  "frontier": [],
  "flows": [],
  "baseline": {}
}
```

## Appending entries

Do not write or rewrite the index as one large object. Under `### Evidence index`, the skeleton holds one block with `schemaVersion`, `baseline`, and empty arrays. Add each citation, coverage row, frontier item, or flow as its own fenced `json` block directly below, holding only that key:

````markdown
```json
{ "citations": [{ "id": "C7", "kind": "source", "path": "src/app.ts", "startLine": 10, "endLine": 12, "excerpt": "...", "sha256": "..." }] }
```
````

The validator merges every block under the heading: arrays concatenate, `baseline` merges one level deep (its `checks` arrays concatenate), and any other later key replaces an earlier one. A duplicate citation or flow id across blocks is still an error. Insert each new block above `## Research`, so the anchor is unique. A plan with one big block stays valid.

Appending only adds. It never updates: a coverage row `V1` appended as `inspected` after an earlier `V1` that is `pending` leaves both rows, and the pending one still fails validation once the plan is `planned`. So change an entry that already exists in place. Resolve a pending coverage row by editing its `state` and `citationIds` where it sits. Resolve a frontier item by deleting its entry. Refresh a citation's `excerpt` and `sha256` on resume, record an owner's answer, or fix a review finding the same way, touching only the fields that change. Never rewrite a whole block or the whole index to do it.

## Citations

Every backticked `path:line` or `path:start-end` in the plan, outside code fences, must fall inside a citation for the same path. Several prose references can share one citation.

| Kind | Fields | Rule |
| --- | --- | --- |
| `source` | `id`, `path`, `startLine`, `endLine`, `excerpt`, `sha256` | `excerpt` is the literal text of those lines. `sha256` is the SHA-256 of the whole file as read |
| `planned` | `id`, `path`, `createdBy` | A file a todo creates. The path must not exist yet |
| `self` | `id` | T0's reference to this file |
| `external` | `id`, `url`, `version`, `accessed`, `excerpt`, `obligation` | A contract a todo relies on, at the version the project uses, or `rolling` with the date |

Copy excerpts from the file, never from memory. Compute `sha256` from the bytes you read, for example `shasum -a 256 <path>`. Paths are relative to the project root. The excerpt check trims leading and trailing whitespace and normalizes line endings. It does not normalize internal spaces.

## Coverage

One row per relevant area: `id`, `paths`, `searches` (command and scope), `producers`, `consumers`, `citationIds`, and `state`. `inspected` rows cite evidence. `excluded` rows carry a `reason`. `pending` rows are allowed only in a draft.

## Frontier

Each open item has `item`, `reason`, and `nextAction`. A planned plan has an empty frontier.

## Flows

One entry per critical flow: `id`, `requirementIds` (MH ids), `todoIds`, `evidenceIds`, `entry`, `startingState`, ordered `effects`, `recovery`, and one `counterexample` to test. A flow is critical when its failure loses data, strands a user after a state change, or breaks a required integration. When the change has no runtime flow, leave `flows` empty and set `noRuntimeFlowReason`.

## Baseline

`revision` (or `"nonGit": true`), `dirty` (paths and states at the time of writing), and `checks`: each project command you ran, with `command`, numeric `exit`, `result`, and `limitations`. Record failures as they are. A red baseline is information for the builder, not a reason to hide the check.

## Before `status: planned`

Run the validator. Fix every error it reports. A structural pass does not make the plan correct; it makes the citations and mappings checkable. When Bun or the `plan-review` skill is missing, the plan cannot be validated: keep `status: draft` and name the missing dependency in the TL;DR.
