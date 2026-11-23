# Tend: intent, design, and open threads

This file records why Tend exists, what was decided while building it, and
what's still open. Tend started on November 4, 2026, as a script in a
personal automation project, and became its own project soon after.

## Why Tend exists

Tend is for someone who runs several Claude Code sessions as `claude rc`
(Remote Control) inside detached tmux sessions, so they can drive each one
from claude.ai/code or a phone. A small shell script started each session.
After a reboot, or when a session dies, they want the sessions back: the same
folders, and ideally the same conversations.

The requirements grew in this order:

1. A script that restores every Claude tmux session.
2. Maybe a Mac menu bar app that manages them.
3. Generic: a manager for background processes and restoring them, which also
   knows about Claude in particular.
4. Generic app recognition: pick Claude from a list of apps, where an app can
   be any program, recognized by process parentage.
5. A plus button that starts a new session, replacing the shell script.
6. Tend as its own project.

The direction: a general tool for long-running, restorable terminal processes,
with first-class support for programs (like Claude) that can tell Tend how to
resume them.

## Architecture

Two parts. All behavior lives in the CLI; the app is a thin client.

- **`bin/tend`** is a single-file Python 3 script that uses only the standard
  library. It owns the config, tmux, process detection, and start, stop, and
  restore. It must keep working over ssh, with no GUI.
- **`app/Tend.swift`** is a SwiftUI app, built with plain `swiftc` (no Xcode
  project). A small AppKit controller owns the menu bar item and its panel
  (see "The menu bar panel is AppKit" below); everything inside is SwiftUI. It runs its bundled copy of `tend ... --json` and
  renders the result. Every 5 seconds it polls what changes on its own
  (`ls`, `accounts`, and `dropped`). It loads apps, recipes, terminal
  settings, and the config path when it opens and after an action that
  changes them. It asks `tend folders` for the new-session form's
  suggestions, rather than listing folders itself.

Keep this split: new behavior goes in the CLI first, and then the app exposes
it.

### Core concepts

- **Session**: a tracked tmux session. Fields: `name`, `dir`, `command` (what
  a fresh start types), `resume` (what a restore types, saved automatically),
  `autostart`, and `restore_conversation` (stored only when it's off). Stored in `~/.config/tend/sessions.json`. Earlier versions
  called these services and stored them in `services.json`, under a
  `services` key; tend still reads that file and key, and writes back the key
  the file used.
- **App**: a profile that tells Tend how to recognize a program and,
  optionally, how to read its state and resume it. Claude is the only built-in
  app (`BUILTIN_APPS` in `bin/tend`). The comment block above
  `BUILTIN_APPS` documents every field. Entries in the config's `apps` list
  override built-in apps by `id`, or add new ones.
- **Runner**: the engine that keeps processes alive in the background. Today
  this is always tmux. See [Is tmux core?](#is-tmux-core).

### How starting works

Tend creates a detached tmux session with a login shell in `dir`, then types
the command with `send-keys`. The shell loads the user's normal environment,
and it stays open when the command exits, so the error stays readable. Tend
shows that case as `exited`. This copies the original shell script's approach
on purpose.

If the config sets `tmux_launch_agent`, Tend makes sure that the tmux server
runs inside that launch agent before it starts a session, so that sessions
created over ssh can still read the login keychain. Tend doesn't install the
agent. The README has an example that runs `tmux -D` (the server in the
foreground) with `KeepAlive`.

### Restoring once per boot

The app runs `tend restore --once` when it opens. tend records the boot time
in `state.json`, next to the config, and restores only on the first run after
the Mac starts. The tmux server doesn't depend on the app, so a crash or
relaunch of the app must not touch sessions: a session you stopped on purpose
stays stopped. `tend restore` without `--once` always restores.

### Other accounts

Each account runs its own Tend, and each Tend keeps only its own account's
sessions alive. We considered running another account's sessions from this
one, as a system launch daemon with that account's user. We chose not to:
that account's login keychain stays locked without a login, so Claude Code
needs a separate token. Background processes can't get macOS privacy
permissions. Apps that need a desktop, like Photos, can't run at all.

Instead, `tend accounts` watches other accounts and warns when one isn't
logged in or isn't running Tend. macOS can't log a second account in on its
own, so a person still logs it in after a restart. The check uses only the
process list (`pgrep -u USER loginwindow` and `Tend`), so it needs no shared
files and no access to the other account.

### How detection works

Each status check (`tend ls`) combines three sources:

1. `tmux list-panes -a` gives each session's panes, folder, and shell PID.
2. `ps -ax -o pid,ppid,command`, plus `proc_pidpath` from libproc (through
   ctypes) for real executable paths, gives the process tree. Tend walks down
   from each pane's shell. The highest process that matches an app wins, so
   programs that start copies of themselves, like Claude, show up once.
3. App metadata files. Claude writes `~/.claude/sessions/<pid>.json`. Tend
   links a file to a session when the file's `pid` is a process inside that
   session's panes. From that file, Tend reads `status` (busy or idle), `name`,
   and the IDs that its resume templates need.

`tend ls` also saves the current resume command for each running tracked
session, so a restore uses the latest conversation. That side effect is
deliberate, and lives in `sync()`: `status()` itself only reads, so `wait`,
`answer`, and `folders` can scan without writing anything.

### Claude specifics

- Remote Control resume: the same command, like `claude rc`. When Remote
  Control stops, it keeps its environment, and a plain restart reconnects the
  last conversation in server mode, where the Claude app's plus button starts
  new sessions in that folder. Tend used `--session-id {bridgeSessionId}`
  before, and `--continue` is the other option. Both reconnect in
  single-session mode, which grays out the plus button, and `--continue` only
  works for about 4 hours.
- Remote Control forgets an environment after a while, and then a plain
  restart starts a new conversation. So tend records every conversation ID it
  sees in `state.json` (`history`, the last 20 per session), and
  `tend resume` brings one back with `--session-id`, in single-session mode.
  A later plain restart returns to server mode and keeps the conversation.
- After a single-session process stops, Remote Control needs about 45
  seconds to release the folder; starting sooner fails with "already
  served". The profile's `release_wait` covers it.
- Restarting the session tend runs in: tend hands the command to the tmux
  server with `run-shell -b`, marked with `TEND_HANDED_OFF`, because
  `run-shell` sets `TMUX` and `TMUX_PANE` and the handed-off command would
  otherwise hand off again forever.
- Interactive resume: `claude --resume {sessionId}`.
- `strip_flags` removes `--continue`, `--session-id`, and `--resume` from the
  saved `command`, so **Start fresh** really is fresh.
- Trust: in a folder that isn't trusted (itself or a parent, in
  `~/.claude.json`), `claude rc` prints `Trust FOLDER? [y/N]` and waits.
  `y` connects, and Claude records the trust itself. `n` exits with "is not
  trusted". (Tested with 2.1.318. Older versions exited right away, which is
  why `preflight: "claude-trust"` first refused to start there.) Now the
  profile's `questions` entry recognizes the prompt, the app shows Trust and
  Don't trust buttons on the row, and `tend answer NAME yes|no` types the
  reply. The preflight only prints a note saying where to answer.

## Decisions and why

- **Every change to a file happens under a lock.** The app runs `tend ls`
  every 5 seconds, and `ls` saves resume commands. Without a lock, an `ls`
  that loaded the config before a `tend new` saved could write its older
  copy back, and the new session would disappear. `edit_config()` and
  `edit_state()` take an `flock` on `.tend.lock`, load the file fresh, and
  save it. `tests/test_tend.py` checks this with concurrent writers.
- **Python standard library only** for the CLI, so it runs on any Mac with
  `python3`, including over ssh, with no install step.
- **Homebrew ships a cask in a personal tap, not homebrew/cask.** The
  official repository wants a notable project (for a self-submission, three
  times the 30 forks, 30 watchers, or 75 stars it asks of others) at least 30
  days old, so it waits until Tend has that. The cask in
  `packaging/homebrew/Casks/tend.rb` is the source of truth;
  `app/update-cask.sh` copies it into `schaffernation/homebrew-tend`. It
  depends on the tmux formula but not on Python: Homebrew itself needs the
  Command Line Tools, so `/usr/bin/python3` (3.9 on macOS 14) already works
  wherever the cask installs, and a `python@3.x` formula would pull in a
  large, versioned dependency the CLI doesn't need. `binary` links the
  bundled `tend` onto `PATH`; `tend` resolves the link to its real path when
  it calls itself. `auto_updates true` because Sparkle updates the app, so
  `brew upgrade` leaves it alone. `zap` trashes preferences and caches but
  keeps `~/.config/tend`: the session list is something you wrote, a source
  checkout's CLI uses the same file, and your tmux sessions keep running
  after an uninstall, so a reinstall should find them tracked.
- **Typing the command into a shell** instead of `tmux new-session <cmd>`, for
  the user's environment and readable errors.
- **Tooltips, not a hint line.** One version showed hover help in a line at
  the bottom of the panel. Standard `.help` tooltips worked better. Keep the
  descriptive tooltip text.
- **Apps are data, not code.** Claude's support is a profile in the same
  format that users write. A new program's support should be a profile first,
  and code (like a `preflight` check) only when data can't express it.
- **App icons come from installed apps, not favicons.** A profile's `icon` is
  a bundle ID or a path, and the app asks macOS for that app's icon. This
  works offline and matches what's in the Dock. Claude's profile uses the
  Claude desktop app's icon, even though the program is Claude Code.
- **Answer Claude's own trust prompt; don't write `~/.claude.json`.** Setting
  `hasTrustDialogAccepted` ourselves would be simpler, but that file is
  Claude's, and running Claude processes rewrite it often. `tend answer`
  checks that the question is still on screen before it types, so it never
  types `y` into a shell.
- **Report prompts no profile names, but only while an app starts.** Claude
  Code adds prompts without notice, like the spawn-mode choice
  (`Choose [1/2]`), and a session stuck on one looks like it's just slow.
  So until an app has started (see `tend wait` below), tend treats a
  visible cursor waiting at the end of the last line as a question named
  `prompt`, whatever the line says. It sends the lines above as context,
  guesses answers from `[y/N]` or numbered choices, and accepts any reply
  with `--text`. To skip spinners and progress lines, the screen must hold
  still across two captures 0.3 seconds apart, and `tend wait` must see the
  same prompt twice. Once an app has started, its own UI (like Claude's
  input box) would look like a prompt, so tend stops guessing. Profile questions still come first, and
  tend joins wrapped lines (`capture-pane -J`), since a detached pane is 80
  columns and a long folder path wraps the trust prompt.
- **`tend wait` decides when a new session is ready.** The trust question
  can be answered in the menu or by the skill in chat, and the first answer
  wins, so the skill waits for the session's state instead of trusting its
  own answer. "Ready" means the app has started: it reports a status, or
  its pane shows the mode's `ready` line. Claude's session file reports a
  status, but in a real test that came about 35 seconds after answering
  trust, and Claude Code 2.1.322 writes no session file for `claude rc`
  until a conversation starts. So Remote Control mode is ready at its
  `Capacity: 0/32` line, which follows "Ready" or "Connected". An app with
  neither a status field nor a `ready` line is ready once its command runs. `wait` allows 10 seconds for the shell to start
  the command before it believes "exited". When a session's command starts
  a known app, `wait` also waits until it finds that app: a login shell runs
  helper programs while it starts, and `wait` once took one of them for the
  command and said "ready" while `claude` was failing.
- **Setup runs once, outside the session.** `tend new --setup CMD` (or
  `--recipe ID --input TEXT`) runs in the folder before tend tracks the
  session, with the login shell's environment, so a failed clone shows its
  error in the form and starts nothing. It's never saved as the command, so
  restarts don't repeat it. `claude rc` takes no starting prompt, so a recipe
  that copies in a `CLAUDE.md` is the way to give new folders instructions.
  Recipes are data (`recipes` in the config); `clone` is built in.
- **Scripts match by their own name.** A script run by an interpreter (like
  `sh tailscale-keepalive`) looks like `sh` to the process table, so matching
  also checks the script's name and path. Without that, no profile could
  recognize a shell script.
- **`tend new --command STRING`** passes a raw shell string, because the app
  can't split a command into arguments safely.
- **The app's new-session form lives in the model**, not view state, because
  the menu bar panel can close while a folder picker is open.
- **The panel is for sessions; settings have their own window.** Apps,
  Terminal, Accounts, startup, the command-line tool, and the config file
  are in a `Settings` scene, so they don't compete with the sessions.
- **Rows keep their order.** Moving sessions that need attention to the top
  made rows jump around. Instead, a question shows as a card under its row, and
  errors and account problems show as banners at the top of the panel.
- **Each restore setting has an icon next to the name.** Restore at login is
  `autostartstop`, and Restore conversation is a speech bubble. A setting
  that's off always shows its icon, slashed. Settings that are on, the usual
  case, show lighter while you hover, so you can check any row. SF Symbols has
  no slashed bubble, so `SlashedSymbol` draws Apple's slash, measured from
  `flag.slash`, `bell.slash`, and `autostartstop.slash`, extended a little
  into the bottom-right corner. `ConversationIcon` draws the bubble at 90%
  and one weight heavier, so it matches `autostartstop` in size and stroke. The new-session form labels its toggles with the same
  symbols.
- **Orange means "needs you."** Questions and account problems use it.
  Nothing else does: an exited session's badge is yellow.
- **Restart asks first, inline.** Restart and Start fresh turn the row's
  buttons into a red confirm button that goes away after 6 seconds. Restart
  has its own icon, so it doesn't look like refresh. An inline confirm was
  chosen over `confirmationDialog`, which is unreliable from a menu bar panel.
- **Row buttons show on hover**, except the main one (Open, or Start). A
  setting shows them all the time. The hidden buttons keep their space, so
  the row doesn't shift.
- **The menu bar panel is AppKit; what's in it is SwiftUI.** `MenuBarExtra`
  can't take a drop on its icon, highlight the icon while its window is
  open, or keep the window open while a folder picker runs. So
  `StatusPanelController` owns an `NSStatusItem` and a borderless
  `NSPanel` (`TendPanel`) that hosts `ContentView` in an
  `NSHostingController`, and `TendApp` keeps only the `Settings` scene,
  through an `NSApplicationDelegateAdaptor`. The panel is
  `.nonactivatingPanel`: it takes the keyboard without making Tend the
  active app, the way a menu does, so the app you were in keeps the menu
  bar. It uses the `.menu` material, joins every Space and full-screen apps,
  hangs under the item, and resizes with its content's
  `preferredContentSize`. It closes when it loses the key window (as when
  Settings opens), on a click in another app (a global event monitor), on
  Esc, and when the Space changes, except while a modal window like the
  folder picker is open; `StatusPanelController.runModal` drops the panel
  below the picker for that time. The icon's symbols are drawn into one
  template image, so the menu bar tints them. A drop on the icon goes to the
  status item's window delegate, the documented route for a window whose
  views don't take a drag. When the menu bar hides the item (it's full),
  the panel opens at the right end of the menu bar.
- **Copy and paste go through SwiftUI's main menu.** A SwiftUI app builds a
  main menu with the standard Edit menu even when it's `LSUIElement`, so
  Cut, Copy, Paste, Select All, and Undo exist. Because the panel doesn't
  activate Tend, `TendPanel.performKeyEquivalent` passes key equivalents
  to the main menu itself after the panel's own views decline them.
- **The session list has one selection, like a source list.** Tracked and
  untracked sessions form one focusable list (`.focusable` with
  `onKeyPress`), not a SwiftUI `List`, because a `List` scrolls and has no
  height of its own, and the panel sizes to its content. The selected row
  uses the system's selection colors (`selectedContentBackgroundColor` while
  the list has the keyboard, `unemphasizedSelectedContentBackgroundColor`
  otherwise) with white text, and there's no separate focus ring, as in a
  source list. The selection, the row being renamed, the inline
  confirmation, and the open peek live in the model, so keys, Esc, and the
  context menu all reach them. Rows still keep their order, and a selected
  row shows its buttons, as a hovered one does.
- **Command-C copies the attach command.** Copying a session most often
  means "let me attach to it in a terminal I already have", so Command-C
  puts `tend ls --json`'s `attach` field (`tmux attach -t =NAME`, or your
  attach command) on the clipboard as text. Putting the folder there as a
  file too would make Paste in Finder copy the folder, so the path is
  separate: Copy Path in the context menu, or Option-Command-C, as in
  Finder. Dragging a row out does offer both, since the drop target
  chooses: Finder and Dock icons take the folder, text views take the
  command.
- **Delete asks first, in the row.** Delete and Command-Delete turn the row's
  buttons into a red Stop tracking confirmation, like Restart's, rather than
  a dialog.
- **The folder chooser is a pop-up `NSPathControl`.** It replaced a SwiftUI
  `Menu` labeled Choose, because the path control shows the folder with its
  icon, lists its parent folders, takes a dropped folder, and looks like
  every other folder pop-up on the Mac. `FolderPicker` rebuilds its menu in
  `pathControl(_:willPopUp:)`: the parents, then the Recent and Nearby
  folders from `tend folders`, then Choose…, which runs the open panel
  through `runModal`. `NSPathControl` tells VoiceOver it's static text, so
  a small subclass reports it as a pop-up button that VoiceOver can open.
- **Peek is read-only and CLI-first.** `tend peek` reads the pane with
  `capture-pane` and doesn't call `sync()`. The app shows its output under
  the row, not in a popover: a popover is its own window, and clicking its
  text would take the key window from the panel and close both.
- **Updates come from Sparkle, with a feed on our own site.** Tend ships
  outside the App Store, so it needs its own updater. Sparkle is the
  standard one for Mac apps: it checks a signed feed, verifies each update
  with an EdDSA key as well as the Developer ID signature, and replaces the
  app in place. Writing our own would mean redoing that security work.
  `build.sh` downloads Sparkle's official release, pinned to one version and
  checked by SHA-256 (`app/sparkle.sh`), instead of vendoring the framework,
  so the repository stays small and an upgrade is a two-line change. Tend
  isn't sandboxed, so the build leaves out Sparkle's XPC services. The
  disk images stay on GitHub Releases; the appcast lives at `SUFeedURL` in
  `Info.plist` (`https://tend.schaffernation.com/appcast.xml`), because
  installed copies check that address forever. The feed is on Tend's own
  subdomain, not under a path on schaffernation.com, so it depends only on
  a DNS record: moving Tend's site to another host, or changing how
  schaffernation.com routes its pages, can't break it. A build without a real
  `SUPublicEDKey`, like a fork's, doesn't start Sparkle at all. Tend is a menu bar app, so it brings
  Sparkle's windows to the front itself.
- **Action errors and refresh errors are separate.** An action's error stays
  until you close it or take another action. Before, the refresh that follows
  every action cleared it right away, so most action errors never showed.

### Sessions that don't restore their conversation

Some sessions only need to be running, not to continue a particular
conversation. The first example: a `claude rc` session in a folder you start
other sessions from, so you can always reach the Mac from the Claude app.
Losing its conversation doesn't matter, and the dropped list shouldn't nag
about it.

So a session has a `restore_conversation` setting, on by default. With it
off, `start()` types the session's plain `command`, and `sync()` skips the
session: no saved `resume`, no history, and no `live` entry, so nothing lands
on the dropped list. Turning it off also removes the saved `resume`, the
`live` entry, and the session's dropped conversations. Otherwise the session
is like any other: it restores at login, stops, and restarts the same way.
For Claude, a plain `claude rc` still starts in server mode.

We considered making this a special kind of session (a "lead" or "hub" that
Tend keeps running and restarts when it dies). We chose a setting instead,
named for what the other sessions do, because the session isn't otherwise
different. Restarting a session that dies is a separate question for every
session (see "Is tmux core?"). Pinning sessions to the top of the list is
planned as its own setting.

### Dropped conversations

On Nov 7 the Mac rebooted, and every Remote Control chat lost its
connection. tend restored each `claude rc` root, but the roots came back as
new servers, and the Claude app showed the old chats as disconnected. Their
background tasks died with the reboot, and their output, in `/tmp`, went
with it. `tend resume` couldn't help: the server had deleted each chat's
environment ("The environment this session was running on has been
deleted"), and `claude remote-control --session-id` failed with a
misleading "This folder is already served" error, however long it waited.
The transcript was still on the Mac, under `~/.claude/projects/`.

So:

- **The root always comes back working.** If `tend resume` can't reattach,
  it starts the session's usual command and puts the conversation on the
  dropped list.
- **Getting a chat back is a choice.** On each sync scan, tend records each
  session's app process (PID and boot time) and its conversations, with the
  profile's `recover` command filled in from each one's metadata, in
  `state.json` (`live`). When the app comes back as a new process, its
  conversations that don't run now go on the dropped list (`dropped`).
  `tend recover NAME ID` starts a new session in the same folder that runs
  the `recover` command, `claude --resume {sessionId} --remote-control`,
  with autostart off, so a restore doesn't bring back a second copy of the
  root. The app shows the list in a banner, with Recover and Dismiss.
- **`tend stop` and `tend rm` forget a session's conversations**, because you
  stopped it on purpose. A restart, a reboot, or a crash doesn't.
- **A conversation that runs again comes off the list**, and the list shows a
  conversation only after 30 seconds, because a plain restart reconnects one
  a few seconds after the root starts. Entries expire after 7 days.
- **Background tasks don't come back.** The recovered chat can see in its
  transcript what it was running, so you ask it to start them again.

## Is tmux core?

Discussed and settled for now: yes, tmux stays the engine. It provides a
terminal for interactive programs, attaching from anywhere (including ssh),
and processes that outlive both the terminal and Tend itself. An app that
owned the processes directly would kill them on every rebuild, unless it
grew a daemon, which would amount to rebuilding tmux.

tmux doesn't restart crashed commands, keep logs, or survive reboots. Restore
covers reboots.

The agreed shape for the future: treat tmux as one **runner** behind a
narrow boundary (start, stop, attach, and "what's the root PID"). A `launchd`
runner could suit headless services that should restart on a crash and log to
files, like dev servers. Detection, apps, and the UI would carry over
unchanged, because they only need a root PID. Build that runner when a real
headless service needs it, not before. Until then, keep tmux calls together
in `bin/tend`.

## Open threads

Untested, in rough order of risk:

1. **How long Remote Control keeps its environment.** A plain `claude rc`
   restart reconnected the last conversation a minute later. A reboot is
   different (see "Dropped conversations"). Whether a plain restart still
   reconnects after a night, without a reboot, isn't confirmed.
2. **`tend recover` with a real `claude`.** The dropped list, recover, and the
   resume failover were tested only with a fake `claude` script on a scratch
   tmux server. That `claude --resume ID --remote-control` reconnects a
   Remote Control chat's transcript in the Claude app isn't confirmed.
3. **The plus button** starting a real `claude rc` session.
4. **The app's UI.** On November 22, 2026 (macOS 27.2), a build ran against a
   scratch config and tmux server, driven with key events posted to its
   process only and with accessibility actions. Seen working in the real
   panel, in light and dark: the panel's material, corners, and resizing;
   the arrow keys, Return on a stopped session, Space and the peek area,
   Delete and Command-Delete with the inline confirmation, Esc closing the
   confirmation, then the form, then the panel; Command-N; Command-C and
   Option-Command-C on a row; Command-A, C, X, V, and Z in the rename field;
   inline rename through `tend rename`; the path pop-up's menu, and Choose…
   opening the folder picker above the panel, which stayed open and took the
   keyboard back; Settings opening from the panel and coming to the front,
   with the panel closing; the Accounts list with + and −; the VoiceOver
   labels and row actions, read through the accessibility API. Not seen:
   the menu bar item itself, because the test Mac's menu bar was full and
   hid it (so the icon, its highlight, and the panel's position under it),
   any drag and drop (onto the icon, the panel, or the path control, or a
   row dragged out), hover, a click on a row, and closing on a click in
   another app. Synthetic mouse events posted to one process don't reach
   its windows, and posting them system-wide would have clicked the
   user's own windows.
5. **Open in terminal** (iTerm through AppleScript) from inside a tend
   session fails with "Not authorized to send Apple events to iTerm
   (-1743)". When a launch agent starts the tmux server (see
   `tmux_launch_agent`), macOS sees `/opt/homebrew/bin/tmux`, a background program, as
   the sender. It can't show an Allow prompt for that, so it denies, and
   `tccutil reset` doesn't help. `tend open` works from an iTerm window and
   from the app. A fix: when `tend open` runs inside tmux, hand the request
   to Tend.app, which has the permission.
6. **Open at login** through `SMAppService` with an ad hoc signed app.
7. **A renamed folder strands its session.** When a project folder was
   renamed, from `app` to `app-ios`, its session kept running (processes follow
   the rename), but its tracked `dir` pointed at a folder that no longer
   existed, so a restart or restore would fail. `tend ls` could flag a
   tracked `dir` that's missing.
8. **Remote Control entries outlive their process.** After a test
   `claude rc` stops, its environment stays in the Claude app and at
   claude.ai/code as disconnected for a while, and `claude rc` has no command
   to remove it. A session stopped minutes earlier can still show as
   connected until the app catches up.
9. **Sparkle updates end to end.** The build, signing, and an appcast signed
   with a throwaway key were checked, and the framework loads. No real
   update has been installed yet: that needs two notarized releases and a
   published feed. Also unseen: Sparkle's permission prompt (on the second
   launch) and update window in the real menu bar, and whether they come to
   the front.

Ideas raised but not built:

- A `launchd` runner (see above).
- UI for app metadata and resume templates. Today, only the config file can
  set them for custom apps.
- An existing launcher script can become a thin wrapper around
  `tend new claude`, instead of starting the session itself and then
  registering it with `tend add`.
