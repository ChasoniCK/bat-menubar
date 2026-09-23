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

Measured, not estimated:

- **Menu closed: nothing at all.** No timer is scheduled, so the process records 0 ns of CPU,
  0 instructions and 0 wakeups over a 60 s window. This does not rely on App Nap.
- **Menu open: ~0.08 s of CPU per 40 s**, against 0.29 s for the pre-optimization build — and that
  0.29 s included 0.16 s burned in `smd` and `backgroundtaskmanagementd`, which the old code woke
  every second by asking `SMAppService` whether the login item was enabled. That check now happens
  when the menu opens, not on every tick.

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
