## Prompt

> Use the plan-scout subagent to find every producer and consumer of app/core/rate_limit.py in this project. Then reply with its report exactly as it returned it.

Both branches ran on 2026-09-29 in Claude Code 2.1.283 with `claude -p`, each in a fresh copy of a small Python service whose rate limiter has 23 relevant producers and consumers: direct and transitive callers, a plugin loaded by string, config, key-format readers, an ops script, docs, and tests. The main session ran on `claude-fable-5-1`. In the with-skill branch it launched the installed `plan-scout` persona, which ran on `claude-sonnet-5`. The without-skill branch asked the same session the same question without the persona: "Find every producer and consumer of app/core/rate_limit.py in this project. Do not change any file. Reply with what you found." An evaluator-only key listing all 23 relevant files was kept out of what either run could see. Absolute paths in the reports are shortened to `<fixture copy>`. Neither run changed a project file.

## Without skill

The baseline is a good answer. It named 21 of the 23 relevant files, including the plugin loaded by string. It missed two of the three throttled route modules. It recorded no searches, so a planner cannot tell a file it ruled out from one it never looked at. Its opening:

```markdown
No files were changed. Here is the full dependency map for `app/core/rate_limit.py`.

**What the module exposes**

- `RateLimited` exception, carrying `key` and `retry_after`.
- `check_rate_limit(subject, now=None)`, which increments a fixed-window counter and returns the remaining allowance.

**Producers (what rate_limit.py depends on)**

- `app/config/load.py` supplies `load_limits`, which reads `config/limits.json` and honors the `RATE_LIMIT_WINDOW` environment variable.
- `app/store/keys.py` supplies `limit_key`, which builds the `rl:<subject>:<window>` key.
- `app/store/memory.py` supplies the shared `store` singleton whose `incr` does the counting.
- `config/limits.json` is the data source for `window_seconds` and `max_requests`.

**Direct consumers (static imports)**

- `app/api/middleware/throttle.py:3` imports both symbols. It wraps handlers, sets the `X-RateLimit-Remaining` header, and converts `RateLimited` into a 429 response.
- `app/jobs/digest_mailer.py:2` imports both symbols to skip users who are over their digest window.
- `app/workers/retry.py:2` imports `RateLimited` and queues failed tasks using `error.retry_after`.
- `tests/test_rate_limit.py:3` and `tests/test_inspect.py:4` import it directly.

**Dynamic consumer**
```

## With skill

The scout named all 23 relevant files. It quoted 18 excerpts, each matching the cited lines exactly, and it recorded every search, including the empty ones. Excerpts from its report:

```markdown
SCOUT-REPORT
Question: `app/core/rate_limit.py` (module `app.core.rate_limit`, symbols `check_rate_limit`, `RateLimited`); producers and consumers; scope: whole working directory `<fixture copy>` (all tracked source, config, tests, docs, ops — no `.claude/` skill files inspected as they are the invoking skill itself).

Searches:
| Query | Scope | Hits |
| --- | --- | --- |
| `rate_limit` | whole dir | 17 lines (7 files + config/plugins.json) |
| `check_rate_limit\|RateLimited` | whole dir | 24 lines (6 code files) |
| `app\.core\.rate_limit` | whole dir | 6 lines (5 code files + registry string) |
| `from app\.core import\|from \.core import\|from \.\. import\|from \. import` | whole dir | 0 |
| `import app\.core\.rate_limit\b` (bare import form) | whole dir | 0 |
| `core\.rate_limit` | whole dir | 6 lines (same as dotted-path search) |

Findings:
| Path | Lines | Relation | Edge | Why it matters |
| --- | --- | --- | --- | --- |
| `app/jobs/digest_mailer.py` | 1-14 | consumer | Python import (`from app.core.rate_limit import RateLimited, check_rate_limit`) | Digest job calls `check_rate_limit` per user each run; a signature or exception-type change breaks it. |
| `app/workers/retry.py` | 1-12 | consumer | Python import (`from app.core.rate_limit import RateLimited`) | Catches `RateLimited` from any task and requeues using `error.retry_after`; depends on the exception's shape. |
| `app/api/middleware/throttle.py` | 1-16 | consumer | Python import + decorator | Core of the HTTP throttling middleware; calls `check_rate_limit(request["client"])`, catches `RateLimited`, and passes it to `too_many_requests`. |
| `app/api/errors.py` | 1-9 | consumer | Attribute access on the exception (`error.retry_after`, `error.key`) | `too_many_requests` builds the 429 response directly from `RateLimited` instance fields, so it is coupled to the exception's attributes though it never imports the module. |
| `app/api/routes/messages.py` | 1-8 | consumer (indirect) | Decorator usage of `throttle` | Applies `@throttle`, which wraps `check_rate_limit`; a change to throttling semantics changes this route's behavior. |
| `app/api/routes/search.py` | 1-8 | consumer (indirect) | Decorator usage of `throttle` | Same as messages.py. |

Queue:
| Relevant file | Searches for files that use it, and for its inputs | New files found |
| --- | --- | --- |
| `app/core/rate_limit.py` | `rate_limit`; `app\.core\.rate_limit`; `check_rate_limit\|RateLimited`; `core\.rate_limit`; `from \.rate_limit import\|import rate_limit`; `import app\.core\.rate_limit\b` (all whole dir) | `app/jobs/digest_mailer.py`, `app/workers/retry.py`, `app/api/middleware/throttle.py`, `app/plugins/registry.py`, `config/plugins.json`, `tests/test_rate_limit.py`, `tests/test_inspect.py` |
| `app/jobs/digest_mailer.py` | `digest_mailer\|send_digests` (folded into `rate_limit`/general reads); read `app/jobs/scheduler.py`, `tests/test_digest.py` | `app/jobs/scheduler.py`, `tests/test_digest.py` |
| `app/workers/retry.py` | `run_with_retry` — no hits beyond its own definition | none |
| `app/api/middleware/throttle.py` | `throttle\|Throttle` (whole dir) | `app/api/routes/messages.py`, `app/api/routes/search.py`, `app/api/routes/uploads.py`, `tests/test_throttle.py` |

Inventory: 41 non-`.git` files in scope (32 under `app/`, 2 under `config/`, 5 under `tests/`, 1 `docs/operations.md`, 1 `ops/reset-limits.sh`, 1 top-level `README.md`); all 41 returned by a search or read directly …

Complete: yes — the Inventory accounts for every non-`.git` file in scope; all producer and consumer edges (direct imports, decorator usage, transitive callers, the plugin-registry string mapping, shared key-format/config/env-var producers, and doc/ops references) were traced to a stable point, and no item is pending.
```

A second run on a copy where `app/workers/retry.py` was unreadable found the other 22 files, then reported the gap instead of guessing:

```markdown
Pending:
- `app/workers/retry.py` — unreadable via both the Read tool and the Grep tool (`EACCES: permission denied` / "could not be opened (EACCES) — it is unreadable, or is being replaced concurrently"). Could change: whether `app/workers/` is a producer or consumer of `app/core/rate_limit.py` (e.g., a retry loop that calls `check_rate_limit` or catches `RateLimited`), and whether it is the missing caller of `app/plugins/registry.py`'s `load_enabled()` or `app/jobs/scheduler.py`'s `run()` (neither of which has a located caller in the readable scope). This file is also the only one shown as modified in the git status snapshot, so its content is directly relevant to any pending change. Next action: obtain read permission on `app/workers/retry.py` (or an equivalent readable copy, e.g. via `git show`) and re-run the same search set against it.

Complete: no — `app/workers/retry.py` could not be read, so its relation to `app/core/rate_limit.py` (if any) is unconfirmed, and the caller of `app/plugins/registry.py:load_enabled()` and `app/jobs/scheduler.py:run()` was not located in the readable scope.
```

On Claude Haiku 4.5, the same skill found all 23 files in 5 of 8 runs, and twice claimed completeness while missing consumers. The scout's suggested model is Sonnet 5 for that reason.
