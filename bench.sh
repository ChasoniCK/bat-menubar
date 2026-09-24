#!/bin/bash
# Measures what Bat itself costs, before vs after a change. Run on the Mac: ./bench.sh [git-ref]
#
# Builds <git-ref> (default: the last commit before the launch/tick trimming) and the working tree
# into a scratch dir, runs each build with the menu shut and with it popped open (--preview), and
# prints a Markdown table. Counters come from proc_pid_rusage, the ones Activity Monitor reads.
# Hands off the mouse and keyboard while it runs: a click or a key closes the popped-up menu.
#
#   IDLE=60 OPEN=40 RUNS=1 ./bench.sh 3cc3b84
set -euo pipefail
cd "$(dirname "$0")"

REF=${1:-3cc3b84}
IDLE=${IDLE:-60}  # seconds sampled with the menu shut
OPEN=${OPEN:-40}  # seconds sampled with the menu open
RUNS=${RUNS:-1}   # each figure is the mean over this many runs
SETTLE=3          # seconds after launch before sampling starts

TMP=$(mktemp -d)
trap 'pkill -f "$TMP/" 2>/dev/null || true; rm -rf "$TMP"' EXIT

cat > "$TMP/usage.c" <<'C'
// usage <pid> <seconds>: counters accumulated over <seconds>, or since launch when it is 0.
// Prints: cpu_ns instructions wakeups idle_wakeups footprint_bytes
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

static void snap(pid_t pid, struct rusage_info_v4 *ri) {
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)ri) != 0) {
        perror("proc_pid_rusage");
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    pid_t pid = (pid_t)atoi(argv[1]);
    unsigned secs = (unsigned)atoi(argv[2]);
    struct rusage_info_v4 a = {0}, b;
    if (secs) { snap(pid, &a); sleep(secs); }
    snap(pid, &b);
    // CPU times come back in mach ticks, which are not nanoseconds on Apple Silicon.
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    unsigned long long ticks = (b.ri_user_time + b.ri_system_time) - (a.ri_user_time + a.ri_system_time);
    printf("%llu %llu %llu %llu %llu\n",
           ticks * tb.numer / tb.denom,
           (unsigned long long)(b.ri_instructions - a.ri_instructions),
           (unsigned long long)(b.ri_interrupt_wkups - a.ri_interrupt_wkups),
           (unsigned long long)(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups),
           (unsigned long long)b.ri_phys_footprint);
    return 0;
}
C
clang -O2 -o "$TMP/usage" "$TMP/usage.c"

# build <name> <swift source>: same compiler flags as build.sh, under its own bundle id so the
# real app's defaults and login item are left alone.
build() {
    local app="$TMP/$1/Bat.app"
    mkdir -p "$app/Contents/MacOS"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Bat</string>
	<key>CFBundleIdentifier</key><string>com.chasonick.bat.bench</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    swiftc -O -target arm64-apple-macos26.0 -parse-as-library "$2" -o "$app/Contents/MacOS/Bat"
    codesign --force --sign - "$app" 2>/dev/null
}

git show "$REF:Bat.swift" > "$TMP/before.swift"
echo "building $REF and the working tree..." >&2
build before "$TMP/before.swift"
build after Bat.swift

# sample <build> <seconds> [flag]: appends "launch_cpu_ns cpu_ns instr wakeups idle_wakeups
# footprint" to $TMP/<build>.<idle|open>.
sample() {
    local pid launch window phase=idle
    if [ $# -ge 3 ]; then phase=open; fi
    "$TMP/$1/Bat.app/Contents/MacOS/Bat" ${3:+"$3"} >/dev/null 2>&1 &
    pid=$!
    sleep "$SETTLE"
    launch=$("$TMP/usage" "$pid" 0)
    window=$("$TMP/usage" "$pid" "$2")
    echo "${launch%% *} $window" >> "$TMP/$1.$phase"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
}

# Builds alternate inside each run so drift (thermals, background work) hits both alike.
for ((i = 1; i <= RUNS; i++)); do
    for b in before after; do
        echo "run $i/$RUNS: $b, menu shut (${IDLE}s)..." >&2
        sample "$b" "$IDLE"
        echo "run $i/$RUNS: $b, menu open (${OPEN}s)..." >&2
        sample "$b" "$OPEN" --preview
    done
done

# row <label> <idle|open> <column> <divisor> <unit>
row() {
    awk -v l="$1" -v d="$4" -v u="$5" -v c="$3" '
        FILENAME == ARGV[1] { b += $c; nb++; next }
                            { a += $c; na++ }
        END {
            b /= nb; a /= na
            ch = b > 0 ? sprintf("%+.0f%%", (a - b) * 100 / b) : (a > 0 ? "new" : "=")
            printf "| %s | %.1f %s | %.1f %s | %s |\n", l, b / d, u, a / d, u, ch
        }' "$TMP/before.$2" "$TMP/after.$2"
}

echo
echo "| Metric | Before ($REF) | After (working tree) | Change |"
echo "|---|---:|---:|---:|"
row "Launch: CPU in the first ${SETTLE} s" idle 1 1000000 ms
row "Menu shut: CPU per ${IDLE} s" idle 2 1000000 ms
row "Menu shut: wakeups per ${IDLE} s" idle 4 1 ""
row "Menu shut: memory footprint" idle 6 1048576 MB
row "Menu open: CPU per ${OPEN} s" open 2 1000000 ms
row "Menu open: instructions per ${OPEN} s" open 3 1000000 M
row "Menu open: wakeups per ${OPEN} s" open 4 1 ""
row "Menu open: wakeups from package idle per ${OPEN} s" open 5 1 ""
row "Menu open: memory footprint" open 6 1048576 MB
