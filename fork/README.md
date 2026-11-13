# Azulejo's herdr fork

A personal build of [herdr](https://github.com/herdrdev/herdr) for use with
Azulejo. It's upstream's latest stable release plus a few commits. This
directory holds the fork's own files; upstream never touches it, so rebases
don't conflict here.

- `BASE`: the upstream tag the branch sits on, e.g. `v0.9.5`.
- `update.sh`: rebase, build, test and install.

## What the fork changes

The `azulejo` branch is `BASE` plus these commits, oldest first:

1. `feat: add terminal.resize_pull_scrollback`: backports Ghostty's
   `resize_pull_scrollback` into the vendored libghostty-vt as local patch
   `vendor/patches/libghostty-vt/0008-resize-pull-scrollback.patch` (C option
   value 42 locally) and adds `[terminal] resize_pull_scrollback` (default
   `true`). This is the version proposed upstream; keep it as it is.
2. `feat(fork): turn terminal.resize_pull_scrollback off by default`: when
   a pane grows, the screen keeps its top row and output that scrolled off
   stays in scrollback. That stops Ink-style TUIs from stacking stale copies of
   their bottom block when Azulejo resizes panes. Set it back to `true` in
   `config.toml` for the usual behaviour.
3. `feat(fork): report fork builds as <version>+azj.1`: `build.rs` sets
   `HERDR_FORK_BUILD=azj.1`, and `herdr --version`, `herdr status` and the
   API's `version` fields report e.g. `0.9.5+azj.1`. The API protocol number
   doesn't change. Bump the suffix in `build.rs` (and nowhere else) when the
   fork's own commits change on the same base.
4. `feat(fork): never install upstream releases over a fork build`:
   `herdr update` exits 1 and points here, the background update check is
   off, and the TUI's install hint says `fork/update.sh`.
5. `chore(fork): add fork update script and notes`: this directory.

`update.sh` adds `chore(fork): track upstream vX.Y.Z` commits when it moves
the base.

## Updating

From the fork checkout, on the `azulejo` branch:

```sh
fork/update.sh              # rebase if needed, build, test, install to ~/.local/bin
fork/update.sh --dry-run    # fetch tags and say what would happen
fork/update.sh --no-install # rebase, build and test only
fork/update.sh --install-dir /some/dir
```

It:

1. Checks the toolchains against herdr's pins (`rust-toolchain.toml` and
   `minimum_zig_version` in `vendor/libghostty-vt/build.zig.zon`). If the
   pinned Rust isn't installed it uses rustup's default toolchain and warns.
   It finds Zig through `$ZIG`, then `zig` on `PATH`, then mise.
2. Fetches `origin`'s tags and picks the newest stable `vX.Y.Z` (no
   previews). If it's newer than `BASE`, it runs
   `git rebase --onto <new> <BASE>` and commits the new `BASE`. Rebases and
   that commit reuse the identity that last committed `BASE`, not your global
   git identity.
3. Builds release, runs the test suite with `cargo nextest`
   (`cargo install cargo-nextest --locked` if it's missing), and checks that
   `--version` carries the `+azj` suffix.
4. Backs up the installed binary as `herdr.bak-<YYYYmmdd-HHMMSS>` next to it
   and moves the new one into place with an atomic rename.
5. Prints the live-handoff command. It never restarts a server itself.

### Moving a running server to the new binary

Installing doesn't touch running servers: they keep the old binary until they
restart, and restarting kills every pane. herdr's live handoff swaps the
binary under a running server and keeps the panes and their processes. It's
what `herdr update --handoff` does after an upstream install. `update.sh`
prints the exact command, which looks like:

```sh
~/.local/bin/herdr server live-handoff --import-exe ~/.local/bin/herdr \
  --expected-version 0.9.5+azj.1 --expected-protocol 22
```

For a named session, put `--session <name>` before `server`.
`herdr session list` lists the sessions. The old server spawns the new binary,
passes it the pane descriptors, waits for it to restore, then exits. Both
sides need the same API protocol. If the protocol changed between versions,
the handoff refuses: stop the server when its agents are idle
(`herdr server stop` or `herdr session stop <name>`) and start it again.

### When a rebase stops on conflicts

The script stops and prints what to do: fix the files, `git add` them,
`git rebase --continue` (the printed command keeps the fork's git identity),
then rerun `fork/update.sh`. It sees the new tag in the branch and only bumps
`BASE`. `git rebase --abort` puts the branch back.

Conflicts most likely come from:

- **libghostty-vt.** If upstream re-vendors libghostty-vt, the vendored files
  that patch 0008 edits conflict. Take upstream's vendored tree and reapply
  `vendor/patches/libghostty-vt/0008-resize-pull-scrollback.patch` on top, as
  `vendor/libghostty-vt.patches.md` describes. Once upstream's vendored
  libghostty-vt reaches Ghostty 1.4.0 or newer, it has
  `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK` itself, and the 0008 patch and
  its index entry go away. Only two things remain: the option number in
  `crates/ghostty-vt/src/bindings.rs` (upstream's value, 40, instead of the
  local 42) and the `[terminal] resize_pull_scrollback` config key.
- **`src/update.rs`.** The guard adds a few lines at the top of
  `self_update`, `auto_update`, `update_install_command` and
  `package_manager_channel_update_guidance_for_current_install`.
- **`src/build_info.rs`** and the version assertions in `tests/api_ping.rs`
  and `tests/cli/sessions.rs`.

## Installing on a remote machine by hand

`herdr --remote` and saved SSH machines need a herdr on the remote. The fork
can't download itself, so put it there yourself:

- **Same OS and CPU** (e.g. macOS arm64 to macOS arm64): herdr copies the
  local binary when you attach, or point it at one explicitly:
  `HERDR_REMOTE_BINARY=target/release/herdr herdr --remote <host>`.
  Or copy it by hand:

  ```sh
  scp target/release/herdr <host>:.local/bin/herdr.new
  ssh <host> 'mv ~/.local/bin/herdr.new ~/.local/bin/herdr'
  ```

- **Different platform** (e.g. Linux): clone this branch on the remote,
  install Rust and Zig there, and run `fork/update.sh` on it.

Then move any running remote server with the live-handoff command above, run
on the remote.

## Going back to stock herdr

1. Put a stock binary back. Either restore the oldest backup
   (`ls ~/.local/bin/herdr.bak-*`) with
   `mv ~/.local/bin/herdr.bak-<stamp> ~/.local/bin/herdr`, or reinstall
   upstream with `curl -fsSL https://herdr.dev/install.sh | sh`.
2. Move running servers onto it with the same live-handoff command, using
   the stock version (`herdr --version`, e.g. `0.9.5`) as
   `--expected-version`. Or restart them when idle.
3. `herdr update` works again from then on. Stock herdr doesn't know
   `resize_pull_scrollback`: drop it from `config.toml`, or herdr reports an
   unknown config key. Stock herdr always pulls scrollback.
