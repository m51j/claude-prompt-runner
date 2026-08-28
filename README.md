# claude-prompt-runner

Two Claude Code skills for work that is too big for one session.

**`write-prompts`** breaks the work into a numbered set of prompts.
**`run-prompts`** executes them — each in its own fresh session, each verified, each committed.

The point is not automation for its own sake. It is that **an agent's own report of success is
worth very little**, and this puts something between that report and your codebase.

---

## The problem

You have a migration, a port, a refactor — days of work. Handing it to one long session degrades:
context fills, early decisions get forgotten, and you end up reviewing a thousand-line diff you did
not watch being written.

Splitting it by hand means launching every session yourself, re-explaining the context each time,
and checking each result manually.

## The idea

Each prompt runs in a **fresh session**. The runner then **re-runs the verification itself** rather
than believing what the session claimed, commits when it passes, and rolls back when it does not.

That middle step is the whole design. In the run these skills were extracted from, two sessions
reported `PASS` without having done the job — dead code still present after one, a mutex not
actually preventing a second instance after another. Both were caught only because the runner
checked instead of trusting.

---

## Install

Requires [Claude Code](https://claude.com/claude-code), `git`, and PowerShell 7 (`pwsh`).

```bash
git clone https://github.com/m51j/claude-prompt-runner.git
cp -r claude-prompt-runner/skills/* ~/.claude/skills/
```

Windows PowerShell:

```powershell
git clone https://github.com/m51j/claude-prompt-runner.git
Copy-Item claude-prompt-runner\skills\* "$env:USERPROFILE\.claude\skills\" -Recurse
```

Per-project instead of globally: copy into `<repo>/.claude/skills/`.

Verify with `/write-prompts` in a Claude Code session.

> **Platform note.** The runner and the desktop-driving helper are PowerShell, so full functionality
> needs Windows (or `pwsh` on Linux/macOS for everything except `App-Smoke.ps1`, which uses Windows
> UI Automation). Web and backend projects work anywhere `pwsh` runs.

---

## Use

**1. Author the set.** In a session at your repo, invoke `/write-prompts` and describe the work in
whatever language you speak. It asks you at most four questions **once**, then writes:

```
Prompts/<task>/
├── manifest.psd1       what runs, in what order, verified how
├── RUN.md              the message you paste to start execution
└── prompts/
    ├── P01-....md
    └── ...
```

The prompts themselves are always English — models follow English instructions more precisely, and
their audience is an agent, not a person.

**2. Run it.** Paste `RUN.md` into a fresh session. It drives:

```powershell
pwsh -File ~/.claude/skills/run-prompts/Run-Prompts.ps1 -Preflight   # always first
pwsh -File ~/.claude/skills/run-prompts/Run-Prompts.ps1              # go
```

It works through the set, stopping only where a person is genuinely needed. Re-running resumes from
the first step that is not done.

**3. Read the report.** `report.html` is generated after every step, so it stays useful even if the
run is interrupted.

---

## What runs per prompt

1. HEAD is recorded as the rollback point; the tree must be clean.
2. The prompt is piped into a **new session** (`--session-id`, so it stays resumable for debugging).
   Other repos are attached read-only for reference.
3. **The gates run — performed by the runner, not claimed by the session.**
4. Green → commit and tag. Red → one retry fed the verbatim failure, then `git reset --hard` and
   stop. Nothing downstream runs, because the chain depends on it.

### Gates

| Gate | Passes when |
|---|---|
| `Build` `Test` `Lint` `Typecheck` | the project's own command exits 0 |
| `Cmd` | any command line you name exits 0 |
| `FileExists` `FileGlob` | something now exists |
| `GrepAtLeast` `GrepZero` | something is present / gone (comments stripped first) |
| `DiffReview` | an independent reviewer reads the diff and returns `ok` |
| `Smoke` | the desktop app really launches and behaves |
| `Signoff` | not a check — marks a step as needing a person |

Every step also requires the session to have written a structured result declaring `PASS`.

### DiffReview

The only gate that reads the **change** rather than the result. Everything else asks "does the tree
satisfy these assertions" — none of them notices a session that did what was asked **and** quietly
refactored things nobody asked for.

It spawns a separate session that never saw the implementer's reasoning, gives it the prompt and the
full diff, and asks: did it do what was asked, did it do *more*, did it do *less*. It runs with
`Edit`/`Write` disallowed — a reviewer that can edit is not a reviewer.

Scope creep fails the step, however good the extra work looks. A change nobody asked for is a change
nobody reviewed.

### Tiers

`A` fully machine-verified · `B` the session drives a web UI with the browser tools · `C` the session
drives a desktop app · `D` machine gates pass, then stops for a person · `E` human acceptance test.

Be stingy with the ones that stop. Sessions that can read a window as text and click it verify far
more than you would expect.

---

## Verifying a running app

`App-Smoke.ps1` reads a live WPF/WinForms window **as text** through UI Automation, so a session can
prove a dialog flow instead of declaring it unverified.

```powershell
pwsh -File ~/.claude/skills/run-prompts/App-Smoke.ps1 -Scenario Start -Exe C:\App\App.exe -KeepRunning
pwsh -File ~/.claude/skills/run-prompts/App-Smoke.ps1 -Scenario Inspect
pwsh -File ~/.claude/skills/run-prompts/App-Smoke.ps1 -Scenario SetText -AutomationId UserBox -Text admin
pwsh -File ~/.claude/skills/run-prompts/App-Smoke.ps1 -Scenario Invoke -Name Save
```

`Start` · `SecondInstance` · `Inspect` · `Invoke` · `SetText` · `Click` · `Keys` · `Screenshot` ·
`Kill`. Controls are addressable by AutomationId or by their visible label in any language; toolbar
items that expose no name are reachable by clicking their UIA bounding rectangle.

Three traps it already handles, because each one presents as an application bug:

- `SW_RESTORE` on a *maximised* window un-maximises it, so every following click misses while still
  reporting success.
- A DPI-unaware host gets logical coordinates from UI Automation and physical ones from the cursor
  API — on multi-monitor setups at different scales, clicks land nowhere near the target.
- A screenshot failure is not a test failure.

**A locked workstation defeats all of it** — synthesized input cannot reach a locked desktop.

For web projects no helper is needed: the session drives the dev server with the browser tools, and
verification is markedly easier.

---

## The report

Generated in Arabic (RTL), derived from the ledger and each session's structured result — so it
regenerates at any moment and stays honest if the run stopped half way.

| Section | Answers |
|---|---|
| قرارات اتُّخذت نيابةً عنك | what was decided without asking, and what was rejected instead |
| مواضع خالف فيها الواقعُ البرومبت | where the prompt turned out to be wrong |
| ما لم يُثبَت | what is still **not** proven |
| خيارات وأعمال لاحقة | what was deliberately left |

To generate it in another language, edit `New-Report.ps1` — the section headings are literals near
the top.

---

## Design notes

Things that turned out to matter more than expected:

**A prompt must not contain an implementation path nobody verified.** Sets are written without
reading every file — that is the accepted trade for authoring quickly. So each prompt separates
*Verified context* (what the author actually read; be specific here) from *Goal* (the outcome; no
procedure). Every session is told: **if the codebase disagrees with the prompt, the codebase wins** —
do the right thing and record it. That converts imprecision from a defect into a reported outcome.

**Ask once, then freeze the answers.** All clarifying questions happen before a single prompt is
written, and the answers become a *Fixed decisions* block repeated in every prompt. Without it,
twenty sessions re-litigate the same choice.

**Require sessions to declare what they could not prove.** Each result carries `unverified[]`,
`deviations[]` and `decisions[]`. This costs nothing and produces the most valuable part of the
report. A twenty-step run reporting nothing unverified is not credible — it is under-reporting.

**`sonnet` is the floor for anything touching code.** Never `haiku` for a prompt that writes or
modifies source, however mechanical it looks: the step that reads as trivial while authoring is
routinely the one that needs judgement once a session opens the file.

**End every set with an audit step.** Per-step gates prove each step in isolation, never that the
steps cohere. In the run these skills came from, that final step found a data-loss bug none of the
previous twenty-two had noticed.

---

## Prior art

[amElnagdy/delegate-skills](https://github.com/amElnagdy/delegate-skills) solves an adjacent problem
— delegating a task to a *different* agent CLI and reviewing its diff — and arrives independently at
several of the same conclusions: self-contained briefs, a structured result contract, one commit per
task, a progress file written as you go, and above all *re-run the gates yourself, never take
"gates passed" on faith*. Worth reading. The main difference is where the enforcement lives: there
it is an instruction to the orchestrator, here it is a manifest the runner executes.

## License

MIT — see [LICENSE](LICENSE).
