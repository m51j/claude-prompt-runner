---
name: write-prompts
description: Turn a large piece of work into a numbered set of English prompts plus a manifest and a run command, so an agent can execute them one at a time with verification gates, a diff review, an independent per-step audit (on by default; it proposes which steps to exclude), and a commit per step. The user describes what they want in Arabic or English; the output prompts are always English. Use when the user asks to break work into prompts, says "اكتب برومبتات" / "write prompts for", plans a migration, port, refactor or feature too big for one session, or asks to prepare work for the run-prompts skill. Do NOT use for work that fits in one session.
compatibility: Produces a set for the `run-prompts` skill, which needs the `claude` CLI, git and PowerShell 7.
metadata:
  version: 1.2
---

# Authoring a prompt set

You produce four things in a new folder: the prompts, a `manifest.psd1`, a `RUN.md` the user pastes
to start execution, and a recommendation of which model and effort to run the orchestrator on.

The user writes to you in Arabic or English. **The prompts you write are always English** — models
follow English instructions more precisely, and the executing sessions are agents, not people.
Anything you say *to the user* follows their language.

## Step 0 — is this even a prompt set?

Decide this first and say which you chose.

| Situation | Do this instead |
|---|---|
| One coherent change that fits in a single session's context | Just do the work. Do not write prompts |
| Several independent pieces with no ordering between them | Subagents, or a workflow if the user opted in |
| A long chain where later steps depend on earlier ones, needing clean context per step, rollback boundaries, and verification | **A prompt set.** Continue |

A prompt set costs real time to run. If two prompts would do, do not write eight.

## Step 1 — one round of questions, then commit to answers

The most annoying failure mode is asking the user something at every step. **Ask once, up front, and
never again.** Use `AskUserQuestion` with at most four questions, and only where a wrong guess would
waste real work.

Everything else: pick the defensible default and write it into the **Fixed decisions** block of the
shared context. That block is what stops twenty downstream sessions from re-litigating the same
choice — the highest-leverage paragraph in the whole set.

Good question: *"the kill switch waits for an OK click — silent exit instead?"*
Bad question: *"`var` or explicit types?"* — match the codebase and move on.

## Step 2 — read enough, and let that bound how specific you are

Read the entry points, the files the work obviously touches, the build and test setup, and any
project `CLAUDE.md` or `AGENTS.md`. **Do not read the whole project** — that is slow, and the user
has accepted the trade.

The consequence is the rule that keeps an imprecise prompt from becoming a wrong one:
**how specific you are allowed to be is bounded by how much you actually read.** Full treatment in
[references/writing-a-prompt.md](references/writing-a-prompt.md).

## Step 3 — discover the real verification commands

Do not invent or assume the build and test commands. Find the project's **actual** ones, in this
order: `CLAUDE.md` / `AGENTS.md` → `Makefile` / `justfile` → `package.json` scripts → the `.sln`,
`.csproj`, `pyproject.toml`, `Cargo.toml`, or CI workflow.

Then **run them once** before writing them into the manifest. A manifest whose `Commands.Test` is
wrong produces a set where every gate fails for a reason that has nothing to do with the work — and
the runner will roll back good work because of it.

If the project has no test command, say so to the user rather than inventing a gate.

## Step 4 — decide the split

Split only where there is a reason: it crosses a rollback boundary, it exceeds one session's
context, it produces something a later step depends on, or it needs a different kind of verification.
Otherwise **merge**. Three good prompts beat ten fragments.

**But size a step by the session it will need, not by the feature.** Every turn re-sends the whole
conversation, so a session's cost grows with turns × what it has swallowed, and its attention
degrades the same way. A step that will plainly run past ~300 turns — two engines in one prompt, a
screen plus the harness that drives it, a port of six scripts — is split at its natural seam with
an explicit handoff, even when the pieces "belong together". Measured: one 1,500-turn step cost
more than the other three of its batch combined and produced no better code. Splitting is not free
either (each session re-reads the codebase cold and pays the gates and the review), so the seam
must be real: a contract, a file boundary, a different kind of verification.

Order so that things others depend on come first, and mark reorderable ones as such.

**End the set with an audit step** — a final prompt that checks the composed result end to end and
writes documentation. Per-step gates prove each step in isolation, never that the steps cohere. In
the run this skill came from, that last step found a data-loss bug none of the previous twenty-two
had noticed. The runner's per-step independent audit (below) does not replace it: that audit reads
one step, this one reads the whole.

## Step 5 — write the prompts and the manifest

One file per prompt, `P01-short-slug.md`, in `prompts/`, from `templates/prompt.md`.

- [references/writing-a-prompt.md](references/writing-a-prompt.md) — the sections, the
  verified-context rule, acceptance criteria that gates can be derived from, and UI/DevExpress work.
- [references/manifest-and-gates.md](references/manifest-and-gates.md) — the schema, choosing gates
  that actually catch a false PASS, tiers, and per-prompt model/effort.

### The independent audit — on by default, propose the exceptions

The runner audits every committed step: a fresh read-only session hunts for real defects, a fix
session reproduces each with a failing test and fixes it (or drops it), and the fixes land in their
own commit. It is **on by default** — you do not add it. It roughly doubles a step's cost, and it is
why a set's result is trustworthy rather than merely green: on the project where it was first done,
it found real defects in almost every step the gates had passed.

Your job is the exceptions. Go through the prompts and mark a step `Audit=$false` with an
`AuditSkip='<reason>'` **only** when an audit has nothing to find:

| Skip the audit | Keep it |
|---|---|
| research or decision notes, no code | any step that writes or changes code — however small |
| documentation, screenshots, a report | migrations, schema or data changes |
| pure asset generation with no logic in it | configuration that changes behaviour (CI, build, deploy) |
| | the final audit step if it is allowed to fix code |

(A step whose diff turns out to be documentation only is skipped by the runner automatically; mark
it anyway when you know, so the plan is visible.) When in doubt, keep it.

If the project has something an auditor must know — the defects that matter most in this domain
(e.g. units, money, data loss in a file format), customer data never to copy, dev-server ports,
areas a fixer must not touch — write it as `audit-brief.md` in the set folder and set
`AuditBrief = 'audit-brief.md'` in the manifest. Keep it short; the runner already supplies the
generic audit instructions.

You **propose** the exceptions in Step 6; the user decides.

## Step 6 — RUN.md and the recommendation

Write `RUN.md` from `templates/RUN.md`: the one message the user pastes into a fresh session to start
execution. Then tell them, in their language:

- how many prompts, and why that many rather than more or fewer
- which steps will stop for them, and what each stop needs
- **the audit plan.** If you marked any step `Audit=$false`, list those steps with the reason for
  each and ask once (`AskUserQuestion`: accept the proposal / audit every step / choose myself) —
  this is the one question allowed after the set is written, because it trades the user's money
  against the result's quality. Apply the answer to the manifest. If no step is excluded, just say
  the audit runs on every step and roughly doubles the per-step cost — no question.
- **which model and effort to run the orchestrator on** — usually `opus` / `high`; `xhigh` if the set
  is architectural or the codebase is unfamiliar
- a rough sense of scale (a 23-prompt set on a large codebase ran to a few hours)

## Output layout

```
<set-folder>/
├── manifest.psd1
├── RUN.md
├── audit-brief.md      optional: project-specific notes for the per-step audit
├── .gitignore          state/ results/ logs/ report.html
└── prompts/
    ├── P01-....md
    └── ...
```

Put it inside the repo being changed (e.g. `Prompts/<task-name>/`) unless the user says otherwise.

## The two failures to design against

**A prompt that lies.** You did not read that file; do not describe its contents. The cost is not
embarrassment — it is a session confidently doing the wrong thing.

**A prompt nobody can check.** If you cannot write a concrete acceptance test for a prompt, it is not
ready. Sharpen it until you can, or merge it into a neighbour that is checkable.
