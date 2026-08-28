# Verifying a running application

The difference between a step marked "unverified" and one actually proven is almost always whether
the session could drive the real thing. Push for driving it.

## Desktop — App-Smoke.ps1

Reads a live WPF/WinForms window **as text** through UI Automation, so a session can verify a dialog
flow instead of declaring it unverified.

```bash
pwsh -NoProfile -File ~/.claude/skills/run-prompts/App-Smoke.ps1 -Scenario Start -KeepRunning
```

| Scenario | Does |
|---|---|
| `Start` | launch, wait for a window, screenshot, dump the UIA tree, tail the log, kill. `-KeepRunning` leaves it up; `-AllowExit` treats a self-exit as success |
| `SecondInstance` | launch twice; the second copy must exit (single-instance guards) |
| `Inspect -Title X` | the element tree of a live window, as text |
| `Invoke -AutomationId X` / `-Name "نعم"` | click a control (falls back to Toggle/Select) |
| `SetText -AutomationId X -Text "..."` | write into a field via the UIA ValuePattern |
| `Click -X <n> -Y <n>` | a real cursor click at screen coordinates |
| `Keys -Send "{DOWN}{ENTER}"` | keystrokes to the focused window |
| `Screenshot` | full-screen PNG — open it with the Read tool, which renders images |
| `Kill` | kill every copy |

It prints one JSON line and writes artifacts to `-OutDir`. Exit code 0/1.

**The pattern that works:** `Start -KeepRunning` → `Inspect` to read every AutomationId and label →
`Invoke`/`SetText` → `Inspect` again to see what changed. Buttons are addressable by their visible
label in any language.

### When Invoke will not work

Toolbar and status-bar items in some UI kits — DevExpress especially — expose no usable name through
UI Automation (every one reads `"Static"`) and ignore posted `WM_LBUTTONDOWN`; their hit-testing reads
the real cursor. For those: enumerate the container's children through UIA, take the
`BoundingRectangle` of the one you want, and `Click` its centre.

### Traps already handled inside the helper

Worth knowing, because they present as application bugs:

- **`SW_RESTORE` on a merely maximised window un-maximises it.** Every element moves, and the click
  that follows lands on nothing while still reporting success. The helper restores only a genuinely
  minimised window.
- **DPI.** With two monitors at different scales, a DPI-unaware host gets logical coordinates from
  UIA and physical ones from the cursor API. The helper declares per-monitor awareness first.
- **Screenshots are artifacts, not assertions.** `CopyFromScreen` throws whenever the desktop session
  is momentarily unavailable; letting that fail a gate costs a whole retry session for nothing.

### The hard limit

**A locked workstation defeats all of it** — synthesized cursor input cannot reach a locked desktop.
A run that drives the GUI needs the machine awake. This is the single most common reason a desktop
verification step fails for a reason unrelated to the code.

Also: a Velopack-style installed app launches through a **stub** that starts the real executable and
exits immediately. Watching the stub's exit and concluding the app died is wrong — look for the
process running from `current\`.

## Web

No helper needed, and verification is markedly easier — prefer tier B over a sign-off stop.

Start the dev server, then use the browser tools to navigate, fill and assert, and read the console
and network panes. Two things worth doing that sessions often skip:

- assert on the **rendered** result, not on a successful build
- check the console for errors after the interaction, not only before

## Databases and external state

When a step's acceptance depends on data, verify against the data — query it. "The code that writes
the row compiles" is not evidence the row appears. Where an MCP server is configured for the service,
the session can query it directly; otherwise a CLI (`sqlcmd`, `psql`) in a `Cmd` gate does it.

Clean up test rows and test databases afterwards, and say in `unverified` if you could not.
