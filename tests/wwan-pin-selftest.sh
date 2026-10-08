#!/bin/sh
##########################################################################
# Self-test for wwan-pin.
#
# Runs entirely off-device against a synthetic sysfs tree, so the matching and
# rename logic can be proven without a router and without a modem plugged in.
#
# The interesting case is a SWAP: two modems that came up under each other's
# name. That is the reported symptom, and the case a naive one-at-a-time
# implementation deadlocks on ("name in use").
#
# Seams used: SYS_CLASS_NET (the scan), IP (the rename), FUNCTIONS_SH (the UCI
# helpers, stubbed over a fixed config).
##########################################################################

set -u

here=$(cd "$(dirname "$0")" && pwd)

# In the package layout the script is in files/ (the Makefile sits at the repo
# root); in a flat checkout it sits beside this test. WWAN_PIN overrides both, so
# an INSTALLED copy can be tested directly -- e.g. on a router:
#   WWAN_PIN=/usr/sbin/wwan-pin sh /tmp/wwan-pin-selftest.sh
script="${WWAN_PIN:-}"
if [ -z "$script" ]; then
	for c in "$here/../files/wwan-pin" "$here/../wwan-pin" "$here/wwan-pin"; do
		[ -f "$c" ] && { script="$c"; break; }
	done
fi

[ -n "$script" ] && [ -f "$script" ] || {
	echo "cannot find wwan-pin: looked in files/, beside the test, and at \$WWAN_PIN" >&2
	exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NET="$TMP/class/net"
SYS="$TMP/sys"

# The two USB ports, exactly as the router's config names them:
#   config interface 'wwan0'  -> device '.../usb2/2-1'
#   config interface 'wwan1'  -> device '.../usb1/1-2'
PORT_A="$SYS/devices/pci0000:00/0000:00:15.0/usb2/2-1"
PORT_B="$SYS/devices/pci0000:00/0000:00:15.0/usb1/1-2"

mkdir -p "$PORT_A/2-1:1.4" "$PORT_B/1-2:1.4" "$NET"

# --- stubs ----------------------------------------------------------------

# Stands in for /lib/functions.sh: a fixed two-modem config.
cat > "$TMP/functions.sh" <<STUB
config_load() { :; }
config_get() {
    # \$1=destvar \$2=section \$3=option
    case "\$2:\$3" in
        wwan0:device) eval "\$1=$PORT_A" ;;
        wwan1:device) eval "\$1=$PORT_B" ;;
        *) eval "\$1=" ;;
    esac
}
config_foreach() {
    # \$1=callback \$2=type
    "\$1" wwan0
    "\$1" wwan1
}
STUB

# Stands in for \`ip\`: actually moves the fixture dir, and refuses an in-use name
# the way the kernel does. This is what makes the swap test meaningful.
cat > "$TMP/ip" <<STUB
#!/bin/sh
[ "\${1:-}" = link ] && [ "\${2:-}" = set ] && [ "\${3:-}" = dev ] || exit 2
dev="\${4:?}"; [ "\${5:-}" = name ] || exit 2; new="\${6:?}"
[ -e "$NET/\$dev" ] || exit 1
[ -e "$NET/\$new" ] && exit 1
mv "$NET/\$dev" "$NET/\$new"
echo "    RENAME \$dev -> \$new"
STUB
chmod +x "$TMP/ip"

# --- helpers --------------------------------------------------------------

# the netdev whose sysfs device resolves to (or under) a given port
dev_on() {
    local d r
    for d in "$NET"/*; do
        [ -e "$d/device" ] || continue
        r=$(readlink -f "$d/device" 2>/dev/null) || continue
        case "$r" in "$1"|"$1"/*) basename "$d"; return 0 ;; esac
    done
    echo "(none)"
}

fail=0
check() { # check <what> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "    ok    $1"
    else
        echo "    FAIL  $1 -- got '$2', want '$3'"
        fail=1
    fi
}

# the reported symptom: each modem carrying the other's name
setup_swap() {
    rm -rf "$NET"/*
    mkdir -p "$NET/wwan1" "$NET/wwan0"
    ln -s "$PORT_A/2-1:1.4" "$NET/wwan1/device"   # modem on port A came up wwan1
    ln -s "$PORT_B/1-2:1.4" "$NET/wwan0/device"   # modem on port B came up wwan0
}

# ModemManager's runtime dir and init script are redirected into the fixture
# as well: wwan-pin now reconciles MM's on-disk cache, and without an override a
# test run on a host that really has /var/run/modemmanager would edit the LIVE
# cache. The init stub records the verbs it was called with.
MMTMP="$TMP/mmrundir"
mkdir -p "$MMTMP"
MM_CALLS="$TMP/mm-calls"
: > "$MM_CALLS"
cat > "$TMP/mm-stub" <<'STUB'
#!/bin/sh
echo "$1" >> "$MM_CALLS"
[ "$1" = running ] && exit "${MM_RUNNING_STATE:-1}"
exit 0
STUB
chmod +x "$TMP/mm-stub"

run() { SYS_CLASS_NET="$NET" SYS_CLASS_USBMISC="$TMP/class/usbmisc" \
        IP="$TMP/ip" FUNCTIONS_SH="$TMP/functions.sh" \
        MM_RUNDIR="$MMTMP" MM_INIT="$TMP/mm-stub" MM_CALLS="$MM_CALLS" \
        sh "$script" "$@" 2>&1; }

# --- 1. the symptom is real ----------------------------------------------

echo "1. before the fix, the swap is live"
setup_swap
check "modem on port A is mis-named wwan1" "$(dev_on "$PORT_A")" "wwan1"
check "modem on port B is mis-named wwan0" "$(dev_on "$PORT_B")" "wwan0"

# --- 2. dry run reports and changes nothing ------------------------------

echo "2. --dry-run reports the swap but changes nothing"
out=$(run --dry-run)
printf '%s\n' "$out" | sed 's/^/  /'
check "dry-run renames nothing" "$(printf '%s\n' "$out" | grep -c RENAME || true)" "0"
check "dry-run still names A as wwan1" "$(dev_on "$PORT_A")" "wwan1"
check "dry-run announced the change" "$(printf '%s\n' "$out" | grep -c 'would rename' || true)" "2"

# --- 3. the swap resolves ------------------------------------------------

echo "3. wwan-pin resolves the swap"
out=$(run)
printf '%s\n' "$out" | sed 's/^/  /'
check "port A is now wwan0" "$(dev_on "$PORT_A")" "wwan0"
check "port B is now wwan1" "$(dev_on "$PORT_B")" "wwan1"

# --- 4. idempotent -------------------------------------------------------

echo "4. a second run is a no-op"
out=$(run)
check "no renames when already correct" "$(printf '%s\n' "$out" | grep -c RENAME || true)" "0"

# --- 5. absent modem is a non-event --------------------------------------

echo "5. an absent modem is a non-event"
# after test 4: port A is wwan0, port B is wwan1. Unplug B's modem.
rm -rf "$NET/wwan1"
out=$(run); rc=$?
check "exit 0 with a modem absent" "$rc" "0"
check "no renames attempted" "$(printf '%s\n' "$out" | grep -c RENAME || true)" "0"
check "the present modem is left alone" "$(dev_on "$PORT_A")" "wwan0"

# --- 6. nothing configured ------------------------------------------------

echo "6. a config with no modem interfaces does nothing"
cat > "$TMP/functions-empty.sh" <<'STUB'
config_load() { :; }
config_get() { eval "$1="; }
config_foreach() { "$1" lan; }
STUB
out=$(SYS_CLASS_NET="$NET" IP="$TMP/ip" FUNCTIONS_SH="$TMP/functions-empty.sh" \
      MM_RUNDIR="$MMTMP" MM_INIT="$TMP/mm-stub" MM_CALLS="$MM_CALLS" \
      sh "$script" 2>&1)
check "exit 0 with nothing configured" "$?" "0"
check "no output with nothing configured" "$out" ""

# --- 7. the real functions.sh reads an unset var at source time -----------
#
# REGRESSION: /lib/functions.sh reads $IPKG_INSTROOT unguarded in top-level code
#     [ -z "$IPKG_INSTROOT" ] && ... || true
# AND inside functions this script calls (config_load among them):
#     [ -n "$IPKG_INSTROOT" ] && return 0
# If the script has `set -u` in force, either aborts it with exit 2 and the hook
# silently renames nothing. A stub that never touches an unset variable cannot
# catch that, so this stub deliberately does both, as the real file does.

echo "7. functions.sh reading an unset var (both at source time and in a call)"
cat > "$TMP/functions-strict.sh" <<'STUB'
[ -z "$IPKG_INSTROOT" ] && [ -f /lib/config/uci.sh ] && . /lib/config/uci.sh || true
config_load() { [ -n "$IPKG_INSTROOT" ] && return 0; :; }
config_get() { [ -n "$IPKG_INSTROOT" ] && return 0; eval "$1="; }
config_foreach() { "$1" lan; }
STUB
out=$(SYS_CLASS_NET="$NET" IP="$TMP/ip" FUNCTIONS_SH="$TMP/functions-strict.sh" \
      MM_RUNDIR="$MMTMP" MM_INIT="$TMP/mm-stub" MM_CALLS="$MM_CALLS" \
      sh "$script" --dry-run 2>&1); rc=$?
check "does not abort on it" "$rc" "0"
check "no IPKG_INSTROOT error" "$(printf '%s\n' "$out" | grep -c IPKG_INSTROOT || true)" "0"

# and prove the guard is load-bearing: inject `set -u` and it must fail
sed '2i set -u' "$script" > "$TMP/strict-script"
out=$(SYS_CLASS_NET="$NET" IP="$TMP/ip" FUNCTIONS_SH="$TMP/functions-strict.sh" \
      MM_RUNDIR="$MMTMP" MM_INIT="$TMP/mm-stub" MM_CALLS="$MM_CALLS" \
      sh "$TMP/strict-script" --dry-run 2>&1); rc=$?
check "with set -u added it does fail (so this test has teeth)" \
      "$(printf '%s\n' "$out" | grep -c IPKG_INSTROOT || true)" "1"

# --- 8. ModemManager's cache (the failure this reconciliation exists for) --
#
# Renaming a netdev invalidates MM's on-disk cache. It is keyed by netdev NAME
# and REPLAYED on every MM start, so a rename leaves an entry pointing at a path
# that no longer exists and MM never expires it. Live, that presented as a modem
# perfectly healthy on USB (driver bound, /dev/cdc-wdm0 present) reading
# "No modems were found" -- and with `unlock retries: sim-pin2`, which reads as
# a SIM-PIN fault and is not one. Restarting MM does not clear it: the stale
# cache is the cause and the restart is what replays it.

echo "8. ModemManager's cache is reconciled against the names on disk"
# after tests 4-5: port A is wwan0 and present; port B / wwan1 is absent.
mkdir -p "$PORT_A/2-1:1.4/usbmisc/cdc-wdm7" "$TMP/class/usbmisc/cdc-wdm7"
cat > "$MMTMP/events.cache" <<EOF
add,wwan0,net,$NET/wwan1
add,ttyS1,tty,/dev/null
EOF
cat > "$MMTMP/cdcwdm.cache" <<EOF
wwan9 cdc-wdm9
wwan0 cdc-wdm7
EOF
out=$(run)
printf '%s\n' "$out" | sed 's/^/  /'
check "the dead netdev event was dropped" \
      "$(grep -c 'net/wwan1' "$MMTMP/events.cache" || true)" "0"
check "the unrelated tty event was kept" \
      "$(grep -c 'ttyS1' "$MMTMP/events.cache" || true)" "1"
check "the dead cdcwdm entry was dropped" \
      "$(grep -c 'wwan9' "$MMTMP/cdcwdm.cache" || true)" "0"
check "the live modem's mapping is present" \
      "$(grep -c '^wwan0 cdc-wdm7$' "$MMTMP/cdcwdm.cache" || true)" "1"

# Pruning alone is NOT enough. When MM's cache has been emptied -- or the modem
# changed USB composition after the rename, so the pin ran while no MBIM control
# port existed yet -- there is nothing left to replay and MM reports no modem
# however correct the mapping looks. The events must be ADDED for every modem
# that is present, with the syspaths read from sysfs. (Live, this exact gap left
# a modem invisible after it was switched back to the MBIM composition.)
check "a net event was added for the live modem" \
      "$(grep -c '^add,wwan0,net,' "$MMTMP/events.cache" || true)" "1"
check "a usbmisc event was added for its control port" \
      "$(grep -c '^add,cdc-wdm7,usbmisc,' "$MMTMP/events.cache" || true)" "1"
check "no event was invented for the absent modem" \
      "$(grep -c '^add,wwan1,net,' "$MMTMP/events.cache" || true)" "0"

# With MM not running there is nothing to nudge -- at boot this is the case, and
# MM replays the corrected cache itself.
: > "$MM_CALLS"; export MM_RUNNING_STATE=1
run >/dev/null 2>&1
check "MM not running -> not restarted" \
      "$(grep -c restart "$MM_CALLS" || true)" "0"

# With MM running it is holding the stale state in memory and only reads the
# cache at start, so it must be made to read it again.
: > "$MM_CALLS"; export MM_RUNNING_STATE=0
run >/dev/null 2>&1
check "MM running -> restarted so it re-reads" \
      "$(grep -c restart "$MM_CALLS" || true)" "1"
unset MM_RUNNING_STATE

echo
if [ "$fail" = 0 ]; then
    echo "ALL PASSED"
else
    echo "FAILURES PRESENT"
fi
exit $fail
