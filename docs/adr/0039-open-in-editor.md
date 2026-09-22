# ADR 0039: Open in editor — a pull request's file, in your own clone, in your own editor

Status: Accepted · Date: 2026-09-22

## Context

Shepherd shows a pull request's diff in Monaco (ADR 0003) or in the native list (ADR 0034). Both
are views of the *patch*: they show the hunks GitHub sent, not the file around them, and they
cannot run the code, jump to a definition or show the rest of the module. Reviewers want that
constantly, and the maintainers asked for it by name: "jump into the code", with a choice of
program — VS Code for one of them, IntelliJ for the other, and a sensible default for everyone else.

Two things were already in place:

- **A map of local clones.** `AppSettings.localCheckouts` (`owner/repo` → folder) exists for
  delegation (ADR 0011): a worktree has to be built from somewhere. It is edited in Settings →
  Delegation and the delegation sheet offers to fill it in.
- **No sandbox.** Shepherd is not sandboxed (`Shepherd/Support/Shepherd.entitlements`), so opening a
  file in the user's home or spawning a process needs no security-scoped bookmark.

## Decision

- **The clone map is reused, not duplicated.** "Open in editor" resolves the pull request's
  repository-relative path against `localCheckoutURL(for:)`. Linking a clone from the review screen
  ("Link a Local Checkout…") writes the same map, so delegation for that repository starts working
  too, and the reverse.
- **URL schemes over CLIs.** VS Code (`vscode://file/<abs>:<line>`), Cursor (`cursor://file/…`)
  and IntelliJ IDEA (`idea://open?file=<abs>&line=<n>`) are reached through the URL handlers their
  apps register, so nothing depends on `code` or `idea` being on a `PATH` a Dock-launched app does
  not see. When a scheme has no handler but the app is installed (by bundle identifier), the file is
  opened *with* that app instead and only the line is lost. *System default* is plain
  `NSWorkspace.open` — Finder's answer — and is the default because it works on every Mac.
- **A custom command, with the delegation rules.** `{file}` and `{line}` in a template that is split
  by `ShellWords` first and substituted after, run with `Process`, never a shell — the mechanism of
  ADR 0011 and ADR 0030, so a path with spaces or a `;` stays one argument. The first word must be a
  path; a bare `code` is refused with a message rather than guessed at.
- **Honest about the checkout.** Line numbers are head-side. The clone is on whatever branch the user
  left it on, and Shepherd does not run git to find out. A path the clone does not have opens the
  clone's folder with a toast saying the checkout may be on another branch; the action's help says
  lines only match when the checkout is on the pull request's head. A path that would climb out of
  the chosen folder (`../…`) is never opened.
- **Where it is offered:** the review file list's context menu, an icon in the file header, and the
  `path:line` links of the claims card, *Look closer* and the CI diagnosis card (which can name a
  file the diff does not contain — the clone is the one place it can be read). No line for the
  header: the cursor lives behind the diff bridge, and this decision does not widen the bridge.
- **The choice syncs.** `EditorConfiguration` travels in its own `SyncedSettingsDocument.EditorGroup`
  (ADR 0014): an editor is a person's habit, not a machine's. The custom command may name a path
  that exists on one Mac only — the trade `agentCLI.executablePath` already makes.

## Consequences

- No host is added and nothing leaves the Mac: the feature opens local files in local programs.
- The checkout paths themselves have travelled with settings sync since ADR 0014, inside the
  delegation group, although a folder path is a fact about one Mac's disk. That is unchanged here and
  noted rather than fixed in passing: moving them out of the document would silently drop every
  second Mac's clones on the next download, which needs its own decision.
- An editor whose URL scheme changes breaks only its own entry; the pure URL/argv construction
  (`EditorLauncher`) is pinned by `EditorLauncherTests`.
