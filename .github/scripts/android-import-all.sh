#!/usr/bin/env bash
# Imports every <platform>.vtf in DIR on the connected emulator and checks the
# imported titles equal <platform>.titles.txt. Used by crossplatform.yml.
set -euo pipefail
dir="$1"
fail=0
for src in macos windows android; do
  pw="$(cat "$dir/$src.password.txt")"
  sk="$(tr -d '\r\n' < "$dir/$src.secret-key.txt")"
  apps/android/scripts/import-vtf.sh "$dir/$src.vtf" "$pw" "$sk" | tee got.txt
  sed -n 's/^SR_IMPORT_TITLE //p' got.txt | tr -d '\r' | LC_ALL=C sort > got.sorted
  tr -d '\r' < "$dir/$src.titles.txt" | LC_ALL=C sort > want.sorted
  if diff want.sorted got.sorted; then
    echo "ROUNDTRIP $src -> android: OK ($(wc -l < got.sorted | tr -d ' ') items)"
  else
    echo "ROUNDTRIP $src -> android: MISMATCH"
    fail=1
  fi
done
exit $fail
