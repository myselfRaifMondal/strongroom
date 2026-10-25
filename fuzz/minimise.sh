#!/usr/bin/env bash
# Minimises fuzz/corpus/<target>/ in place with `cargo fuzz cmin`: keeps the
# smallest set of inputs that still reaches the same coverage.
#   fuzz/minimise.sh                      every target
#   fuzz/minimise.sh payload_decode       one or more named targets
# FUZZ_TRIPLE names the build target (CI sets x86_64-unknown-linux-gnu,
# because the prebuilt cargo-fuzz is a musl binary). Unset uses the host.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(container_parse chunk_decrypt payload_decode)
triple=()
[ -z "${FUZZ_TRIPLE:-}" ] || triple=(--target "$FUZZ_TRIPLE")
for t in "${targets[@]}"; do
  if [ ! -d "corpus/$t" ] || [ -z "$(ls -A "corpus/$t")" ]; then
    echo "skip $t: corpus/$t is empty (run fuzz/seed_corpus.sh first)"
    continue
  fi
  before="$(ls "corpus/$t" | wc -l | tr -d ' ')"
  # The nightly comes from fuzz/rust-toolchain.toml.
  cargo fuzz cmin ${triple[@]+"${triple[@]}"} "$t" "corpus/$t" -- -rss_limit_mb=2048
  after="$(ls "corpus/$t" | wc -l | tr -d ' ')"
  echo "minimised $t: $before -> $after inputs"
done
