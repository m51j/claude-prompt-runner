---
name: run-prompts
description: Execute a numbered prompt set (P01, P02, …) written by the write-prompts skill, running each prompt in its own fresh `claude -p` session with independent verification gates, an automated diff review, an independent audit that hunts and fixes real defects after every step (on by default), a commit per step, rollback on failure, and an Arabic HTML report. Use when the user points at a folder containing manifest.psd1 and a prompts/ directory, says "run the prompts", "نفّذ البرومبتات", asks to continue or resume a prompt set, to sign off a step, or to regenerate the report. Also use when a RUN.md tells you to orchestrate a prompt set.
compatibility: Requires the `claude` CLI, git, and PowerShell 7 (`pwsh`). The App-Smoke helper is Windows-only; web projects need no helper.
metadata:
  version: 1.2
---

# Running a prompt set

You are the **orchestrator**. You do not implement the prompts — a separate fresh session does each
one. You drive the runner, judge what it reports, fix what it surfaces, and hand back a finished
result with an honest report.

## Why a runner rather than one long session

- **A fresh session per prompt.** Clean context each step, and every step stays independently
  resumable (`claude --resume <sessionId>`) for debugging afterwards.
- **Verification you perform, not verification the session claims.** In the run this was built from,
  two sessions reported PASS without having done the job. Both were caught only because the runner
  re-ran the checks itself. **Never trust a self-reported success.**
- **A commit per step**, which is the rollback boundary a dependency chain needs.
- **An independent audit of every committed step** (on by default). Gates prove assertions and
  DiffReview proves the diff matches the task; neither asks whether the code is *right*. A fresh
  read-only session hunts the step for real defects, a fix session reproduces each with a failing
  test before fixing it (or drops it), the gates re-run, and the fixes land in their own
  `fix(Pxx-audit)` commit. On the project where this was first done by hand it found real defects
  in almost every step the gates had passed; sets run without it carried the same classes of defect
  silently. Details: [references/manifest-and-gates.md](references/manifest-and-gates.md#the-independent-audit).

## The commands

Run from the set folder (the one holding `manifest.psd1`).

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Preflight
```

| Switch | Effect |
|---|---|
| `-Preflight` | tools, clean trees, baseline Build/Test, app launches. **Always run first** |
| `-DryRun` | prints every planned invocation, cwd, model and gate. Spawns nothing |
| `-Status` | the ledger plus recorded cost |
| `-Report` | regenerate `report.html` (Arabic) from the ledger |
| `-Only P07` / `-From P05 -To P09` | one step or a range |
| `-Signoff P10 -Result pass\|fail` | clear a human sign-off stop |
| `-Force` | re-run a step already DONE or FAILED |
| `-NoAudit` | skip the audit for this invocation; on a step in `AUDIT_FAILED`, accept it as it stands |

With no switch it runs from the first step that is not DONE and stops at the first sign-off gate or
failure.

## How to behave

**Work as long as you can before stopping.** The user's reason for using this is that it does not
consume their time. Do not stop to narrate progress, ask permission for the next step, or check in
after each prompt.

**Stop only for three things.** Anything else you decide yourself and record:

1. an action that is irreversible or destructive,
2. a choice that materially changes the shape of the deliverable where both options are defensible,
3. a credential or permission you do not have.

Every other choice: make it, and make sure it reaches the session's `decisions[]` so it lands in the
report. A decision recorded is not a decision hidden.

**Never end with known breakage.** Before reporting finished: every prompt DONE, the manifest's Build
and Test green, the app starting clean if the set has an `AppExe`, and `report.html` regenerated. If
you cannot reach that state, say so in your first sentence rather than closing on an optimistic
summary.

**Fix what the run surfaces.** The runner's audit already hunts each step and lands its fixes in
`fix(Pxx-audit)` commits. Beyond that, sessions report `deviations[]` and `followups[]`; real defects
found along the way are worth fixing in their own commits, separate from the prompt commits, so any
one can be reverted alone. Do not run a second audit of your own on top of the runner's - read its
findings (`results/<Id>-audit.json`, `-fix.json`) and act on what it could not fix. In the originating run that produced six fixes beyond the 23 prompts, four of them
data-loss or function-breaking bugs nobody had asked about.

## What the gates cannot see

The mechanical gates answer "does the tree satisfy these assertions". These slip past them:

- **Wrong code that satisfies the assertions.** The independent audit is for this. When a step stops
  in `AUDIT_FAILED`, the step is committed but its fixes failed the gates twice: read the findings
  and the saved patch, fix by hand in a commit of your own, then `-Only Pxx -NoAudit` to accept; or
  re-run to give a new fix session a try. Never accept unfixed high-severity findings silently -
  record them in `results/_orchestrator.json` so they reach the report.
- **Scope creep.** A session can pass every gate while also refactoring things nobody asked for. The
  `DiffReview` gate catches most of it automatically — but when a set has no such gate, read
  `git diff <baseCommit>..` yourself before moving on.
- **Coherence.** Per-step gates prove each step in isolation, never that the steps fit together. That
  is what the set's final audit prompt is for; if the set lacks one, do the check yourself at the end.
- **Context bloat.** Every turn re-sends the whole conversation, so a session that swallowed its test
  logs and every reference file pays for them on every later turn and thinks worse for it. The
  protocol now tells sessions to delegate bulk reading to subagents, keep logs in files, and run the
  narrow tests while iterating. Watch `state.json` (`attemptCosts`) and the session's
  `cache_read_input_tokens`: a step whose cost is far out of line with its output is one that should
  have been split or that ignored the discipline - read its log before running the next.

## References

- [references/manifest-and-gates.md](references/manifest-and-gates.md) — the manifest schema, every
  gate type including `DiffReview`, tiers, and per-prompt model/effort.
- [references/driving-apps.md](references/driving-apps.md) — verifying a desktop app with
  `App-Smoke.ps1`, verifying a web app with the browser tools, and the traps in both.
- [references/failure-and-recovery.md](references/failure-and-recovery.md) — what to do when a step
  fails, sign-off stops, and the report.
