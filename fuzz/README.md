# Fuzzing

cargo-fuzz (libFuzzer) targets for the parsers in `vtf-core` and
`vault-core` that read untrusted input. This crate is its own
workspace and is never part of the product build.

| Target | What it fuzzes |
| --- | --- |
| `container_parse` | Header and slot-table parser and the device unlock path |
| `chunk_decrypt` | Chunk decryption under structured edits of a valid file |
| `payload_decode` | Strict CBOR / payload decoder |
| `csv_import` | CSV parser and the column mapping for every export source |
| `pairing_parse` | `SR1PAIR:` pairing payload from another device |
| `totp_uri` | TOTP secret and `otpauth://` URI parser |
| `vault_header` | Plaintext vault header (`.hdr`) and the device key wrap blob |

Each file in `fuzz_targets/` lists the invariants it checks.

## In CI

- `rust.yml` runs every target for 60 seconds on each pull request.
- `fuzz-long.yml` runs every target for 1 hour each week. It keeps the
  corpus in the Actions cache, minimises it after each run and uploads
  crash inputs as a run artifact. Start it by hand with a different run
  time (in seconds):

  ```sh
  gh workflow run fuzz-long.yml -f seconds=7200
  ```

## Running locally

You need nightly Rust and cargo-fuzz:

```sh
rustup toolchain install nightly
cargo install cargo-fuzz
```

Seed the corpus from `vectors/` and `fuzz/seeds/` (creates `fuzz/corpus/`, which is not
committed), then run one target. This example runs for one hour:

```sh
fuzz/seed_corpus.sh
cd fuzz
cargo +nightly fuzz run payload_decode corpus/payload_decode -- \
  -max_total_time=3600 -rss_limit_mb=2048 -print_final_stats=1
```

Useful options:

- `-jobs=N -workers=N` runs N fuzzing processes at once. Each one uses
  memory, so keep N small on a laptop.
- `-max_total_time=0` (or leaving it out) runs until you stop it.
- `cargo +nightly fuzz coverage <target> corpus/<target>` builds a coverage
  report for the corpus.

Long runs grow the corpus with inputs that add little. Minimise it now and
then; this keeps the smallest set of inputs with the same coverage:

```sh
fuzz/minimise.sh                  # every target
fuzz/minimise.sh chunk_decrypt    # one target
```

On Linux with the prebuilt cargo-fuzz binary, set
`FUZZ_TRIPLE=x86_64-unknown-linux-gnu` first (and pass the same triple as
`--target` to `cargo fuzz run`).

## When a target crashes

libFuzzer stops and writes the input to `fuzz/artifacts/<target>/`.
Reproduce it with:

```sh
cargo +nightly fuzz run <target> fuzz/artifacts/<target>/crash-<hash>
```

Do not open a public issue for a crash that might be exploitable (for
example a panic in a parser or anything in the decrypt path). Report it
privately as [docs/SECURITY.md](../docs/SECURITY.md) explains. Other
crashes can go in a normal issue with the reproducer attached.

The `fuzz-long` workflow uploads crash inputs as a run artifact (kept 7
days). This repo is public: anyone signed in to GitHub can download run
artifacts, and anyone can read the logs, where libFuzzer also prints small
crashing inputs as Base64. A maintainer should download the input, report
it privately, then delete the run's artifact.
