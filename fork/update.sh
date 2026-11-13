#!/usr/bin/env bash
# Update the Azulejo herdr fork: rebase onto the newest upstream stable tag,
# build, test and install. See fork/README.md.
#
# usage: fork/update.sh [--install-dir DIR] [--dry-run] [--no-install]

set -euo pipefail

usage() {
    cat <<'EOF'
usage: fork/update.sh [--install-dir DIR] [--dry-run] [--no-install]

  --install-dir DIR  install herdr into DIR (default: $HOME/.local/bin)
  --dry-run          fetch tags and print what would happen; change nothing
  --no-install       rebase, build and test, but don't install
EOF
}

install_dir="${HOME:?HOME is not set}/.local/bin"
dry_run=0
no_install=0
while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            install_dir="$2"
            shift 2
            ;;
        --install-dir=*)
            install_dir="${1#--install-dir=}"
            shift
            ;;
        --dry-run) dry_run=1; shift ;;
        --no-install) no_install=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Never talk to the herdr session this shell may sit in.
unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID \
    HERDR_WORKSPACE_ID HERDR_ENV HERDR_SESSION

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"
if [ -e "$(git rev-parse --git-path rebase-merge)" ] || [ -e "$(git rev-parse --git-path rebase-apply)" ]; then
    die "a rebase is in progress; finish it (git rebase --continue) or abort it (git rebase --abort), then rerun"
fi
[ -f fork/BASE ] || die "fork/BASE is missing; run this from the fork branch"

# --- Git identity --------------------------------------------------------
# Rebases and BASE bumps reuse the identity that owns the fork commits, so a
# global git identity never leaks into the fork's history.
fork_ident="$(git log -1 --format='%an%x09%ae' -- fork/BASE)"
[ -n "$fork_ident" ] || die "fork/BASE isn't committed yet"
export GIT_AUTHOR_NAME="${fork_ident%%$'\t'*}" GIT_AUTHOR_EMAIL="${fork_ident#*$'\t'}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# --- Toolchains ----------------------------------------------------------
# rustup's own proxies first: version-manager shims may have no Rust set.
cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
[ -x "$cargo_bin/rustup" ] && export PATH="$cargo_bin:$PATH"
rust_pin="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
zig_pin="$(sed -n 's/.*minimum_zig_version *= *"\(.*\)".*/\1/p' vendor/libghostty-vt/build.zig.zon)"

if [ -z "${RUSTUP_TOOLCHAIN:-}" ] && command -v rustup >/dev/null 2>&1; then
    # Ask from outside the checkout: inside it, rustup may auto-install the
    # pinned toolchain just to answer.
    toolchains="$(cd / && rustup toolchain list 2>/dev/null || true)"
    case "$toolchains" in
        "$rust_pin"* | *$'\n'"$rust_pin"*) ;;
        *)
            fallback="$(printf '%s\n' "$toolchains" | sed -n 's/^\([^ ]*\) .*default.*/\1/p' | sed -n 1p)"
            [ -n "$fallback" ] || die "Rust $rust_pin isn't installed and rustup has no default toolchain"
            warn "Rust $rust_pin (herdr's pin) isn't installed; using $fallback"
            export RUSTUP_TOOLCHAIN="$fallback"
            ;;
    esac
fi
command -v cargo >/dev/null 2>&1 || die "cargo not found"
rust_version="$(rustc --version | awk '{print $2}')"
[ "$rust_version" = "$rust_pin" ] || warn "rustc $rust_version differs from herdr's pin $rust_pin"

zig_version_of() { "$1" version 2>/dev/null || true; }
zig="${ZIG:-$(command -v zig || true)}"
if [ "$(zig_version_of "${zig:-false}")" != "$zig_pin" ] && command -v mise >/dev/null 2>&1; then
    mise_zig="$(mise where "zig@$zig_pin" 2>/dev/null || true)/bin/zig"
    [ -x "$mise_zig" ] && zig="$mise_zig"
fi
[ -n "$zig" ] || die "zig not found; install Zig $zig_pin or set ZIG"
zig_version="$(zig_version_of "$zig")"
[ "$zig_version" = "$zig_pin" ] || warn "zig $zig_version differs from herdr's pin $zig_pin"
export ZIG="$zig"
say "toolchains: rustc $rust_version (pin $rust_pin), zig $zig_version (pin $zig_pin)"

# --- Pick the upstream tag -----------------------------------------------
branch="$(git symbolic-ref --quiet --short HEAD)" || die "HEAD is detached; check out the fork branch"
git diff --quiet && git diff --cached --quiet || die "the working tree has uncommitted changes"

base="$(tr -d '[:space:]' < fork/BASE)"
say "fetching upstream tags from origin"
git fetch --quiet --tags origin
latest="$(git tag -l --sort=-v:refname 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p)"
[ -n "$latest" ] || die "no stable vX.Y.Z tag on origin"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "fork/BASE names $base, which isn't a tag here"

newer="$(printf '%s\n%s\n' "${base#v}" "${latest#v}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
if [ "$latest" = "$base" ] || [ "v$newer" = "$base" ]; then
    say "$branch is on $base, the newest stable upstream tag"
elif git merge-base --is-ancestor "$latest" HEAD; then
    # A rebase that stopped on conflicts and was finished by hand.
    say "$branch already contains $latest; recording it in fork/BASE"
    if [ "$dry_run" = 0 ]; then
        printf '%s\n' "$latest" > fork/BASE
        git commit --quiet -m "chore(fork): track upstream $latest" -- fork/BASE
    fi
else
    say "rebasing $branch from $base onto $latest"
    if [ "$dry_run" = 1 ]; then
        say "dry run: would run git rebase --onto $latest $base $branch"
    else
        before="$(git rev-parse HEAD)"
        if ! git rebase --onto "$latest" "$base" "$branch"; then
            cat >&2 <<EOF

error: the rebase onto $latest stopped on conflicts.
  1. Fix the files git lists above, then run, keeping the fork's identity:
       git add <files>
       git -c user.name="$GIT_COMMITTER_NAME" -c user.email="$GIT_COMMITTER_EMAIL" rebase --continue
     (a conflict in vendor/ usually means patch 0008 needs reapplying; see fork/README.md)
  2. When the rebase finishes, rerun fork/update.sh. It sees $latest in the
     branch and only bumps fork/BASE.
To give up instead: git rebase --abort   (the branch was at $before)
EOF
            exit 1
        fi
        printf '%s\n' "$latest" > fork/BASE
        git commit --quiet -m "chore(fork): track upstream $latest" -- fork/BASE
        say "rebased; the branch was at $before"
    fi
fi

if [ "$dry_run" = 1 ]; then
    say "dry run: would build release, run cargo nextest, and install into $install_dir/herdr"
    exit 0
fi

# --- Build and test ------------------------------------------------------
say "building release"
cargo build --release --locked
cargo nextest --version >/dev/null 2>&1 || die "cargo-nextest is missing: cargo install cargo-nextest --locked"
say "running tests"
cargo nextest run --locked --status-level fail --final-status-level fail \
    --failure-output final --success-output never

bin="${CARGO_TARGET_DIR:-$root/target}/release/herdr"
version_line="$("$bin" --version)"
case "$version_line" in
    "herdr "*+azj.*) say "built $version_line" ;;
    *) die "built binary reports '$version_line', without the +azj fork suffix" ;;
esac
version="${version_line#herdr }"

if [ "$no_install" = 1 ]; then
    say "not installing (--no-install); binary: $bin"
    exit 0
fi

# --- Install -------------------------------------------------------------
target="$install_dir/herdr"
mkdir -p "$install_dir"
[ -L "$target" ] && die "$target is a symlink; point --install-dir at the real directory"
if [ -e "$target" ]; then
    backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$target" "$backup"
    say "backed up the old binary to $backup"
fi
staged="$install_dir/.herdr.new.$$"
cp "$bin" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$target"
say "installed $version to $target"

protocol="$("$target" status client --json | sed -n 's/.*"protocol": *\([0-9]*\).*/\1/p' | sed -n 1p)"
handoff="\"$target\" server live-handoff --import-exe \"$target\" --expected-version $version"
[ -n "$protocol" ] && handoff="$handoff --expected-protocol $protocol"

cat <<EOF

Running herdr servers still run the old binary. To move one onto $version
without losing panes, run this when you're ready (this script doesn't):

  $handoff

For a named session, put --session <name> before "server":

  "$target" --session <name> server live-handoff --import-exe "$target" --expected-version $version${protocol:+ --expected-protocol $protocol}

\`herdr session list\` shows the sessions.
EOF
