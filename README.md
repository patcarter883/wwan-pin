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

## Tests

```
sh tests/wwan-pin-selftest.sh
```

Six cases -- including the swap -- run against a fixture tree, needing no router.
They pass under `dash`/`ash`. Before trusting a build, re-run them under the
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
