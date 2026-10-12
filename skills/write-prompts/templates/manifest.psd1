<#
    manifest.psd1 — the execution plan. Read by the run-prompts skill.

    Tier  A = fully machine-verified
          B = machine-verified + the session drives a web UI with the browser tools
          C = machine-verified + a real run of the desktop app via App-Smoke.ps1
          D = machine gates pass, then STOPS for a person (real dialogs, network, hardware)
          E = human acceptance test (installers, full walkthroughs)
          Be stingy with D and E — sessions that can read and click a window verify a lot.

    Gates run AFTER the session and independently of what it claimed. Every prompt also
    implicitly requires results\<Id>.json with status = PASS.
      Build | Test | Lint | Typecheck   -> the matching Commands entry, In = repo key
      Cmd          Run, In
      FileExists   Path, In
      FileGlob     Pattern, In
      GrepAtLeast  Pattern, Path, In, Include
      GrepZero     Pattern, Path, In, Include      (comment lines are stripped first)
      DiffReview   Model, MaxChars                 (independent reviewer reads the diff)
      Smoke        Scenario, AllowExit             (needs AppExe)
      Signoff      marks the step as needing a person

    Put DiffReview on EVERY prompt that changes code. It is the only gate that reads the change
    rather than the result, and the only thing that catches scope creep - a session doing what
    was asked AND quietly refactoring things nobody asked for. Everything else here only asks
    "does the tree satisfy these assertions".

    Discover Commands from the project (CLAUDE.md / AGENTS.md / Makefile / package.json / the
    solution or CI workflow) and RUN THEM ONCE before writing them here. A wrong Test command
    makes every gate fail for a reason unrelated to the work, and the runner rolls back good
    work because of it.

    Model/Effort are per prompt and fall back to the defaults below. Use ALIASES
    (opus | sonnet) never pinned ids, so an alias always means the latest of that tier.
      anything that touches code    -> sonnet  / medium   <- the FLOOR, never lower
      normal implementation         -> opus    / high
      architecture, hard debugging  -> opus    / xhigh
      no code at all (docs, report) -> haiku   / low      is acceptable

    NEVER give haiku a prompt that writes or modifies code, however trivial it looks.

    INDEPENDENT AUDIT - ON by default, not listed as a gate. After each step commits, a fresh
    read-only session hunts for real defects; a fix session reproduces each with a failing test and
    fixes it or drops it; the gates re-run; the fixes land in a separate fix(Pxx-audit) commit.
    Turn it off ONLY where there is nothing to find, and say why (the reason reaches the report):
      Audit=$false; AuditSkip='research notes only, no code'
    Keep it on for anything that writes code, migrations, schema or behaviour-changing config.
#>
@{
    Name        = '<task-name>'
    Branch      = '<feature/task-name>'
    Repos       = @{
        main = '<C:\Code\MyApp>'
        # ref = '<C:\Code\Reference>'   # attached read-only with --add-dir
    }
    PrimaryRepo = 'main'
    PromptsDir  = 'prompts'
    Model       = 'opus'
    Effort      = 'high'
    # AuditBrief = 'audit-brief.md'   # optional project-specific notes for the auditor

    # Desktop only. Omit entirely for web projects.
    # AppExe    = '<src\bin\Debug\net10.0-windows\App.exe>'

    Commands    = @{
        Build = '<dotnet build App.sln --nologo -v minimal>'
        Test  = '<dotnet test tests\App.Tests --nologo -v minimal>'
        # Lint      = '<npm run lint>'
        # Typecheck = '<npm run typecheck>'
    }

    Prompts = @(
        @{ Id='P01'; Repo='main'; Tier='A'; Title='<short title>'
           Model='sonnet'; Effort='medium'
           Gates=@(
             @{ Type='Build' },
             @{ Type='Test' },
             @{ Type='DiffReview' },
             @{ Type='FileExists'; Path='<path that must now exist>' }
           ) },

        @{ Id='P02'; Repo='main'; Tier='A'; Title='<short title>'
           Gates=@(
             @{ Type='Build' }, @{ Type='Test' }, @{ Type='DiffReview' },
             @{ Type='GrepZero'; Pattern='<what must be gone>'; Path='<folder>' }
           ) },

        # Desktop step: prove it really runs.
        # @{ Id='P03'; Repo='main'; Tier='C'; Title='<...>'
        #    Gates=@( @{Type='Build'}, @{Type='Test'}, @{Type='Smoke'; Scenario='Start'} ) },

        # No code: nothing for the audit to find. Propose this to the user; do not decide it alone.
        # @{ Id='P03'; Repo='main'; Tier='A'; Title='<research: compare the options>'
        #    Model='sonnet'; Effort='medium'
        #    Audit=$false; AuditSkip='<research notes only, no code>'
        #    Gates=@( @{ Type='FileExists'; Path='<docs/research/options.md>' } ) },

        # Needs a person. Say why in the prompt's Acceptance section.
        # @{ Id='P04'; Repo='main'; Tier='D'; Title='<...>'
        #    Gates=@( @{Type='Build'}, @{Type='Test'}, @{Type='Signoff'} ) },

        # Standing decisions made after the set was written reach a session through Note.
        # @{ Id='P05'; ... ; Note=@'
        # <what changed, why, and that it is intended - so the session documents it
        #  rather than "restoring" the original instruction>
        # '@ },

        # Always end with an audit of the composed result.
        @{ Id='P99'; Repo='main'; Tier='A'; Title='Final audit and documentation'
           Model='opus'; Effort='xhigh'
           Gates=@( @{ Type='Build' }, @{ Type='Test' } ) }
    )
}
