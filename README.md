# wwan-pin

Give a USB modem the same network interface name every time it is plugged in.

OpenWrt names `wwan*` / `wwx*` netdevs in **probe order**. The same modem comes
back as `wwan1` after a replug, and anything that addresses a radio *by name* --
a librist `miface=`, a wan-failover member, a firewall rule -- silently binds a
different one. There is no error, just the wrong modem carrying your traffic.

`wwan-pin` makes the UCI `interface` section the single definition of a modem's
identity, and renames the kernel netdev to match it.

## How it works

The UCI interface already declares which USB port the modem sits on:

```
config interface 'wwan0'
	option device '/sys/devices/pci0000:00/0000:00:15.0/usb2/2-1'
```

`wwan-pin` walks `/sys/class/net`, resolves each candidate netdev to its USB port
path, and renames it to the name of the section that declares that port.

The section name **is** the authority. Nothing else has to be kept in sync, and
there is no second place to update when a modem moves.

### The swap case

Renaming `wwan1` -> `wwan0` while a `wwan0` already exists collides. Two modems
exchanging names is resolved in two phases through temporary names, so no rename
ever lands on an occupied name:

```
wwan1  -> wwtmp0    (vacate)
wwan0  -> wwtmp1    (vacate)
wwtmp0 -> wwan0     (assign)
wwtmp1 -> wwan1     (assign)
```

## Install

```
make
apk add --allow-untrusted --no-network wwan-pin-*.apk   # OpenWrt 25.12+ (apk-tools v3)
opkg install wwan-pin_*.ipk                            # older releases (opkg)
```

Ships two files:

* `/usr/sbin/wwan-pin` -- the renamer
* `/etc/hotplug.d/net/30-wwan-pin` -- runs it when a netdev appears

## Use

```
wwan-pin --dry-run   # report what would change, change nothing
wwan-pin             # apply
wwan-pin --help
```

An absent modem is a non-event: a section whose device is not present is skipped,
so it is safe to run when half the modems are unplugged. That is the ordinary
state on a bench.

## ModemManager, and why renaming has a second half

Renaming a netdev invalidates state ModemManager keeps **on disk** in
`/var/run/modemmanager/`, keyed by netdev **name**: `events.cache`
(`action,devname,subsystem,syspath`, replayed on every start) and `cdcwdm.cache`
(`<netdev> <cdc-wdm>`, the netdev to control-port map).

ModemManager on OpenWrt has no udev -- it learns modems from hotplug events. Its
own handler is numbered 25 and this one 30, so on a fresh add MM records the
**pre-rename** name first, and the rename then leaves a cache entry pointing at a
path that no longer exists. MM replays that entry on every start and never expires
it, so the modem disappears from `mmcli -L` while being perfectly healthy on USB
(driver bound, `/dev/cdc-wdm0` present). **Restarting ModemManager does not clear
it: the stale cache is the cause and the restart is what replays it.** The symptom
is worse than a plain absence -- a half-initialised modem reports
`unlock retries: sim-pin2`, which reads as a SIM-PIN fault and is not one.
(`mmcli -S` / manual rescan is unsupported on OpenWrt, so feeding MM a correct
event is the only route.)

After every rename this script therefore reconciles both caches against what is
actually on disk: dead entries are dropped, an entry is **added** for every modem
present (syspaths read from sysfs, never assumed), entries belonging to other
devices are kept, and ModemManager is restarted **only if it is already running**
-- at boot it has not started yet and replays the corrected cache itself.

Pruning alone is not enough, and it is easy to get wrong: an empty cache is
replayed as *nothing*, so a modem that was re-enumerated after the pin ran stays
invisible however correct the mapping looks. Adding the events is what makes it
work.

There is a second trigger for the same reason. A modem can change USB
**composition** after its netdev appears -- up as ECM (`usb0`, no control port),
switching to MBIM (`wwanN` + `cdc-wdmN`) once `20-vos5g-mbim` forces its USB
config. By then the rename has run and there was no MBIM port to announce.
`/etc/hotplug.d/usbmisc/30-wwan-pin` fires on the control port and closes that
window. **A netdev-only hook is a real gap, not a theoretical one -- it was hit
live.**

## Tests

```
sh tests/wwan-pin-selftest.sh
```

Eight cases -- including the swap and the ModemManager cache -- run against a
fixture tree, needing no router. They pass under `dash`/`ash`. The MM cases
redirect `MM_RUNDIR` and `MM_INIT` into the fixture, so running them never touches
a live `/var/run/modemmanager`. Before trusting a build, re-run them under the
target's own shell and confirm the copy being tested is the installed file:

```
scp -O wwan-pin root@<router>:/tmp/ && ssh root@<router> 'sh /tmp/wwan-pin-selftest.sh'
```

## Pitfall worth knowing

Do **not** put `set -u` in a script that sources `/lib/functions.sh`. That file
reads `$IPKG_INSTROOT` unguarded, both at source time (around line 539) and inside
functions -- `config_load` does `[ -n "$IPKG_INSTROOT" ] && return 0`. With `set -u`
the script aborts with `IPKG_INSTROOT: parameter not set` before doing anything.
Every variable here is written `${x:-...}` instead.
