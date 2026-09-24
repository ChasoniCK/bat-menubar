import AppKit
import ServiceManagement
import IOKit
import IOKit.ps

// MARK: - SMC

// Layout must match SMCKeyData_t from Apple's smc.c exactly (80 bytes).
private struct SMCVers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func keyInfo(_ key: UInt32) -> SMCKeyInfo? {
        if let cached = infoCache[key] { return cached }
        var p = SMCParam(); p.key = key; p.data8 = 9  // READ_KEYINFO
        guard let out = call(&p) else { return nil }
        infoCache[key] = out.keyInfo
        return out.keyInfo
    }

    /// Reads a `flt ` SMC key. Returns nil if the key is absent or not a float.
    func float(_ name: String) -> Double? {
        guard let v: Float32 = value(name, type: 0x666C7420) else { return nil }  // 'flt '
        return v.isFinite ? Double(v) : nil
    }

    /// Reads an `si32` SMC key. SMC payloads are little-endian, like the floats above.
    func int32(_ name: String) -> Int32? {
        value(name, type: 0x73693332)  // 'si32'
    }

    /// The payload must be decoded from the reply buffer in place. Handing the 32-byte tuple back to
    /// the caller and reading it there silently yields zeroes once the optimizer gets hold of it.
    private func value<T>(_ name: String, type: UInt32) -> T? {
        let key = name.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
        guard let info = keyInfo(key), info.dataType == type,
              info.dataSize == UInt32(MemoryLayout<T>.size) else { return nil }
        var p = SMCParam(); p.key = key; p.data8 = 5; p.keyInfo = info  // READ_BYTES
        guard var out = call(&p) else { return nil }
        return withUnsafeBytes(of: &out.bytes) { $0.loadUnaligned(as: T.self) }
    }
}

// MARK: - Monitor

final class PowerMonitor {
    private(set) var system = 0.0        // total load of the machine, W
    private(set) var adapter = 0.0       // delivered by the charger, W
    private(set) var batteryWatts = 0.0  // + charging into battery, - drawn from it

    /// Opened on the first reading rather than at launch: a login item that is never clicked
    /// never touches the SMC.
    private lazy var smc = SMC()

    var pluggedIn: Bool { adapter > 0.05 }
    var charging: Bool { batteryWatts > 0.05 }
    /// Load exceeds what the adapter supplies, so the battery is covering the rest.
    var onBattery: Bool { batteryWatts < -0.05 }
    var drainingWhilePluggedIn: Bool { pluggedIn && onBattery }
    var fromBattery: Double { max(-batteryWatts, 0) }

    /// Two SMC keys, both republished on the SMC's own 1 Hz grid, and nothing else. B0AP is signed
    /// (negative = leaving the battery), which is why IORegistry is no longer consulted here: its
    /// battery data only refreshes once a minute, so direction used to lag by up to 60 s.
    func refresh() {
        adapter = smc?.float("PDTR") ?? 0
        batteryWatts = Double(smc?.int32("B0AP") ?? 0) / 1000
        system = adapter + max(-batteryWatts, 0) - max(batteryWatts, 0)
    }
}


// MARK: - Menu

/// One readout row: dim label, full-contrast value, right-aligned on a tab stop. The tab does the
/// aligning that space padding used to, which keeps the monospaced look without the extra width.
///
/// The row owns its title and remembers what it last showed, so a tick whose reading has not
/// moved costs one string compare — no attributed string built, no menu redraw.
@MainActor
private final class Readout {
    let item = NSMenuItem()
    private let title: NSMutableAttributedString
    private let valueStart: Int
    private var shownValue = ""
    private var shownColor: NSColor?

    init(_ label: String) {
        title = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: Readout.font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Readout.style,
        ])
        valueStart = title.length
        title.append(NSAttributedString(string: " ", attributes: [
            .font: Readout.font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Readout.style,
        ]))
    }

    /// Both text and color are compared: the System row can turn red while its number holds still.
    func show(_ value: String, _ color: NSColor? = nil) {
        guard value != shownValue || color != shownColor else { return }
        shownValue = value
        shownColor = color
        title.replaceCharacters(in: NSRange(location: valueStart, length: title.length - valueStart), with: value)
        title.addAttribute(.foregroundColor, value: color ?? NSColor.labelColor,
                           range: NSRange(location: valueStart, length: title.length - valueStart))
        item.attributedTitle = title  // copied by the setter, so the buffer can be edited in place
    }

    // Built once: the font lookup and paragraph style are identical for every row.
    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                                                          weight: .regular)
    private static let style: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 152)]
        return style
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = PowerMonitor()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private let loadRow = Readout("System:")
    private let adapterRow = Readout("Adapter:")
    private let batteryRow = Readout("Battery:")
    private let warnRow = Readout("Deficit:")
    private let stateRow = Readout("State:")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.batteryblock.fill",
                                           accessibilityDescription: "Power")

        // autoenablesItems off so the readout rows stay inert without AppKit repainting them;
        // an attributedTitle keeps its color either way.
        menu.autoenablesItems = false
        menu.delegate = self

        // A menu item with no action is painted dimmed, colors and all — so the readouts get an
        // inert one just to keep full contrast.
        for row in [loadRow, adapterRow, batteryRow, stateRow, warnRow] {
            let item = row.item
            item.action = #selector(ignore)
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(.separator())
        loginItem.target = self
        loginItem.isEnabled = true
        menu.addItem(loginItem)

        menu.addItem(.separator())
        // No keyEquivalent here: showing "⌘Q" makes AppKit reserve ~47pt of empty space on every row.
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        // The visible item shows no shortcut; this hidden twin carries ⌘Q so the reserved
        // key-equivalent column does not widen every row.
        let quitShortcut = NSMenuItem(title: "Quit", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quitShortcut.target = self
        quitShortcut.isHidden = true
        quitShortcut.allowsKeyEquivalentWhenHidden = true
        menu.addItem(quitShortcut)

        // No reading and no login-item query here: menuWillOpen does both before anything is
        // shown, so launch (at every login) stays free of SMC calls and of the XPC round trip.
        statusItem.menu = menu

        // ponytail: the status icon can be hidden by bar managers, so --preview pops the same
        // menu on screen — the only way to eyeball the layout.
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                menu.popUp(positioning: nil, at: NSPoint(x: 600, y: 900), in: nil)
            }
        }
    }

    // ponytail: nothing to show while the menu is shut, so only poll while it's open.
    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginState()
        update()
        // The timer is added to RunLoop.main below, so the block only ever fires on the main
        // thread — but Timer's block is @Sendable, so the isolation has to be asserted.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Slack lets the kernel fold this wakeup into one that is due anyway instead of waking
        // the CPU on the dot; 10 % of the interval is what Apple's energy guide asks for.
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)  // .default stops firing during menu tracking
        timer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        monitor.refresh()

        loadRow.show(watts(monitor.system), monitor.onBattery ? .systemRed : .systemGreen)
        adapterRow.show(watts(monitor.adapter, sign: monitor.adapter > 0.005 ? "+" : nil))
        batteryRow.show(watts(abs(monitor.batteryWatts), sign: batterySign),
                        monitor.onBattery ? .systemRed : nil)
        stateRow.show(stateText)

        // Toggling visibility re-lays the menu out, so only touch it when it actually flips.
        let hideWarn = !monitor.drainingWhilePluggedIn
        if warnRow.item.isHidden != hideWarn { warnRow.item.isHidden = hideWarn }
        if !hideWarn {
            warnRow.show(watts(monitor.fromBattery, sign: "+"), .systemRed)
        }
    }

    /// Costs an XPC round trip that wakes smd and backgroundtaskmanagementd, so it is refreshed only
    /// when the menu opens and right after the user toggles it — never on the 1 Hz tick.
    private func refreshLoginState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private var batterySign: String? {
        if monitor.batteryWatts > 0.005 { return "+" }
        if monitor.batteryWatts < -0.005 { return "-" }
        return nil
    }

    private var stateText: String {
        if monitor.charging { return "Charging" }
        if monitor.onBattery { return "Discharging" }
        return monitor.pluggedIn ? "Not Charging" : "Idle"
    }

    /// Sign sits in its own column, so a "+" never shifts the number: "+ 6.98W" / "  0.00W".
    /// Integer math rather than String(format:): no trip through Foundation's formatter and no
    /// NSString, and the result is short enough to live in Swift's inline small-string storage.
    private func watts(_ value: Double, sign: String? = nil) -> String {
        let centi = Int((min(abs(value), 9999) * 100).rounded())  // clamp: Int() traps on overflow
        let frac = centi % 100
        let lead: String = sign ?? " "
        let minus: String = value < 0 && centi > 0 ? "-" : ""
        let pad: String = frac < 10 ? "0" : ""
        return "\(lead) \(minus)\(centi / 100).\(pad)\(frac)W"
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func ignore() {}

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

/// Only the --print smoke test wants this, so it may take the slow IORegistry path.
private func batteryPercent() -> Int {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int ?? 0
}

@main
enum Bat {
    // NSApplication.delegate is weak — a local would be deallocated before launch finishes.
    @MainActor private static let delegate = AppDelegate()

    @MainActor static func main() {
        // ponytail: `Bat --print` dumps one reading and exits — the app's own smoke test.
        if CommandLine.arguments.contains("--print") {
            let m = PowerMonitor()
            m.refresh()
            print(String(format: "system=%.2fW adapter=%.2fW battery=%+.2fW plugged=%@ charging=%@ soc=%d%%",
                         m.system, m.adapter, m.batteryWatts,
                         m.pluggedIn ? "yes" : "no", m.charging ? "yes" : "no", batteryPercent()))
            print("loginItem=\(SMAppService.mainApp.status.rawValue) (1 = enabled)")
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--login"), i + 1 < CommandLine.arguments.count {
            do {
                if CommandLine.arguments[i + 1] == "on" { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                print("ok, status=\(SMAppService.mainApp.status.rawValue)")
            } catch { print("failed: \(error)") }
            return
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
