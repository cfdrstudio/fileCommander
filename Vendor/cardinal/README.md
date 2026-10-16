# Vendored: Cardinal search engine

fileCommander's search (⇧⌘F) runs on [Cardinal](https://github.com/cardisoft/cardinal)'s
file name index. These are Cardinal's Rust crates, copied unchanged from upstream commit
`4c50734f9a09d88110f96652b43634b412f79449` (2026-06-26), under its MIT license (`LICENSE`).

Copied: `search-cache`, `fswalk`, `namepool`, `cardinal-sdk`, `cardinal-syntax`,
`query-segmentation`, `search-cancel`, `slab-mmap`, `file-tags`. Not copied: the Tauri app,
`lsf`, `fs-icon`, `was`, docs.

Local change (keep it when updating):
- `search-cancel/src/lib.rs`: `CancellationToken::with_counter`, so each fileCommander search
  can be cancelled on its own (upstream cancels through one process-wide counter, which would
  let one search window cancel another).

`CardinalBridge/` wraps `search-cache` in a small C API (`Sources/CCardinal/cardinal_bridge.h`),
built by `./build-cardinal.sh` into a static library that Swift links.

To update: copy the same crates from a newer upstream checkout over these folders, reapply the
change above, copy upstream's `rust-toolchain.toml` to `CardinalBridge/` and here, then run
`./build-cardinal.sh` and `cd CardinalBridge && cargo test --release`.
