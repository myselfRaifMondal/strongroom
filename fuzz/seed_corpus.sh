#!/usr/bin/env bash
# Builds fuzz/corpus/<target>/ seed directories from vectors/ (not committed).
#   container_parse: every positive and negative .vtf file
#   payload_decode:  every positive .cbor payload + the decrypted plaintexts of
#                    the payload-level negative vectors (fuzz/seeds/, produced
#                    by `uv run python -m vtf_ref.dump_plaintexts`)
#   chunk_decrypt:   one unmodified-file selector per base file plus a few edits
#   csv_import, pairing_parse, totp_uri, vault_header: fuzz/seeds/<target>/
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vectors="$here/../vectors"
c="$here/corpus"
mkdir -p "$c/container_parse" "$c/payload_decode" "$c/chunk_decrypt"
cp "$vectors"/positive/*.vtf "$vectors"/negative/*.vtf "$c/container_parse/"
cp "$vectors"/positive/*.cbor "$here"/seeds/payload_decode/*.bin "$c/payload_decode/"
printf '\x00' >"$c/chunk_decrypt/base1"
printf '\x01' >"$c/chunk_decrypt/base2"
printf '\x02' >"$c/chunk_decrypt/base3"
printf '\x01\x03\x00\x00\x00\x01' >"$c/chunk_decrypt/swap"
printf '\x02\x05\x02\x00\x00\x00' >"$c/chunk_decrypt/delete-last"
printf '\x00\x00\x00\x00\x10\x01' >"$c/chunk_decrypt/flip-header"
printf '\x01\x02\x00\xff\x00\x00' >"$c/chunk_decrypt/truncate"
for t in csv_import pairing_parse totp_uri vault_header; do
  mkdir -p "$c/$t"
  cp "$here/seeds/$t"/* "$c/$t/"
done
for t in container_parse payload_decode chunk_decrypt csv_import pairing_parse totp_uri vault_header; do
  echo "seeded $t: $(ls "$c/$t" | wc -l | tr -d ' ') inputs"
done
