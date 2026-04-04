#!/usr/bin/env bash
# Snappy wt-core rebuild (debug by default = incremental, sub-second after first compile).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE=0
EVAL=0

for arg in "$@"; do
  case "$arg" in
    --release|-r) RELEASE=1 ;;
    --eval|-e)   EVAL=1 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--release|-r] [--eval|-e]"
      echo "  default: cargo build (debug)"
      echo "  --eval: print shell lines for: eval \"\$(... --eval)\""
      exit 0
      ;;
  esac
done

cd "$ROOT/rust"

if [[ "$EVAL" -eq 1 ]]; then
  # In eval mode, cargo output must go to stderr only so stdout is clean for eval.
  if [[ "$RELEASE" -eq 1 ]]; then
    cargo build --release >&2
    BIN="$ROOT/rust/target/release"
  else
    cargo build >&2
    BIN="$ROOT/rust/target/debug"
  fi
  printf 'export PATH="%s:$PATH"\n' "$BIN"
  printf 'source %q\n' "$ROOT/git-worktree-switcher.plugin.zsh"
else
  if [[ "$RELEASE" -eq 1 ]]; then
    cargo build --release
    BIN="$ROOT/rust/target/release"
  else
    cargo build
    BIN="$ROOT/rust/target/debug"
  fi
  echo "wt-core → $BIN/wt-core"
  echo "export PATH=\"$BIN:\$PATH\""
  echo "source \"$ROOT/git-worktree-switcher.plugin.zsh\""
fi
