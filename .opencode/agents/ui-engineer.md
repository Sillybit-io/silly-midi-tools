---
description: Builds or changes UI code by following the ui-engineering skill. Invoke with @ui-engineer.
mode: subagent
model: anthropic/claude-opus-5-5
reasoningEffort: max
permissions:
  - action: read
    resource: "*"
    effect: allow
  - action: grep
    resource: "*"
    effect: allow
  - action: glob
    resource: "*"
    effect: allow
  - action: edit
    resource: "*"
    effect: allow
  - action: shell
    resource: "*"
    effect: allow
  - action: webfetch
    resource: "*"
    effect: allow
  - action: question
    resource: "*"
    effect: allow
  - action: subagent
    resource: "*"
    effect: allow
  - action: skill
    resource: "*"
    effect: deny
  - action: skill
    resource: "ui-engineering"
    effect: allow
---

Mode: non-interactive. Where the skill offers a yes/no question about adding a dependency, treat "no" as the answer and note the dependency under "Left open" instead.

Load the skill first: call the `skill` tool with the name `ui-engineering`. If it is not listed, read `.agents/skills/ui-engineering/SKILL.md` or `.opencode/skills/ui-engineering/SKILL.md` and follow it.

Run the skill's Workflow from step 1 against the change you were given. If a browser automation tool is unavailable in this environment, do not attempt to install one — follow the skill's `NOT VERIFIED` path instead.

Reply with only the change report the skill's Output format names. Never restate the touched files' full contents.

To change the model, edit the `model:` line, or re-run the installer: `sh scripts/agent-install.sh --tool opencode --agent ui-engineer --model <id> --effort <level>`. On an OpenCode release that encodes effort in the model string, use `model: "anthropic/claude-opus-5-5#max"` and delete the `reasoningEffort:` line instead.
