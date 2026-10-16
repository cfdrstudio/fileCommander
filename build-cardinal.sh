#!/bin/zsh
# Builds CardinalBridge (Cardinal's search engine, Rust) into CardinalBridge/target/release,
# where Package.swift links it from. Run before `swift build` / `swift test`;
# build-app.sh runs it for you.
set -e
cd "$(dirname "$0")/CardinalBridge"
# Homebrew's rustup is keg-only, so it may not be on PATH.
for dir in "$HOME/.cargo/bin" /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin; do
  [[ -x "$dir/cargo" ]] && path=("$dir" $path)
done
if ! command -v cargo >/dev/null; then
  echo "cargo not found. Install Rust with: brew install rustup (the toolchain in rust-toolchain.toml installs itself)" >&2
  exit 1
fi
# Match Package.swift's platform so the linker doesn't warn about newer objects.
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --locked
