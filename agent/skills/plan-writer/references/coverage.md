# Coverage closure

Read this file before exploring the codebase, when resuming a draft, and when a fix-only step reopens investigation. Investigation ends when coverage is closed, not when a count runs out. By the owner's decision, this planning skill has no file, line, search, page, or pass budget. That decision overrides the work-budget rule in `skill-writer` for planning investigation only. A host timeout or interruption produces a checkpoint, never a planned file.

## Seeds

Start from everything the request touches:

- The requested behavior and the files the request names.
- Entry points that reach that behavior: commands, routes, hooks, jobs, installers, and exported functions.
- Artifacts the change will create, move, or delete.
- The tests and fixtures that pin the current behavior.

## Follow every edge

For each seed, find what it depends on (producers) and what depends on it (consumers). Repeat for every relevant file you find. Check these edge kinds, because a plain import search misses most of them:

| Edge | How to find it |
| --- | --- |
| Imports and calls | Search for the symbol, the module path, and re-exports |
| Registrations by string | Search for the module or command name as a string: plugin maps, dynamic imports, route tables, tool manifests |
| Path strings | Search for literal paths the change moves or renames, in code, scripts, configuration, and docs |
| Data formats | Search for the key, file, or wire format the change alters, and for every reader of it |
| Configuration | Files and environment variables that set the behavior |
| Generated and installed files | Build outputs, templates, installers, update and migration paths |
| Documentation commands | Commands and flags quoted in READMEs and runbooks |
| Failure and recovery | Error handlers, retries, rollbacks, and cleanup that run when the change fails |
| Tests | Tests that pin current behavior, including snapshot and fixture files |

Search beyond the files the request names. Use synonyms and the old and new names. Record each search: the command or query, its scope, and what it found.

An empty or failed search is not proof of absence. Record its scope and the synonyms tried. When a search tool is unavailable, record that and use another way to read the same scope.

## Account for each relevant edge

Every relevant edge ends in one of two states:

- **inspected** — you opened the code at that location and recorded a citation with a literal excerpt of the lines you rely on.
- **excluded** — you name the boundary reason it cannot affect the change, such as "owner data copied byte for byte and never parsed", and cite the evidence for that reason.

"Probably fine" is not a reason. An edge still unread stays `pending`, and `pending` rows block the planned state.

## Frontier and closure

Keep the frontier: the pending paths, searches, and unverified external contracts, each with why it is open and the next action. Coverage is closed when:

1. every discovered relevant edge is inspected or excluded,
2. every external contract a todo relies on is checked at its target version, and
3. the frontier is empty.

Unknown product choices belong to the owner and become questions. Unread files and unfinished searches belong to you. Never turn an unread file into an owner question such as "needs a look at <path>".

## Checkpoints and resume

The plan file exists from the skeleton step on, and each citation, coverage row, and frontier item was appended as you found it, so the draft is already current. Before the session ends, append the frontier items and the next action, one block each. Keep `status: draft`.

On resume, re-read the draft from disk. Recompute the SHA-256 of every cited source. When a source changed, re-read its cited lines and update the excerpt, or record the change. Then work the frontier before anything else, even when `## Research` and `## Questions` are already filled. New evidence can add seeds. Research and questions repeat when that evidence demands it.

## Fix-only follow-up

A blocker about coverage, a flow, or a missed consumer reopens investigation along that blocker's affected paths. Follow those edges to closure, update the coverage rows, citations, critical flows, and the QA that proves the fix. Do not redesign unrelated sections.

## Delegating discovery

When a `plan-scout` persona is available and allowed, you may send it one bounded discovery question: the seed, the edge kinds, and the scope. It returns paths, excerpts, and searches, never a verdict. Re-read each returned excerpt in the file before you cite it. When the scout is unavailable or denied, search yourself. Discovery never waits on delegation.
