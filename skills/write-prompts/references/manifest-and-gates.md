# Choosing gates, tiers and models

The manifest is where a prompt set stops being a wish list. Full schema and every gate type:
`~/.claude/skills/run-prompts/references/manifest-and-gates.md`. This file is about the *choices*.

Start from `templates/manifest.psd1`.

## Gates that catch a false PASS

`Build` + `Test` catches a compile error, not a job half done. In the run these skills came from, two
sessions reported PASS without having done the work and both were caught only by prompt-specific
assertions.

Derive them mechanically from each prompt's *Acceptance* section:

| Acceptance says | Gate |
|---|---|
| "X is gone from the codebase" | `GrepZero` |
| "X now exists" | `FileExists` / `FileGlob` |
| "X is wired into Y" | `GrepAtLeast` |
| "the app still starts" | `Smoke` with `Start` |
| anything else measurable | `Cmd` |

If a prompt's only gates are `Build` and `Test`, look again — either the acceptance section is too
vague, or you have not translated it.

## Put DiffReview on every prompt that changes code

```powershell
Gates=@( @{Type='Build'}, @{Type='Test'}, @{Type='DiffReview'} )
```

It spawns an independent reviewer that reads the diff against the prompt and fails the step for
scope creep — the one failure no mechanical gate can see. A session can satisfy every assertion you
wrote while also refactoring things nobody asked for, and without this nothing notices.

It costs one cheap extra session per prompt. Omit it only where there is no diff worth reading — a
migration file, a document. Its usefulness is directly proportional to how well you wrote *Out of
scope*, so write that section properly.

## The independent audit is on — mark only the exceptions

The runner audits every committed step by default (a fresh read-only auditor, a test-first fix
session, the gates again, a separate `fix(Pxx-audit)` commit). You do not list it as a gate. Mark a
step off only when there is nothing for an auditor to find, and always say why:

```powershell
@{ Id='P02'; ...; Audit=$false; AuditSkip='research notes only, no code' }
```

Research, decision notes, documentation and logic-free assets are the usual exceptions; anything that
writes code, migrations, schema or behaviour-changing configuration keeps it. A project-specific
brief for the auditor goes in `audit-brief.md` with `AuditBrief = 'audit-brief.md'` at the top of
the manifest. Model keys (`AuditModel`, `AuditFixModel`, default `opus` / `high`) rarely need
changing — a weak auditor finds little and invents more. Full detail:
`~/.claude/skills/run-prompts/references/manifest-and-gates.md`, "The independent audit".

## Tiers — be stingy with the ones that stop

| Tier | Use when |
|---|---|
| A | the gates fully settle it |
| B | a web UI needs driving — the session does it with the browser tools |
| C | a desktop app needs running — the session drives it with `App-Smoke.ps1` |
| D | machine gates pass, then a person is genuinely needed |
| E | a human acceptance test: installers, full walkthroughs, physical hardware |

A step needs a person only for things a session cannot reach: physically disconnecting a network,
elevated permissions, hardware, or a judgement call that is genuinely the user's.

It does **not** need a person merely because it involves a dialog. Sessions that can read a window as
text and click it verify far more than expected — in the originating run, two steps tiered as
human-only turned out to be nearly fully automatable once the session could click. For web work,
tier B should be the norm and a stop the exception.

Every D and E step costs the user an interruption. Spend those deliberately.

## Model and effort per prompt

| Kind of step | Model / effort |
|---|---|
| Writes or changes code — **any amount** | `sonnet` / `medium` at the very lowest |
| Normal implementation | `opus` / `high` |
| Architecture, tricky debugging, the final audit | `opus` / `xhigh` |
| No code at all — docs, a report, listing or summarising | `haiku` / `low` is fine |

**Never assign `haiku` to a prompt that writes or modifies code**, however trivial it looks. A step
that seems mechanical while you are authoring it is routinely the one that turns out to need
judgement once a session opens the file. `sonnet` is the floor for anything touching source.

Use **aliases** (`opus`, `sonnet`) never pinned model ids, so an alias always resolves to the latest
of that tier and the set does not rot on the shelf.

`ReviewModel` sets the default for `DiffReview`; `sonnet` is enough to read a diff.

## Branch and repos

`Branch` is created in every repo if missing — one branch across the whole set, so the work is one
reviewable unit. Omit it to run on the current branch.

List every repo the set touches in `Repos`. The one a prompt names is its working directory; all
others are attached with `--add-dir` so a session can read reference material, and the protocol
forbids editing them.
