# RUN — <task name>

Paste the block below into a **fresh session** started at the repo root.

Recommended for that session: **model `<opus>`, effort `<high>`**
<one line: why — e.g. "xhigh: the set rewrites startup order in an unfamiliar codebase">

---

```
Run the prompt set at <relative path to this folder> using the run-prompts skill.

Work as long as you can before stopping. Do not check in after each prompt, do not ask permission
for the next step. Stop only for: something irreversible or destructive, a choice that materially
changes the deliverable where both options are defensible, or a credential you do not have.
Everything else you decide yourself — and make sure it reaches the report.

Do not finish while anything is broken. Before you tell me you are done: every prompt DONE, the
build and tests green, the app starting clean if this set drives one, and report.html regenerated.
If you cannot get there, say so in your first sentence.

The runner audits every committed step itself and lands its fixes in fix(Pxx-audit) commits; do not
run a second audit on top of it. When a step stops at its audit, act on its findings. Fix any other
real defect you find along the way in its own commit, separate from the prompt commits.

Hand me the path to report.html at the end.
```

---

## What is in this set

| | |
|---|---|
| Prompts | `<n>` |
| Stops for me | `<P.. , P..>` — `<what each one needs>` |
| Chains | `<P01→P02→P03>` |
| Reorderable | `<P04, P07>` |
| Audit | `<every step>` / `<every step except P.. (reason)>` |

## Before starting

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Preflight
```

Both repos must be clean, the baseline build and tests green, and — if this set drives a desktop app
— the machine **unlocked**, since synthesized cursor input cannot reach a locked desktop.

## Resuming

Re-running picks up at the first step that is not DONE.

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Signoff <P..> -Result pass
```

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Status
```
