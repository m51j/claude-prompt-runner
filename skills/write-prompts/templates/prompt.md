# P01 — <short title, imperative>

**Repo:** <repo key from the manifest>
**Depends on:** <P.. ids, or "nothing"> · <*reorderable* if it can run any time after its deps>

---

## Shared context

<!-- Verbatim in EVERY prompt file. Each session starts cold and sees only its own file. -->

```
SHARED CONTEXT — read fully before doing anything.

Repos:
- TARGET:    <path>   <one line: what this is>
- REFERENCE: <path>   <read-only source of patterns; NEVER edit it>
The prompt states which repo it edits. Never modify another repo in the same session.

Fixed decisions (do not revisit or "improve"):
- <decision> — <the one-line reason, so nobody reopens it>
- <decision> — <reason>

Hazards — names and files that must not change:
- <name> — <what silently breaks if it is renamed>

Verification baseline: <build command> must be green after every prompt, and <test command>
where tests are touched. Do not commit — the runner commits.
```

---

## Verified context

<!-- ONLY what you actually opened and read while authoring. Be specific here and nowhere else.
     If you did not read it, it does not belong in this section. -->

- `path/to/File.cs` — <what is there now, and why it matters to this step>
- <existing helper/pattern the session should reuse rather than reinvent>

## Goal

<!-- The outcome, in terms of behaviour. NOT a procedure. Anything you did not verify while
     authoring is a goal, never a step. Let the session find the way. -->

<what must be true when this is done>

## Acceptance

<!-- Concrete and mechanical. The manifest's gates are derived from this section, so vagueness
     here costs a real check later. -->

- <observable fact 1 — how anyone would confirm it>
- <observable fact 2>
- <the command that must pass, and what its output must show>

## Out of scope

- <what this prompt must not touch, and which later prompt owns it>

---

If the codebase disagrees with this prompt, **the codebase wins** — this was written without reading
every file. Do the right thing and record what you changed in `deviations`.
