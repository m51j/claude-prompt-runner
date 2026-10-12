# Failure, sign-off, and the report

## When a step fails its gates

The runner has already retried once with the verbatim failure text (a retry is a fix-up session on
the same tree, not a fresh start — and a creep-only failure got a scope-trim first), then
`git reset --hard` to the step's base commit and `git clean -fd`. Nothing downstream ran, because
the chain depends on it.

Read `logs/<Id>/gate-failure-*.txt` and the session log, then decide **which of three things is
wrong** — this is the judgement the runner cannot make:

**The work is wrong.** The session misunderstood or did it badly. Re-run with `-Force`; if the prompt
was ambiguous, sharpen it first.

**The prompt is wrong.** It named a file that moved, described an approach that does not fit, or
asked for something the codebase makes impossible. Fix the prompt file, then `-Force`. The set is not
sacred — it was written without reading every file, and that is the accepted trade.

**The gate is wrong.** It asserts something that was never the real requirement, or greps for a
pattern that legitimately still exists. Fix the manifest, then `-Force`.

**Never loosen a gate to make a step pass.** If you are tempted, the honest options are: fix the
work, fix the prompt, or stop and tell the user the acceptance criterion cannot be met.

To inspect exactly what the session did and why, resume it — the ledger holds its id:

```bash
claude --resume <sessionId>
```

## Reading a DiffReview failure

`scope_creep` used to mean, almost always, a prompt whose folder fence was tighter than the work:
four of eight steps in one real run were failed for a DI registration or a route mapping the task
could not function without. Two things now stand between that and a rollback: the reviewer is
given the implementer's report and told that *necessary wiring* is not creep, and a `scope_creep`
that is the only failing gate triggers a cheap **scope-trim** session (revert what was named, or
justify it in `scope_justification`) before any full retry. Read `logs/<Id>/scope-creep-*.txt` and
`trim-*.json` to see what it did. If a step still fails on creep after the trim, the diff really
does carry unrequested work: sharpen the prompt's **Out of scope** (name the neighbouring thing and
which step owns it) and `-Force`, rather than dropping the gate.

`incomplete` and `wrong` mean the reviewer thinks the diff does not satisfy the task. Check it
yourself before acting — the reviewer sees only the diff and the prompt, so a change that is correct
because of something elsewhere in the repo can read as wrong to it. If the reviewer is mistaken, say
so in your summary and `-Force` past it; do not silently delete the gate.

## When a step stops at its audit (`AUDIT_FAILED`)

The step's own work is committed and passed its gates; what failed is the fix for the audit's
findings (twice), or the audit session returned nothing usable. Read:

- `results/<Id>-audit.json` — the findings, each with a reproduction
- `results/<Id>-fix.json` and `logs/<Id>/audit-fix-failure-*.txt` — what the fixer did and which gate it broke
- `logs/<Id>/audit-fix-rollback-*.patch` — the fixer's last attempt, `git apply`-able

Then one of:

- **Re-run** — a new fix session tries again with the same findings (no new audit while HEAD has not moved).
- **Fix by hand** — commit your fixes, then `-Only <Id> -NoAudit` to accept the step.
- **Judge a finding wrong** — record why in `results/_orchestrator.json` `decisions[]`, then
  `-Only <Id> -NoAudit`.

Never accept a high-severity finding as unfixed without saying so in the report.

## Sign-off stops

Tier D and E steps commit once their machine gates pass, then stop. The runner prints the prompt's
acceptance section as a checklist.

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Signoff P10 -Result pass
```

`-Result fail` marks it FAILED instead and the run will not continue past it.

**Before handing a stop to the user, close everything you can yourself.** A stop that reads "please
verify the whole feature" wastes their time; one that reads "everything is verified except the
offline drill, which needs admin rights to disable the adapter" respects it. Drive whatever part of
the acceptance you can and report precisely what is left.

While a stop is pending you may still run **independent** steps — ones that neither depend on the
stopped step nor touch the same files — with `-Only`. Do not run anything that builds on work the
user might yet reject.

## The report

`report.html` is Arabic, RTL, and **derived** from `state/state.json` + `results/*.json`, both written
after every step. It regenerates at any moment and stays honest if the run was interrupted — a real
report of the first seven steps beats nothing.

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Report
```

It has four sections that matter, all fed by the sessions' own structured output:

| Section | Fed by | Why the user reads it |
|---|---|---|
| قرارات اتُّخذت نيابةً عنك | `decisions[]` | what was chosen without asking, and what was rejected |
| مواضع خالف فيها الواقعُ البرومبت | `deviations[]` | where the prompt was wrong |
| ما لم يُثبَت | `unverified[]` | the honest limit of what was proven |
| خيارات وأعمال لاحقة | `followups[]` | what was deliberately left |
| ما وجده التدقيق المستقل | `results/<Id>-audit.json` + `-fix.json` | every defect the audit found: fixed (with the test), dropped (with the reason), or not fixed |

If those sections come back thin across a whole run, the sessions are under-reporting rather than the
run being flawless. Push on it — a twenty-step run with no deviations and nothing unverified is not
credible.

Hand the user the report's path when you finish.

## Finishing

Before you say you are done:

- every prompt DONE — none FAILED, none silently skipped
- the manifest's Build and Test green **on the final tree**, not just the last step's slice
- the app starts clean, if the set drives one
- test data and scratch artifacts cleaned up, or listed in the report if they could not be
- `report.html` regenerated

If any of that does not hold, say so in your first sentence.
