# Changelog

This file lists the changes in each release of Tend. Versions follow
[Semantic Versioning](https://semver.org).

## Unreleased

### Added

- `tend dropped`, `tend recover`, and `tend dismiss`: list the conversations
  a restart dropped, like Remote Control chats after a reboot, and reopen one
  in its own session. The app shows them in a banner.
- `tend config` shows where Tend keeps its files.
- `tend peek NAME` shows the last lines of a session's pane without
  attaching, and `tend rename OLD NEW` renames a session and keeps its
  history. `tend ls --json` includes each session's attach command.
- The app's session list works from the keyboard: the arrow keys select a
  session, Return opens or starts it, Space shows its recent output, Delete
  asks to stop tracking it, Command-C copies its attach command, and
  Option-Command-C copies its folder's path. Esc closes the new-session form,
  and then the panel.
- Drop a folder on the menu bar icon or the panel to start a session there,
  and drag a session out to Finder or a terminal.
- A session's context menu has Show in Finder, Copy Path, Copy Attach
  Command, Rename, and Show Recent Output.
- Tests (`python3 -m unittest discover tests`) and a GitHub Actions workflow
  that runs them and builds the app.
- A license (MIT), contributing guide, and security policy.
- The app updates itself with [Sparkle](https://sparkle-project.org). In
  **Settings > General > Updates**, you can check for updates and turn
  automatic checks on or off.
- A Homebrew cask, for `brew install --cask schaffernation/apps/tend`. It
  installs tmux and links `tend` onto your `PATH`. `app/update-cask.sh`
  points it at a new release.
- The release disk image opens to a designed window, with the Tend volume
  icon, a background with an arrow from Tend to **Applications**, and a fixed
  window size. `app/make-dmg.sh` builds it. Each release also has a
  `Tend.dmg`, so `releases/latest/download/Tend.dmg` always gets the newest
  version.
- A website, in `site/`: plain static files for
  [tend.schaffernation.com](https://tend.schaffernation.com), with a download
  button that shows the newest version from the Sparkle feed. `app/appcast.sh`
  now writes the feed to `site/appcast.xml`, and `site/make-images.swift`
  makes the site's icons and link preview image from the app icon.

### Changed

- Tend's menu bar item opens and closes its panel as soon as you press the
  mouse button, as Control Center's items do, and looks pressed while the
  panel is open.

- On macOS 26 and later, the panel looks more like the Mac's own menu bar
  panels: it hangs 2 points below the menu bar, as a menu does; section
  headers are 11 points, as in a menu; and Settings… and Quit Tend are menu
  items at the bottom, like Control Center's "Sound Settings…".
- Tend calls tracked tmux sessions "sessions" everywhere. A new config file is
  named `sessions.json`. An existing `services.json` keeps working.
- tend adds Homebrew and `~/.local/bin` to the end of your `PATH` instead of
  replacing it, so your own tools come first.
- The app polls only what changes on its own, and asks `tend folders` for
  folder suggestions.
- The menu bar panel behaves like a native one: it opens under the icon,
  highlights the icon while it's open, closes when you click elsewhere, and
  works over full-screen apps and on every Space.
- The new-session form chooses its folder with a standard path pop-up, which
  lists recent and nearby folders and opens the standard folder picker.
- The Accounts settings list watched accounts with + and − buttons, as in
  System Settings.

- On macOS 26 and later, the menu bar panel uses Liquid Glass: a glass
  background, the refresh and plus buttons in one glass group, glass Start
  and Cancel buttons, and cards with corners that follow the panel's. macOS
  14 and 15 keep the earlier design.

- The app icon is a layered icon, so macOS 26 and later show it as glass,
  and in the dark, clear, and tinted icon styles.

- On macOS 26 and later, each Settings pane sizes the window to fit, so
  General no longer scrolls.

### Fixed

- On macOS 26 and later, the panel had no shadow, so it didn't stand out
  from what's under it the way the Mac's own panels do. It now casts one
  that follows its rounded corners, and the shadow follows the panel as it
  grows and shrinks.
- Cut, Copy, Paste, Select All, and Undo didn't work in the panel's text
  fields.
- VoiceOver read some icons by their symbol names, like "bubble.left, off".

- Two Tend commands that changed the config at the same time, like the app's
  poll and `tend new`, could lose one of the changes. Changes now happen
  under a lock.
- `tend open` failed for a session whose name had a character outside ASCII,
  like `café`.
- A config file with a JSON error printed a Python traceback. tend now says
  where the error is.
- A tmux session started with a command instead of a shell showed as exited,
  and `tend snapshot` saved it as a plain shell.
- The **Restore sessions after the Mac starts** setting could show the wrong
  value in Settings.
- An app installed after Tend opened showed no icon until Tend restarted.

- On macOS 27, the panel could show no sessions and stop refreshing,
  because the app waited forever for a `tend` command that had finished.
- With many sessions, the panel ran off the bottom of the screen, and you
  couldn't reach the last rows. Now it stops above the bottom of the screen
  and its list scrolls, with the header and footer in place, and the arrow
  keys scroll the selected session into view.

## 0.1

The first version.

- `tend` command-line tool: track tmux sessions, start, stop, restart, and
  restore them, and attach to or open them in a terminal.
- Menu bar app that shows each session's state and runs `tend` for you.
- Built-in Claude Code support: busy and idle status, reconnecting a restored
  Remote Control session to its last conversation, conversation history with
  `tend history` and `tend resume`, and answering the trust prompt with
  `tend answer`.
- App profiles, so Tend can recognize any program.
- Setup commands and recipes for new folders, like cloning a repository.
- Warnings when another account on the Mac isn't logged in or isn't running
  Tend.
- A Claude Code skill that starts and manages sessions.
