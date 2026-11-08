#!/bin/sh
# test-customize.sh — self-check gate customize.sh. Run: sh test-customize.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'ui_print() { echo "$@"; }\nset_perm_recursive() { :; }\n' > "$TMP/stubs.sh"
mkdir -p "$TMP/mod/ko" "$TMP/bin"
printf 'KO' > "$TMP/mod/ko/fog-4.19_arm64_fgetpriority.ko"
printf '#!/system/bin/sh\n' > "$TMP/mod/service.sh"
fake_uname() { printf '#!/bin/sh\necho "%s"\n' "$1" > "$TMP/bin/uname"; chmod +x "$TMP/bin/uname"; }

fail() { echo "FAIL: $*"; exit 1; }

# case 1: 4.19 → accepted, fgetpriority.ko created
fake_uname "4.19.325-cip126-st10-Kairos"
MODPATH="$TMP/mod" PATH="$TMP/bin:$PATH" sh -c ". '$TMP/stubs.sh'; . '$HERE/customize.sh'" \
  || fail "case1: 4.19.325 ditolak padahal harus diterima"
[ -f "$TMP/mod/ko/fgetpriority.ko" ] || fail "case1: fgetpriority.ko tidak tersalin"
[ ! -f "$TMP/mod/ko/fog-4.19_arm64_fgetpriority.ko" ] || fail "case1: file sumber tidak dibersihkan"

# case 2: GKI-style uname → rejected, exit non-zero, tanpa ko tersalin
fake_uname "5.10.101-android12-8-gf5bf744d1ab0"
rm -f "$TMP/mod/ko/fgetpriority.ko"
if MODPATH="$TMP/mod" PATH="$TMP/bin:$PATH" sh -c ". '$TMP/stubs.sh'; . '$HERE/customize.sh'" 2>/dev/null; then
  fail "case2: uname 5.10 GKI diterima padahal harus ditolak"
fi
[ ! -f "$TMP/mod/ko/fgetpriority.ko" ] || fail "case2: ko tersalin saat ditolak"

# case 3: spoof non-4.19 apa pun (contoh 6.1) → rejected
fake_uname "6.1.99-custom"
if MODPATH="$TMP/mod" PATH="$TMP/bin:$PATH" sh -c ". '$TMP/stubs.sh'; . '$HERE/customize.sh'" 2>/dev/null; then
  fail "case3: uname 6.1 diterima padahal harus ditolak"
fi

echo "PASS: gate customize.sh 3/3"
