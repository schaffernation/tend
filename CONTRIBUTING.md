# Contributing to Tend

Thanks for helping. This page covers how the project is laid out, how to test
a change without disturbing your own sessions, and what a pull request needs.

Before you change the design, read [docs/intent.md](docs/intent.md). It
records why Tend works the way it does, and which parts are still untested.

## How the project is laid out

- `bin/tend` is the command-line tool: one Python file that uses only the
  standard library. It holds all of Tend's behavior.
- `app/Tend.swift` is the menu bar app. It runs its bundled copy of
  `tend ... --json` and shows the result. It has no behavior of its own.
- `app/build.sh` builds the app, and `app/release.sh` builds a signed,
  notarized disk image. `app/make-dmg.sh` packages the app in the disk
  image with its designed window, drawn by `app/make-dmg-background.swift`
  and laid out by `app/make-dsstore.py`. Run it on its own to check the
  window without notarizing:
  `app/build.sh --no-install && app/make-dmg.sh app/build/Tend.app /tmp/Tend.dmg`.
  `app/sparkle.sh` downloads the pinned Sparkle release that the build and
  release scripts use, and `app/appcast.sh` makes the update feed.
- `site/` is Tend's website, plain static files with no build step. See
  [site/README.md](site/README.md).
- `app/Updates.swift` holds the app's Sparkle code: the updater and the
  **Updates** settings.
- `skills/tend` is a Claude Code skill that drives the CLI.

Three rules keep the project in shape:

- **Add behavior to the CLI first.** If the app needs it, give the command a
  `--json` option, and then show it in the app.
- **Add a program as data first.** Support for a new program is an app
  profile, like the built-in Claude profile in `bin/tend`. Add code, like a
  new `preflight` check, only when a profile can't express what you need.
- **Keep `bin/tend` to the standard library.** It has to run on any Mac with
  `python3`, over ssh, with nothing to install.

## Set up

1. Install tmux: `brew install tmux`.
2. Clone the repository, and link the CLI so your terminal runs your copy:

   ```
   git clone https://github.com/schaffernation/tend.git
   cd tend
   ln -sfn "$PWD/bin/tend" ~/.local/bin/tend
   ```

3. To build the app without installing it, run `app/build.sh --no-install`.
   Without a Developer ID certificate, the build is signed ad hoc and runs
   only on your Mac.

## Test without touching your real sessions

If you use Tend yourself, your real sessions are running while you work. Test
against a scratch config and a separate tmux server instead.

1. Point tend at a scratch config:

   ```
   export TEND_CONFIG=/tmp/tend-test/config.json
   ```

2. Start a separate tmux server. Inside tmux, `TMUX` points every tmux command
   at your current server, so unset it first. tmux socket paths must be under
   about 100 characters, so use a short folder:

   ```
   unset TMUX
   export TMUX_TMPDIR=/tmp/tend-test
   mkdir -p $TMUX_TMPDIR
   tmux display -p '#{socket_path}'
   ```

   Check that the socket path is in your scratch folder before you go on.

3. Test with throwaway commands like `sleep`:

   ```
   tend add t --dir /tmp --start -- sleep 600
   tend ls
   ```

4. To run a built app against the same setup, run:

   ```
   open -n --env TEND_CONFIG=$TEND_CONFIG --env TMUX_TMPDIR=$TMUX_TMPDIR app/build/Tend.app
   ```

5. When you're done, stop the scratch server with `tmux kill-server`, in the
   same shell.

To test Claude support without starting a real `claude rc`, use a fake
`claude` script. A real one leaves a disconnected entry in your Claude app,
and answering its trust prompt changes `~/.claude.json`. tend matches a
script by its name, so a file named `claude` that prints the trust prompt is
enough to test `tend answer`:

```
#!/bin/sh
printf 'Trust %s? [y/N] ' "$PWD"; read a
```

## Run the tests

From the repository root, run:

```
python3 -m unittest discover tests
```

The tests need only Python. The end-to-end tests also need tmux. They start
their own tmux server in a folder under `/tmp` and stop it when they finish,
so they don't touch your sessions, even if you run them inside tmux. Without
tmux, they're skipped.

Add a test with each change to `bin/tend`. Keep logic that doesn't need tmux,
like parsing or matching, in functions that take plain data, so a unit test
can call them directly.

When you change the config or state, do it inside `edit_config()` or
`edit_state()`. They hold a lock and reload the file, so a change that the
menu bar app's poll saved in the meantime isn't lost.

## Build

After you change `app/` or `bin/tend`, run `app/build.sh --no-install`. The
build treats warnings as errors.

The first build downloads Sparkle into `app/build/cache` and checks its
SHA-256. To move to a new Sparkle version, change `sparkle_version` and
`sparkle_sha256` in `app/sparkle.sh`. `build.sh` leaves out Sparkle's XPC
services, which only sandboxed apps use, and signs Sparkle's `Autoupdate`,
`Updater.app`, and the framework before the app, as Sparkle's documentation
describes for builds without Xcode.

A build whose `Info.plist` has no real `SUPublicEDKey` doesn't start Sparkle,
so it never checks for updates.

SourceKit reports "'main' attribute cannot be used in a module that contains
top-level code" for `Tend.swift`. It's a false alarm: `build.sh` compiles with
`-parse-as-library`.

If you change how the panel looks, run `app/screenshot/make.sh` to update the
screenshots in the README. It draws the real panel with example sessions, so
your own sessions don't appear.

## Write text the same way

Help text, error messages, tooltips, and docs follow the
[Google developer documentation style guide](https://developers.google.com/style):
second person, active voice, present tense, and no "simply" or "just". An
error message says what went wrong and what to do about it. In the app, hover
text goes in `.help` tooltips.

## Release

Maintainers release Tend as a disk image on GitHub Releases, and as a
Homebrew cask in the `schaffernation/homebrew-apps` tap.

1. In `app/Info.plist`, raise `CFBundleShortVersionString` and
   `CFBundleVersion`. In `CHANGELOG.md`, rename **Unreleased** to the new
   version.
2. Run `app/release.sh`. It builds, signs, and notarizes
   `app/build/Tend-VERSION.dmg`, and adds the release to the Sparkle feed in
   `site/appcast.xml`. The comment at the top of the script says how to
   store your notarization credentials.
3. Publish the release with the `gh release create` command that
   `release.sh` prints. The cask downloads `Tend-VERSION.dmg` from the
   `vVERSION` release, so keep that file name. Publish the release before
   you push the feed, because the feed's download link points at it.
4. Update the cask with the uploaded disk image, then commit it with the
   feed, and push:

   ```
   app/update-cask.sh VERSION app/build/Tend-VERSION.dmg
   git add site/appcast.xml packaging/homebrew/tend.rb
   git commit -m "Release Tend VERSION" && git push
   ```

   Pushing to `main` deploys the website in `site/`, so installed copies of
   Tend see the update right away. `update-cask.sh` sets the version and
   SHA-256 in `packaging/homebrew/tend.rb`. The `schaffernation/homebrew-apps`
   tap copies the cask from this repository within an hour. To copy it now,
   run the tap's **Sync casks** workflow on GitHub.
5. Once the tap has it, check the cask:

   ```
   brew audit --cask --strict --online schaffernation/apps/tend
   ```

The tap lists the casks it copies in its `casks.yaml`. Homebrew finds
`schaffernation/apps` at `github.com/schaffernation/homebrew-apps` by name.

## Send a pull request

1. Open an issue first for anything bigger than a fix, so we can agree on the
   approach.
2. Keep a pull request to one change.
3. If you change a command that the skill uses, update
   `skills/tend/SKILL.md`. If you change a decision recorded in
   `docs/intent.md`, update it too.
4. Add an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
5. Run the tests. GitHub Actions runs them, and builds the app, on every
   pull request.
6. In the description, say how you tested the change.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
