# Writing one prompt

Every prompt file is read by a session that has **no chat history, no memory of the other prompts,
and no idea what you were thinking**. It sees that one file and the repo. Everything it needs is in
the file or it does not exist.

## The sections

Use `templates/prompt.md`. In order:

**Header** — repo it edits, what it depends on, whether it is reorderable.

**Shared context, verbatim in every file.** Repos and which one this prompt edits, the fixed
decisions, hazards and names that must not change, and the baseline verification commands. Yes, it is
repeated in all of them — each session starts cold and this is the only way it reaches them.

**Verified context** — what you actually opened and read. The only place you may be specific about
files, symbols and line numbers.

**Goal** — the outcome, in terms of behaviour.

**Acceptance** — how anyone would know it worked.

**Out of scope** — what this prompt must not touch, and which later prompt owns it.

## The rule that matters most

**How specific you are allowed to be is bounded by how much you actually read.**

- Read it → state it as fact, in *Verified context*.
- Inferred, guessed, or expected → state it as a goal, never as a procedure.

**Never write an implementation path you did not verify.** Naming a file, a function or a line number
you did not open turns a helpful prompt into a misleading one: the session either follows you into a
mistake, or burns a turn discovering you were wrong. Say what the result must be and let it find the
way — it can read the code, which is more than you did.

Every prompt ends with the escape hatch, and it is not boilerplate:

> If the codebase disagrees with this prompt, **the codebase wins** — do the right thing and record
> it in `deviations`.

That single line converts your imprecision from a defect into a managed, reported outcome.

## Acceptance criteria the gates can be built from

This section is where the manifest's gates come from, so vagueness here costs a real check later.

Bad: *"the settings load correctly."*
Good: *"`grep -r 'ss2' src/` returns nothing"* · *"`src/Infrastructure/AppPaths.cs` exists and every
settings path in the project resolves through it"* · *"`dotnet test` passes including 3 new tests for
the migration."*

For each criterion ask: **what would be true if this worked, and false if the session only claimed it
did?** If you cannot answer, the criterion is not testable and the prompt is not ready.

## Out of scope — write it properly

The `DiffReview` gate fails a step for scope creep, and when it fires the cause is almost always a
vague *Out of scope*. Name the neighbouring things a reasonable session might be tempted to fix
along the way, and say which later prompt owns them.

> Out of scope: the legacy `Connect()` helper in `Shared/PublicModule.cs` — P12 replaces it. Do not
> reformat, rename or refactor anything you are not asked to change here.

## Writing for UI work

**C# + DevExpress** — tell the prompt to invoke the matching installed skill *by name*:
`devexpress-winforms-data-grid`, `devexpress-winforms-ribbon-and-bars`, `devexpress-winforms-layout`,
`devexpress-winforms-editors`, `devexpress-wpf-*`, `devexpress-reports-*`. They carry the correct
APIs and stop a session guessing at them.

**Any UI** — demand a professional result explicitly, because "make it work" reliably produces
something that looks like a prototype:

> The result must look professionally designed, not merely functional: consistent spacing and
> alignment on a single scale, a clear visual hierarchy, correct RTL mirroring including icons and
> numerals, full keyboard operability, and considered empty, loading and error states.

Where a design already exists in the project, point at it — a session that can see the established
look will match it.

## Handoff between prompts

A fact that emerges during P02 — a helper got named, an interface was chosen, a file landed somewhere
specific — does not reach P05 by itself. Two mechanisms:

- The session writes `handoff` in its result file, and the next session is told what it needs.
- Anything you already know at authoring time goes into the later prompt's *Verified context*.

If a later prompt depends on a name an earlier one will invent, say so explicitly: *"use the helper
introduced in P02; find its name before writing against it."*
