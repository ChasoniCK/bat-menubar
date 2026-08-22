# Bat

A macOS menu bar app that shows where your Mac's power is going, in watts, live.

```
System:   11.27W      ← green while the adapter covers it, red once the battery chips in
Adapter: + 11.27W
Battery:    0.00W
State:   Not Charging
──────────────────
✓ Launch at Login
──────────────────
  Quit            ⌘Q
```

When the load exceeds what the charger can deliver, an extra red row appears showing how many
watts are coming out of the battery on top of the adapter.

## Where the numbers come from

Readings are pulled straight from the SMC once per second — `PDTR` for adapter input and `PPBR`
for battery flow. IORegistry (`AppleSmartBattery`) supplies only the charge/discharge direction:
its wattage lags by up to a minute, while direction flips far more slowly than the numbers do.

Polling only runs while the menu is open, so the app costs nothing when you are not looking at it.

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

## Flags

```bash
Bat --print          # one reading to stdout, then exit
Bat --login on|off   # toggle the login item from the shell
Bat --preview        # pop the menu on screen (useful when a bar manager hides the icon)
```

## Notes

Apple Silicon only — the SMC keys it reads do not exist on Intel Macs.
