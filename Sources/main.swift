import Cocoa

// MARK: - DFRFoundation private framework bridge

@_silgen_name("DFRSetStatus")
func DFRSetStatus(_ status: Int32)

// Resolve DFR symbols at runtime — some are missing on newer macOS.
enum DFR {
    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
    }()

    typealias SetPresetFn = @convention(c) (AnyObject, NSString) -> Void
    static let setPreset: SetPresetFn? = {
        guard let h = handle,
              let sym = dlsym(h, "DFRElementSetControlStripPresetIdentifier") else { return nil }
        return unsafeBitCast(sym, to: SetPresetFn.self)
    }()

    typealias ShowCloseBoxFn = @convention(c) (Bool) -> Void
    static let showCloseBox: ShowCloseBoxFn? = {
        guard let h = handle,
              let sym = dlsym(h, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return nil }
        return unsafeBitCast(sym, to: ShowCloseBoxFn.self)
    }()
}

// Private NSTouchBar selectors. The signature has changed across macOS versions;
// we try each known variant via IMP-casting.
enum GlobalTouchBar {
    static let trayId = "com.untouchable.strip"

    typealias Fn3 = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
    typealias Fn2 = @convention(c) (AnyObject, Selector, NSTouchBar, NSString?) -> Void

    static func call3(_ selName: String, _ bar: NSTouchBar) -> Bool {
        let sel = NSSelectorFromString(selName)
        guard let m = class_getClassMethod(NSTouchBar.self, sel) else { return false }
        let fn = unsafeBitCast(method_getImplementation(m), to: Fn3.self)
        fn(NSTouchBar.self, sel, bar, 1, trayId as NSString)
        return true
    }

    static func call2(_ selName: String, _ bar: NSTouchBar) -> Bool {
        let sel = NSSelectorFromString(selName)
        guard let m = class_getClassMethod(NSTouchBar.self, sel) else { return false }
        let fn = unsafeBitCast(method_getImplementation(m), to: Fn2.self)
        fn(NSTouchBar.self, sel, bar, trayId as NSString)
        return true
    }

    @discardableResult
    static func present(_ bar: NSTouchBar) -> String {
        let variants: [(String, (NSTouchBar) -> Bool)] = [
            ("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", { call3("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", $0) }),
            ("presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:", { call3("presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:", $0) }),
            ("presentSystemModalTouchBar:systemTrayItemIdentifier:", { call2("presentSystemModalTouchBar:systemTrayItemIdentifier:", $0) }),
            ("presentSystemModalFunctionBar:systemTrayItemIdentifier:", { call2("presentSystemModalFunctionBar:systemTrayItemIdentifier:", $0) }),
        ]
        for (_, fn) in variants where fn(bar) { return "ok" }
        return "none"
    }
}

// MARK: - Control Strip (persistent icon route used by MTMR/Pock)

enum ControlStrip {
    // Must match GlobalTouchBar.trayId so presentSystemModal replaces the X with this item.
    static func register() {
        let id = NSTouchBarItem.Identifier(GlobalTouchBar.trayId)
        let item = NSCustomTouchBarItem(identifier: id)
        // Tiny invisible view — we don't want a visible tray icon, just to claim the slot.
        let v = NSView(frame: .zero)
        item.view = v

        let sel = NSSelectorFromString("addSystemTrayItem:")
        if let m = class_getClassMethod(NSTouchBarItem.self, sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
            let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            fn(NSTouchBarItem.self, sel, item)
            NSLog("Untouchable: tray slot claimed via addSystemTrayItem:")
        } else {
            NSLog("Untouchable: addSystemTrayItem: not found")
        }
    }
}

// MARK: - Weather (Open-Meteo, no API key)

struct Weather {
    let tempC: Double
    let code: Int

    var emoji: String {
        switch code {
        case 0: return "☀️"
        case 1, 2: return "🌤"
        case 3: return "☁️"
        case 45, 48: return "🌫"
        case 51...67: return "🌧"
        case 71...77: return "🌨"
        case 80...82: return "🌧"
        case 95...99: return "⛈"
        default: return "•"
        }
    }
}

final class WeatherClient {
    // Amsterdam by default — edit or wire up CoreLocation later.
    var latitude: Double = 52.3676
    var longitude: Double = 4.9041

    func fetch(_ done: @escaping (Weather?) -> Void) {
        let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current_weather=true"
        )!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard
                let data,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cw = obj["current_weather"] as? [String: Any],
                let t = cw["temperature"] as? Double,
                let c = cw["weathercode"] as? Int
            else { DispatchQueue.main.async { done(nil) }; return }
            DispatchQueue.main.async { done(Weather(tempC: t, code: c)) }
        }.resume()
    }
}

// MARK: - Touch Bar

final class UntouchableBar: NSObject, NSTouchBarDelegate {
    static let weatherId = NSTouchBarItem.Identifier("com.untouchable.weather")
    static let clockId = NSTouchBarItem.Identifier("com.untouchable.clock")

    let bar = NSTouchBar()
    let weatherLabel = NSTextField(labelWithString: "… loading")
    let clockLabel = NSTextField(labelWithString: "--:--")

    override init() {
        super.init()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.flexibleSpace, Self.weatherId, .fixedSpaceLarge, Self.clockId, .flexibleSpace]
        weatherLabel.font = .systemFont(ofSize: 18, weight: .medium)
        weatherLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        clockLabel.textColor = .white
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        switch id {
        case Self.weatherId: item.view = weatherLabel
        case Self.clockId: item.view = clockLabel
        default: return nil
        }
        return item
    }

    func setWeather(_ w: Weather?) {
        weatherLabel.stringValue = w.map { "\($0.emoji)  \(Int($0.tempC.rounded()))°" } ?? "— no data"
    }

    func tickClock() {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        clockLabel.stringValue = f.string(from: Date())
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let bar = UntouchableBar()
    let weather = WeatherClient()
    var weatherTimer: Timer?
    var clockTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "∅"
            btn.toolTip = "Untouchable — your Touch Bar, silenced"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh Weather", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Untouchable", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Take over the Touch Bar
        DFRSetStatus(2)
        NSLog("Untouchable: DFRSetStatus(2) called")

        // ORDER MATTERS (per MTMR):
        // 1. Register a system-tray item with our identifier
        // 2. Call DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        // 3. Present the modal bar, passing that same identifier as systemTrayItemIdentifier
        ControlStrip.register()
        DFR.showCloseBox?(false)
        NSApp.activate(ignoringOtherApps: true)
        GlobalTouchBar.present(bar.bar)

        // Keep shoving the bar — if the user taps the (X) dismiss, we re-present fast.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            GlobalTouchBar.present(self.bar.bar)
        }

        // Timers
        bar.tickClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.bar.tickClock()
        }
        refresh()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        DFRSetStatus(0) // give the system strip back
    }

    @objc func refresh() {
        weather.fetch { [weak self] w in self?.bar.setWeather(w) }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
