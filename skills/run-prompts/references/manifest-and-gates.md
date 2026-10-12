# manifest.psd1 — schema, gates, tiers

```powershell
@{
    Name        = 'scale-cloud'          # tag prefix and report title
    Branch      = 'feature/scale-cloud'  # created in every repo if missing; omit to stay put
    Repos       = @{ main = 'C:\Code\MyApp'; ref = 'C:\Code\Reference' }
    PrimaryRepo = 'main'                 # default cwd, and default for gates that take `In`
    PromptsDir  = 'prompts'              # relative to the set folder
    Model       = 'opus'                 # default; ALIASES only, never pinned ids
    Effort      = 'high'
    ReviewModel = 'sonnet'               # DiffReview default
    TrimModel   = 'sonnet'               # the scope-trim session (default sonnet / medium)
    # The independent audit is ON by default (see "The independent audit" below). Optional:
    # Audit = $false                     # off for the whole set
    # AuditModel = 'opus'; AuditEffort = 'high'; AuditFixModel = 'opus'; AuditFixEffort = 'high'
    # AuditBrief = 'audit-brief.md'      # project-specific notes appended to the audit prompt
    AppExe      = 'src\bin\Debug\net10.0-windows\App.exe'   # omit for web projects
    Commands    = @{
        Build = 'dotnet build App.sln --nologo -v minimal'
        Test  = 'dotnet test tests\App.Tests --nologo -v minimal'
    }
    Prompts = @(
        @{ Id='P01'; Repo='main'; Tier='A'; Title='...'
           Model='sonnet'; Effort='medium'
           Gates=@( @{Type='Build'}, @{Type='Test'}, @{Type='DiffReview'} ) }
        @{ Id='P02'; Repo='main'; Tier='A'; Title='Research: compare the options'
           Audit=$false; AuditSkip='writes research notes only, no code'
           Gates=@( @{Type='FileExists'; Path='docs/research/options.md'} ) }
    )
}
```

Every repo other than the prompt's own is attached with `--add-dir`, so a session can read reference
material but the protocol forbids editing it.

## Gate types

Gates run **after** the session and independently of what it claimed. Every prompt also implicitly
requires `results/<Id>.json` with `status: PASS`.

| Type | Fields | Passes when |
|---|---|---|
| `Build` `Test` `Lint` `Typecheck` | `In` | the matching `Commands` entry exits 0 |
| `Cmd` | `Run`, `In` | that command line exits 0 |
| `FileExists` | `Path`, `In` | the file is there |
| `FileGlob` | `Pattern`, `In` | at least one match |
| `GrepAtLeast` | `Pattern`, `Path`, `In`, `Include` | ≥1 match |
| `GrepZero` | `Pattern`, `Path`, `In`, `Include` | 0 matches (comment lines stripped first) |
| `DiffReview` | `Model`, `MaxChars` | an independent reviewer returns `ok` |
| `Smoke` | `Scenario`, `AllowExit` | `App-Smoke.ps1` returns ok (needs `AppExe`) |
| `Signoff` | — | not a check; marks the step as needing a person |

`Build` retries once when it fails with a missing generated source under an intermediate folder —
that is a build racing something that touched it, not broken source. A real compile error survives
the second attempt.

`GrepZero` strips `//`, `#` and `--` comment lines before matching. Dead code left by a conversion
carries the same literals as live code and would otherwise flag a file that is actually correct.

## DiffReview — the only gate that reads the change

Everything else asks "does the tree satisfy these assertions". None of them notices a session that
did what was asked **and** quietly refactored half the codebase, or that satisfied the letter of an
assertion while missing the point.

`DiffReview` spawns a separate session that never saw the implementer's reasoning, hands it the
prompt, its `Note` (as standing decisions that supersede the prompt), and the complete diff since the step's base commit, and asks three questions: did it do what
was asked, did it do **more**, did it do **less**. It runs with `Edit`/`Write` disallowed — a
reviewer that can edit is not a reviewer — and returns a structured verdict.

| verdict | meaning |
|---|---|
| `ok` | does what was asked, nothing more, nothing less |
| `scope_creep` | also changed things the task did not ask for — **a failure** |
| `incomplete` | an acceptance criterion is plainly unmet by the diff |
| `wrong` | does something other than what was asked |

Scope creep is a failure however good the extra work looks: a change nobody asked for is a change
nobody reviewed. When it fires, read `logs/<Id>/diff-review.json` and decide — usually the fix is to
re-run the step with a sharper "Out of scope" section in the prompt, not to relax the gate.

**Put it on every prompt that changes code.** It costs one cheap extra session (`sonnet` is enough
to read a diff) and it is the only thing standing between you and unreviewed drive-by edits. Skip it
only for prompts that produce no diff worth reading — a migration file, a document.

Very large diffs are truncated at `MaxChars` (default 180 000) and the reviewer judges what it sees.

### What the reviewer is given, and the scope trim

The reviewer sees the prompt, the `Note`, the diff, **and the implementer's own results file**
(`summary`, `changed_files`, `deviations`, `decisions`, and `scope_justification` after a trim). It
is told to treat those as claims to check against the diff, and to distinguish two things that look
alike: **necessary wiring** outside the prompt's expected folders (a DI registration, a route
mapping, a shared contract, a guard the task itself changed — minimal and explained) is *not* creep;
refactors, renames, reformatting and "while I was here" fixes are.

When a step's **only** failing gate is `DiffReview` with `scope_creep`, the runner does not spend a
full retry. It runs one **scope-trim session** (`TrimModel`, default `sonnet` / `medium`) whose whole
job is to revert the hunks the reviewer named — or keep one and write a `scope_justification` line
saying what breaks without it — then re-runs every gate. If the verdict still stands, the ordinary
retry follows. One trim per prompt; its cost lands in `state.json` as `trimCostUsd`, and every
attempt's cost is kept in `attemptCosts`. Measured on a real run: the creep verdicts were mostly
necessary wiring, and the retries they forced were the second-largest cost after the sessions
themselves.

## The independent audit

Not a gate you list: it runs after **every** committed step unless switched off. Gates prove
assertions and `DiffReview` proves the diff matches the task — neither asks whether the code is
*right*. On the project where this was first done by hand, a fresh audit found real defects in almost
every step the gates had passed (data loss, wrong calculations, undo that did not undo, migrations
that broke old files, tests that asserted nothing). Sets run without it carried the same classes of
defect silently and looked "cleaner" only because nobody looked.

1. **Audit session** — fresh, `Edit`/`Write` disallowed, never saw the implementer's reasoning. It gets
   the prompt, the `Note`, the implementer's results file (as claims to check), the diff range, the
   project's commands and the optional project brief. It may run builds, tests and reproduction
   scripts (scratch files under `logs/<Id>/audit-scratch`). It returns structured findings — id,
   severity, title, file:line, problem, reproduction, suggested fix — and `checked_ok`. **Zero
   findings is a valid result**; style, naming and refactor wishes are not findings. Anything it
   leaves in the tree is discarded.
2. **Fix session** — for each finding: reproduce it with a test that fails, then make the smallest fix;
   or **drop** it with a reason when it cannot be reproduced or the code is right. This is the guard
   against an auditor inventing defects. It writes `results/<Id>-fix.json`, and the runner fails the
   pass unless every finding id is either fixed or dropped.
3. **Gates** — every gate of the step re-runs, except `DiffReview` (the fix is not the task's diff)
   and `Signoff`. Red → one retry of the fix session with the verbatim failure.
4. **Commit** — green → one `fix(Pxx-audit): N defect(s) …` commit listing each fixed finding, beside
   the step's own commit, so either can be reverted alone. All dropped → nothing is committed.

Red twice → the fixes are saved as `logs/<Id>/audit-fix-rollback-*.patch`, the tree goes back to the
step's commit (the step itself stays committed), the step is marked `AUDIT_FAILED` and the run stops.
Re-running resumes the audit (reusing the findings while HEAD has not moved); `-Only Pxx -NoAudit`
accepts the step as it stands after you fixed or judged the findings by hand.

The audit runs **before** a tier D/E sign-off stop, so the person signs the audited result.

| Manifest key | Default | |
|---|---|---|
| `Audit` (top level) | on | `$false` turns it off for the whole set |
| `Audit` / `AuditSkip` (per prompt) | on | `Audit=$false; AuditSkip='research notes only'` — the reason reaches the report |
| `AuditModel` / `AuditEffort` | `opus` / `high` | the auditor; a weak model finds little and invents more |
| `AuditFixModel` / `AuditFixEffort` | `opus` / `high` | the fix session |
| `AuditBrief` | — | path (relative to the set) of a project-specific brief appended to the audit prompt: what matters most in this domain, ports, customer data never to copy, areas a fixer must not touch |

Skipped automatically: a step whose change (outside the set folder) is documentation or images only,
a step that changed nothing, and any run with `-NoCommit`. Cost: roughly one more opus session per
step, plus a fix session when there are findings — budget about double the per-step cost.

Results: `results/<Id>-audit.json` (findings), `results/<Id>-fix.json` (fixed/dropped),
`state.json` → `audit` (status, counts, `fixCommit`) and `auditCostUsd`; the report has a section
listing every finding as fixed, dropped (with the reason) or not fixed.

## Writing gates that actually catch things

`Build` + `Test` catches a compile error, not a job half done. For each prompt ask: *what would be
true if this worked, and false if the session only claimed it did?* Then encode that.

- "this must be gone" → `GrepZero`
- "this must now exist" → `FileExists` / `FileGlob`
- "this must be wired up" → `GrepAtLeast`
- anything else → `Cmd`

## Tiers

| Tier | Meaning |
|---|---|
| A | fully machine-verified |
| B | machine-verified, plus the session drives a web UI with the browser tools |
| C | machine-verified, plus a real run of the desktop app via `App-Smoke.ps1` |
| D | machine gates pass, then **stops** for a person (real dialogs, network, hardware) |
| E | human acceptance test (installers, full walkthroughs) |

Be stingy with D and E. Sessions that can read and click a live window verify far more than expected.

## Model and effort

`Model`/`Effort` are per prompt, falling back to the manifest defaults. Use them — a step that writes
one SQL file does not need what a startup rewrite needs.

**`sonnet` is the floor for any step that touches code.** Never `haiku` for a prompt that writes or
modifies source, however mechanical it looks: a step that reads as trivial while the set was authored
is routinely the one that needs judgement once a session opens the file. `haiku` is fine only for
steps producing no code at all. If you find a code prompt set to `haiku`, correct the manifest before
running it.

Use **aliases** (`opus`, `sonnet`) never pinned model ids, so an alias always resolves to the latest
of that tier and the set does not rot.

## Per-prompt standing decisions

`Note` on a prompt entry is appended to that session's protocol as **standing decisions**, and is
also handed to `DiffReview` — otherwise the reviewer fails a session for obeying it. It is for
choices made after the set was written that supersede what the prompt says. Without it, a session
reading a superseded instruction will faithfully "restore" behaviour the user deliberately changed.
