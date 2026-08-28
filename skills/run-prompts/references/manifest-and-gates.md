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
    AppExe      = 'src\bin\Debug\net10.0-windows\App.exe'   # omit for web projects
    Commands    = @{
        Build = 'dotnet build App.sln --nologo -v minimal'
        Test  = 'dotnet test tests\App.Tests --nologo -v minimal'
    }
    Prompts = @(
        @{ Id='P01'; Repo='main'; Tier='A'; Title='...'
           Model='sonnet'; Effort='medium'
           Gates=@( @{Type='Build'}, @{Type='Test'}, @{Type='DiffReview'} ) }
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
