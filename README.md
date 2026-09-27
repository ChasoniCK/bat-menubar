# Bat

A macOS menu bar app that shows where your Mac's power is going, in watts, live.

The System row is green while the adapter covers the load and turns red once the battery chips in;
an extra red row then shows how many watts are coming out of the battery on top of the adapter.

## Where the numbers come from

Two SMC keys, read once per second while the menu is open:

- `PDTR` — watts coming in from the adapter, `flt `
- `B0AP` — battery flow in milliwatts, `si32`, **signed**: negative means the battery is being drained

System load is then `adapter + drawn from battery - charged into battery`.

IORegistry (`AppleSmartBattery`) is deliberately not used for any of this. Its battery data only
refreshes once every 60 seconds, so a discharge that starts at t=26s is not visible there until
t=60s; `B0AP` shows it immediately. Reading it is also expensive — `IORegistryEntryCreateCFProperties`
makes the kernel serialize the whole 11 KB property tree to hand over four scalars.

## Cost

**Menu closed: nothing at all.** No timer is scheduled, so once launch has settled the process
records 0 ns of CPU, 0 instructions and 0 wakeups over a 60 s window. This does not rely on App Nap.

**Menu open:** two SMC reads per second, plus redrawing whichever rows changed. `./bench.sh`, v1.7
(`3cc3b84`) against v1.8:

| | v1.7 | v1.8 | |
|---|---:|---:|---:|
| Menu open: CPU per 40 s | 185.5 ms | 132.0 ms | −29% |
| Menu open: instructions per 40 s | 217.8 M | 96.9 M | −56% |
| Menu open: wakeups per 40 s | 185 | 46 | −75% |
| Menu open: wakeups from package idle per 40 s | 7 | 0 | −100% |
| Menu open: memory footprint | 18.2 MB | 17.8 MB | −2% |
| Menu shut: CPU per 60 s | 2.0 ms | 1.3 ms | |
| Menu shut: wakeups per 60 s | 8 | 6 | |
| Menu shut: memory footprint | 12.6 MB | 12.6 MB | |
| Launch: CPU in the first 3 s | 70.7 ms | 73.1 ms | |

The menu-shut window opens 3 s after launch, so it still catches the tail of AppKit's start-up.
Those rows and the launch row differ by under a millisecond, too little to credit to either build
without averaging several runs.

What v1.8 changed:

- **Launch touches neither the SMC nor `SMAppService`.** Both happen on the first menu open, so a
  login item that is never clicked never wakes `smd` and `backgroundtaskmanagementd` at login.
  (Since v1.6 that login-item check runs once per menu open, not on every tick.)
- **An unchanged row costs one string compare.** Each row keeps its last text and color; before,
  every row built a fresh attributed string each tick only to find it matched the old one. Watts
  are formatted with integer math instead of `String(format:)`, and the warning row's visibility is
  only written when it flips.
- **The 1 Hz timer has 100 ms of tolerance**, so the kernel can fold its wakeup into one that is
  due anyway — the change aimed at package-idle wakeups.

To measure, or to compare against any other commit:

```bash
./bench.sh [git-ref]   # default ref: 3cc3b84 (v1.7's code); ~4 min, hands off the mouse
```

It builds both versions, runs each with the menu shut and popped open (`--preview`), and prints a
table of CPU time, instructions, wakeups and memory footprint from `proc_pid_rusage`. `IDLE` and
`OPEN` set the window lengths, `RUNS` the number of runs averaged, and `SETTLE` how long after
launch sampling starts (`SETTLE=60` for the steady state with the menu shut).

## Install

Download `Bat.zip` from [Releases](../../releases), unzip, drop `Bat.app` into `~/Applications`.

The build is ad-hoc signed, so Gatekeeper will refuse a downloaded copy until you clear the
quarantine flag:

```bash
xattr -dr com.apple.quarantine ~/Applications/Bat.app
```

## Build from source

```bash
./build.sh
```

Needs Xcode command line tools. Installs to `~/Applications/Bat.app`. Requires macOS 26.

The bundle version is taken from git: `CFBundleShortVersionString` is the latest tag without the
`v` (`v1.7` → `1.7`), `CFBundleVersion` is the commit count. To cut a release, tag first, then build:

```bash
git tag v1.8
./build.sh
```

## Flags

```bash
Bat --print          # one reading to stdout, then exit
Bat --login on|off   # toggle the login item from the shell
Bat --preview        # pop the menu on screen (useful when a bar manager hides the icon)
```

## Notes

Apple Silicon only — the SMC keys it reads do not exist on Intel Macs.
