import Cocoa
import CoreAudio

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

// MARK: - HID aux keys (same path as F1/F2/mute/vol)

enum AuxKey {
    // NX_KEYTYPE constants
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let brightnessUp: Int32 = 2
    static let brightnessDown: Int32 = 3
    static let mute: Int32 = 7
    static let illumUp: Int32 = 21
    static let illumDown: Int32 = 22

    static func post(_ key: Int32) {
        send(key, down: true)
        send(key, down: false)
    }

    // Some aux keys (keyboard illumination) are only honored on the session tap.
    // Post to both to cover all cases.
    static func postAll(_ key: Int32) {
        send(key, down: true, taps: [.cghidEventTap, .cgSessionEventTap, .cgAnnotatedSessionEventTap])
        send(key, down: false, taps: [.cghidEventTap, .cgSessionEventTap, .cgAnnotatedSessionEventTap])
    }

    private static func send(_ key: Int32, down: Bool, taps: [CGEventTapLocation] = [.cghidEventTap]) {
        let flagsRaw: UInt = down ? 0xa00 : 0xb00
        let data1 = (Int(key) << 16) | ((down ? 0xa : 0xb) << 8)
        guard let ev = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flagsRaw),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ), let cg = ev.cgEvent else { return }
        for tap in taps { cg.post(tap: tap) }
    }
}

// MARK: - Display brightness via DisplayServices (private)

enum DisplayBrightness {
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getFn: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private static let setFn: (@convention(c) (UInt32, Float) -> Int32)? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: (@convention(c) (UInt32, Float) -> Int32).self)
    }()

    static func level() -> Float? {
        guard let g = getFn else { return nil }
        var v: Float = 0
        return g(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    static func setLevel(_ v: Float) {
        guard let s = setFn else { return }
        _ = s(CGMainDisplayID(), max(0, min(1, v)))
    }

    static func step(_ delta: Float) {
        let cur = level() ?? 0.5
        setLevel(cur + delta)
    }
}

// MARK: - Keyboard backlight via CoreBrightness (private)
//
// On macOS 26 (Tahoe), the API is:
//   -[KeyboardBrightnessClient copyKeyboardBacklightIDs]  -> NSArray<NSNumber*>
//   -[KeyboardBrightnessClient brightnessForKeyboard:(uint64_t)]  -> float
//   -[KeyboardBrightnessClient setBrightness:(float) forKeyboard:(uint64_t)]  -> BOOL

enum KeyboardBacklight {
    private static let clientClass: AnyClass? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        let cls: AnyClass? = NSClassFromString("KeyboardBrightnessClient")
        if cls == nil { NSLog("Untouchable: KeyboardBrightnessClient class not found") }
        return cls
    }()

    private static let client: NSObject? = {
        guard let cls = clientClass as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static func imp<T>(_ selName: String, as type: T.Type) -> T? {
        guard let cls = clientClass,
              let m = class_getInstanceMethod(cls, NSSelectorFromString(selName))
        else {
            NSLog("Untouchable: missing method \(selName)")
            return nil
        }
        return unsafeBitCast(method_getImplementation(m), to: T.self)
    }

    private static let copyIdsImp: (@convention(c) (AnyObject, Selector) -> NSArray?)?
        = imp("copyKeyboardBacklightIDs", as: (@convention(c) (AnyObject, Selector) -> NSArray?).self)

    private static let getImp: (@convention(c) (AnyObject, Selector, UInt64) -> Float)?
        = imp("brightnessForKeyboard:", as: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)

    private static let setImp: (@convention(c) (AnyObject, Selector, Float, UInt64) -> Bool)?
        = imp("setBrightness:forKeyboard:", as: (@convention(c) (AnyObject, Selector, Float, UInt64) -> Bool).self)

    // First keyboard ID (usually the built-in). Re-queried each call in case devices change.
    private static func currentKeyboardID() -> UInt64? {
        guard let c = client, let copy = copyIdsImp else { return nil }
        let arr = copy(c, NSSelectorFromString("copyKeyboardBacklightIDs"))
        guard let first = arr?.firstObject as? NSNumber else {
            NSLog("Untouchable: no keyboard backlight IDs found")
            return nil
        }
        return first.uint64Value
    }

    static func level() -> Float? {
        guard let c = client, let g = getImp, let id = currentKeyboardID() else { return nil }
        return g(c, NSSelectorFromString("brightnessForKeyboard:"), id)
    }

    static func setLevel(_ v: Float) {
        guard let c = client, let s = setImp, let id = currentKeyboardID() else { return }
        let clamped = max(0, min(1, v))
        let ok = s(c, NSSelectorFromString("setBrightness:forKeyboard:"), clamped, id)
        NSLog("Untouchable: kbd backlight -> \(clamped) ok=\(ok)")
    }

    static func step(_ delta: Float) {
        let cur = level() ?? 0.5
        setLevel(cur + delta)
    }
}

// MARK: - System volume via CoreAudio

enum SystemVolume {
    private static var defaultOutputDevice: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    static func get() -> Float? {
        guard let dev = defaultOutputDevice else { return nil }
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr {
            return vol
        }
        // Fall back to per-channel average (L + R)
        var l = Float32(0), r = Float32(0)
        var s1 = UInt32(MemoryLayout<Float32>.size)
        var s2 = UInt32(MemoryLayout<Float32>.size)
        addr.mElement = 1
        let rL = AudioObjectGetPropertyData(dev, &addr, 0, nil, &s1, &l)
        addr.mElement = 2
        let rR = AudioObjectGetPropertyData(dev, &addr, 0, nil, &s2, &r)
        if rL == noErr && rR == noErr { return (l + r) / 2 }
        return nil
    }

    static func set(_ v: Float) {
        guard let dev = defaultOutputDevice else { return }
        var vol = Float32(max(0, min(1, v)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &addr) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
            return
        }
        addr.mElement = 1
        AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
        addr.mElement = 2
        AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
    }

    private static var preMuteVolume: Float?

    private static func muteAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func isMuted() -> Bool {
        guard let dev = defaultOutputDevice else { return false }
        var addr = muteAddr()
        if AudioObjectHasProperty(dev, &addr) {
            var cur = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr {
                return cur != 0
            }
        }
        return (get() ?? 1) < 0.001
    }

    static func toggleMute() {
        guard let dev = defaultOutputDevice else { return }
        var addr = muteAddr()
        if AudioObjectHasProperty(dev, &addr) {
            var cur = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr {
                var next: UInt32 = cur == 0 ? 1 : 0
                AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &next)
                return
            }
        }
        // Fallback: no hardware mute (common with AirPods, etc.) — drop volume to 0 and restore.
        if let cur = get(), cur > 0.001 {
            preMuteVolume = cur
            set(0)
        } else {
            set(preMuteVolume ?? 0.5)
            preMuteVolume = nil
        }
    }
}

// MARK: - Press-and-hold auto-repeat
//
// NSButton on the Touch Bar does NOT receive mouseDown/mouseUp — it receives
// direct touches via touchesBegan/touchesEnded (NSResponder). Timers must be
// scheduled in .eventTracking mode because Touch Bar touches block the default
// run loop mode. Pattern from MTMR's CustomButtonTouchBarItem.

final class HoldButton: NSButton {
    var onFire: (() -> Void)?
    private var repeatTimer: Timer?

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        onFire?()
        let delay = Timer(timeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let repeater = Timer(timeInterval: NSEvent.keyRepeatInterval, repeats: true) { [weak self] _ in
                self?.onFire?()
            }
            RunLoop.main.add(repeater, forMode: .eventTracking)
            RunLoop.main.add(repeater, forMode: .default)
            self.repeatTimer = repeater
        }
        RunLoop.main.add(delay, forMode: .eventTracking)
        RunLoop.main.add(delay, forMode: .default)
        repeatTimer = delay
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

// MARK: - Touch Bar

final class UntouchableBar: NSObject, NSTouchBarDelegate {
    static let weatherId = NSTouchBarItem.Identifier("com.untouchable.weather")
    static let clockId = NSTouchBarItem.Identifier("com.untouchable.clock")
    static let muteId = NSTouchBarItem.Identifier("com.untouchable.mute")
    static let volumeId = NSTouchBarItem.Identifier("com.untouchable.volume")
    static let kbdDownId = NSTouchBarItem.Identifier("com.untouchable.kbddown")
    static let kbdUpId = NSTouchBarItem.Identifier("com.untouchable.kbdup")
    static let brightDownId = NSTouchBarItem.Identifier("com.untouchable.brightdown")
    static let brightUpId = NSTouchBarItem.Identifier("com.untouchable.brightup")

    let bar = NSTouchBar()
    let weatherLabel = NSTextField(labelWithString: "… loading")
    let clockLabel = NSTextField(labelWithString: "--:--")
    weak var volumeSlider: NSSlider?
    weak var muteButton: NSButton?

    override init() {
        super.init()
        bar.delegate = self
        bar.defaultItemIdentifiers = [
            Self.weatherId,
            .fixedSpaceLarge,
            Self.clockId,
            .flexibleSpace,
            Self.muteId,
            Self.volumeId,
            .fixedSpaceSmall,
            Self.kbdDownId,
            Self.kbdUpId,
            Self.brightDownId,
            Self.brightUpId,
        ]
        weatherLabel.font = .systemFont(ofSize: 18, weight: .medium)
        weatherLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        clockLabel.textColor = .white
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.weatherId:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = weatherLabel
            return item
        case Self.clockId:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = clockLabel
            return item
        case Self.brightDownId:
            return repeatingIconButton(id: id, symbol: "sun.min", fire: { [weak self] in self?.brightDown() }, label: "Brightness down")
        case Self.brightUpId:
            return repeatingIconButton(id: id, symbol: "sun.max", fire: { [weak self] in self?.brightUp() }, label: "Brightness up")
        case Self.kbdDownId:
            return repeatingIconButton(id: id, symbol: "light.min", fire: { [weak self] in self?.kbdDown() }, label: "Keyboard light down")
        case Self.kbdUpId:
            return repeatingIconButton(id: id, symbol: "light.max", fire: { [weak self] in self?.kbdUp() }, label: "Keyboard light up")
        case Self.muteId:
            let item = iconButton(id: id, symbol: "speaker.wave.2.fill", action: #selector(muteToggle), label: "Mute")
            if let btn = (item as? NSCustomTouchBarItem)?.view as? NSButton { muteButton = btn }
            refreshMuteIcon()
            return item
        case Self.volumeId:
            let item = NSCustomTouchBarItem(identifier: id)
            let slider = NSSlider(value: Double(SystemVolume.get() ?? 0.5),
                                  minValue: 0, maxValue: 1,
                                  target: self, action: #selector(volumeChanged(_:)))
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
            item.view = slider
            volumeSlider = slider
            return item
        default:
            return nil
        }
    }

    private func iconButton(id: NSTouchBarItem.Identifier, symbol: String, action: Selector, label: String) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let btn = NSButton(title: "", target: self, action: action)
        btn.image = img
        btn.bezelStyle = .rounded
        btn.imageScaling = .scaleProportionallyDown
        item.view = btn
        return item
    }

    private func repeatingIconButton(id: NSTouchBarItem.Identifier, symbol: String, fire: @escaping () -> Void, label: String) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        // Using the convenience init ensures the cell + image position are fully set up.
        // target/action stay nil — onFire is what actually runs.
        let btn = HoldButton(title: "", target: nil, action: nil)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        btn.bezelStyle = .rounded
        btn.imageScaling = .scaleProportionallyDown
        btn.onFire = fire
        item.view = btn
        return item
    }

    func refreshVolumeSlider() {
        guard let s = volumeSlider, let v = SystemVolume.get() else { return }
        s.doubleValue = Double(v)
    }

    func refreshMuteIcon() {
        guard let btn = muteButton else { return }
        let vol = SystemVolume.get() ?? 1
        let muted = SystemVolume.isMuted() || vol < 0.001
        let name = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        btn.image = NSImage(systemSymbolName: name, accessibilityDescription: "Mute")
    }

    @objc func brightDown() { DisplayBrightness.step(-1.0/16) }
    @objc func brightUp()   { DisplayBrightness.step(+1.0/16) }
    @objc func kbdDown() { KeyboardBacklight.step(-1.0/16) }
    @objc func kbdUp()   { KeyboardBacklight.step(+1.0/16) }
    @objc func muteToggle() {
        SystemVolume.toggleMute()
        refreshMuteIcon()
    }
    @objc func volumeChanged(_ sender: NSSlider) {
        SystemVolume.set(Float(sender.doubleValue))
        refreshMuteIcon()
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
    var presentTimer: Timer?
    var enabled = false
    var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "∅"
            btn.toolTip = "Untouchable — your Touch Bar, silenced"
        }
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Disable", action: #selector(toggle), keyEquivalent: "d")
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Refresh Weather", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Untouchable", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // One-time tray-slot registration (replaces the close-box X)
        ControlStrip.register()

        enable()

        // Timers
        bar.tickClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.bar.tickClock()
            self?.bar.refreshVolumeSlider()
            self?.bar.refreshMuteIcon()
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

    @objc func toggle() {
        if enabled { disable() } else { enable() }
    }

    func enable() {
        DFRSetStatus(2)
        DFR.showCloseBox?(false)
        NSApp.activate(ignoringOtherApps: true)
        GlobalTouchBar.present(bar.bar)
        presentTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            GlobalTouchBar.present(self.bar.bar)
        }
        enabled = true
        toggleItem.title = "Disable"
        statusItem.button?.title = "∅"
        NSLog("Untouchable: ENABLED")
    }

    func disable() {
        presentTimer?.invalidate()
        presentTimer = nil
        DFRSetStatus(0) // hand the default strip back
        enabled = false
        toggleItem.title = "Enable"
        statusItem.button?.title = "⊘"
        NSLog("Untouchable: DISABLED")
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
