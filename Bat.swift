import AppKit
import ServiceManagement
import IOKit
import IOKit.ps

// MARK: - SMC

// ponytail: minimal AppleSMC reader — only what a power gauge needs (float keys).
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
        let key = name.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
        guard let info = keyInfo(key), info.dataSize == 4,
              info.dataType == 0x666C7420 else { return nil }  // 'flt '
        var p = SMCParam(); p.key = key; p.data8 = 5; p.keyInfo = info  // READ_BYTES
        guard var out = call(&p) else { return nil }
        let v = withUnsafeBytes(of: &out.bytes) { $0.loadUnaligned(as: Float32.self) }
        return v.isFinite ? Double(v) : nil
    }
}

// MARK: - Battery (IORegistry)

struct BatteryState {
    var pluggedIn = false
    var charging = false
    var percent = 0
    var milliAmps = 0  // + into battery, - out of it

    static func read() -> BatteryState {
        var s = BatteryState()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return s }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let d = unmanaged?.takeRetainedValue() as? [String: Any] else { return s }
        s.pluggedIn = d["ExternalConnected"] as? Bool ?? false
        s.charging = d["IsCharging"] as? Bool ?? false
        s.percent = d["CurrentCapacity"] as? Int ?? 0
        s.milliAmps = (d["InstantAmperage"] as? Int) ?? (d["Amperage"] as? Int) ?? 0
        return s
    }
}

// MARK: - Monitor

final class PowerMonitor {
    private(set) var system = 0.0        // total load of the machine, W
    private(set) var adapter = 0.0       // delivered by the charger, W
    private(set) var batteryWatts = 0.0  // + charging into battery, - drawn from it
    private(set) var battery = BatteryState()

    private let smc = SMC()

    /// Load exceeds what the adapter supplies, so the battery is covering the rest.
    var onBattery: Bool { batteryWatts < -0.05 }
    var drainingWhilePluggedIn: Bool { adapter > 0.1 && onBattery }
    var fromBattery: Double { max(-batteryWatts, 0) }

    func refresh() {
        battery = .read()
        // SMC gives live magnitudes at 1 Hz; IORegistry only knows the direction (it lags ~30 s,
        // but charge/discharge flips far slower than the wattage does).
        adapter = smc?.float("PDTR") ?? 0
        let flow = smc?.float("PPBR") ?? 0   // ~0.6 W of housekeeping noise when nothing flows
        if battery.charging {
            batteryWatts = flow
        } else if battery.milliAmps < -50 {
            batteryWatts = -flow
        } else {
            batteryWatts = 0
        }
        system = adapter + max(-batteryWatts, 0) - max(batteryWatts, 0)
    }
}


// MARK: - Menu

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = PowerMonitor()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private let loadItem = NSMenuItem()
    private let adapterItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let warnItem = NSMenuItem()
    private let stateItem = NSMenuItem()
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
        for item in [loadItem, adapterItem, batteryItem, stateItem, warnItem] {
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
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
        update()

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
        update()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)  // .default stops firing during menu tracking
        timer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        monitor.refresh()

        loadItem.attributedTitle = reading("System", monitor.system,
                                           color: monitor.onBattery ? .systemRed : .systemGreen)
        adapterItem.attributedTitle = reading("Adapter", monitor.adapter, sign: monitor.adapter > 0.005 ? "+" : nil)
        batteryItem.attributedTitle = reading("Battery", abs(monitor.batteryWatts),
                                              sign: batterySign,
                                              color: monitor.onBattery ? .systemRed : nil)
        stateItem.attributedTitle = pair(pad("State:"), stateText)

        warnItem.isHidden = !monitor.drainingWhilePluggedIn
        if monitor.drainingWhilePluggedIn {
            warnItem.attributedTitle = styled(pad("Deficit:") + String(format: "%5.2fW from battery", monitor.fromBattery),
                                              .systemRed)
        }

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private var batterySign: String? {
        if monitor.batteryWatts > 0.005 { return "+" }
        if monitor.batteryWatts < -0.005 { return "-" }
        return nil
    }

    private var stateText: String {
        if monitor.battery.charging { return "Charging" }
        if monitor.onBattery { return "Discharging" }
        return monitor.battery.pluggedIn ? "Not Charging" : "Idle"
    }

    /// "Adapter: +  7.37W" — a monospaced font is what keeps the columns lined up.
    private func reading(_ label: String, _ watts: Double, sign: String? = nil, color: NSColor? = nil) -> NSAttributedString {
        pair(pad(label + ":"), (sign ?? " ") + String(format: "%5.2fW", watts), color)
    }

    /// Dim label, full-contrast value. Disabled rows would otherwise be painted gray throughout.
    private func pair(_ label: String, _ value: String, _ color: NSColor? = nil) -> NSAttributedString {
        let line = NSMutableAttributedString(attributedString: styled(label, .secondaryLabelColor))
        line.append(styled(value, color ?? .labelColor))
        return line
    }

    private func pad(_ label: String) -> String {
        label.padding(toLength: max(9, label.count), withPad: " ", startingAt: 0)
    }

    private func styled(_ text: String, _ color: NSColor? = nil) -> NSAttributedString {
        // A notch below the menu font: readings are a compact block, not menu commands.
        let size = NSFont.menuFont(ofSize: 0).pointSize - 2
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]
        if let color { attributes[.foregroundColor] = color }
        return NSAttributedString(string: text, attributes: attributes)
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

@main
enum Bat {
    // NSApplication.delegate is weak — a local would be deallocated before launch finishes.
    private static let delegate = AppDelegate()

    static func main() {
        // ponytail: `Bat --print` dumps one reading and exits — the app's own smoke test.
        if CommandLine.arguments.contains("--print") {
            let m = PowerMonitor()
            m.refresh()
            print(String(format: "system=%.2fW adapter=%.2fW battery=%+.2fW plugged=%@ charging=%@ soc=%d%%",
                         m.system, m.adapter, m.batteryWatts,
                         m.battery.pluggedIn ? "yes" : "no", m.battery.charging ? "yes" : "no", m.battery.percent))
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
