#!/bin/zsh
# Test keychain items of the AnJ Cloud service (spec #31 M3). Runs ON
# mac-test without sudo; every action runs in the GUI session through
# gui_run.sh, because only there is the login keychain reachable.
#
#   keychain_items.sh add <account> <value>   item created by /usr/bin/security
#                                             (an app's view: "another program")
#   keychain_items.sh value <account>         its value, read by its creator
#   keychain_items.sh accounts                accounts of the service (no secrets)
#   keychain_items.sh clean <match>           delete every item of the service
#                                             whose account contains <match>, and
#                                             any dedicated test keychain whose
#                                             path contains it (a run that died
#                                             before deleting its own)
#
# Service: cloud.anj.anj-cloud. Accounts touched must contain "anj-test-",
# so the app's own items ("anj-cloud:<profile>:device-key") are never
# deleted unless their profile id is a test id (integration_test/
# macos_adapters_test.dart uses "anj-test-m3-...").
set -u
here=${0:A:h}
service=cloud.anj.anj-cloud
out=$(mktemp -d "${TMPDIR:-/tmp}/anj-keychain.XXXXXX") || exit 70
trap 'rm -rf -- "$out"' EXIT
test_account() {
  [[ $1 == *anj-test-* && $1 != *[[:space:]\"\\]* ]] || {
    echo "keychain_items.sh: account must contain anj-test- and no spaces or quotes: $1" >&2; exit 64; }
}
accounts() {
  "$here/gui_run.sh" "$out" 30 /bin/sh -c \
    "security dump-keychain login.keychain-db 2>/dev/null" > "$out/dump" || return 1
  awk -v svc="$service" '
    /^keychain: / { if (s == svc && a != "") print a; s = ""; a = "" }
    /"svce"<blob>="/ { v = $0; sub(/.*"svce"<blob>="/, "", v); sub(/"$/, "", v); s = v }
    /"acct"<blob>="/ { v = $0; sub(/.*"acct"<blob>="/, "", v); sub(/"$/, "", v); a = v }
    END { if (s == svc && a != "") print a }' "$out/dump" | sort -u
}
case ${1:-} in
  add)
    test_account "${2:?account}"
    "$here/gui_run.sh" "$out" 30 security add-generic-password -s "$service" -a "$2" -w "${3:?value}" -l "anj-test" ;;
  value)
    test_account "${2:?account}"
    "$here/gui_run.sh" "$out" 30 security find-generic-password -s "$service" -a "$2" -w ;;
  accounts)
    accounts ;;
  clean)
    match=${2:?match}
    [[ $match == *anj-test-* ]] || { echo "keychain_items.sh: <match> must contain anj-test-" >&2; exit 64; }
    failed=0
    for account in ${(f)"$(accounts)"}; do
      [[ $account == *$match* ]] || continue
      if "$here/gui_run.sh" "$out" 30 security delete-generic-password -s "$service" -a "$account" > /dev/null; then
        echo "deleted keychain item: $account"
      else
        echo "keychain_items.sh: could not delete $account" >&2; failed=1
      fi
    done
    "$here/gui_run.sh" "$out" 30 security list-keychains -d user > "$out/list" 2>/dev/null
    for keychain in ${(f)"$(sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$out/list" | grep -F -- "$match")"}; do
      if "$here/gui_run.sh" "$out" 30 security delete-keychain "$keychain" > /dev/null; then
        echo "deleted test keychain: $keychain"
      else
        echo "keychain_items.sh: could not delete test keychain $keychain" >&2; failed=1
      fi
    done
    left=$(accounts | grep -F -- "$match")
    [[ -z $left ]] || { echo "keychain_items.sh: still present: $left" >&2; failed=1; }
    exit $failed ;;
  *)
    echo "usage: keychain_items.sh add <account> <value> | value <account> | accounts | clean <match>" >&2
    exit 64 ;;
esac
