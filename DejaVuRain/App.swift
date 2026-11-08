import AppKit
import Carbon.HIToolbox
import IOKit.ps
import MetalKit
import ServiceManagement

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// One borderless window per screen, at desktop level: behind every window and the desktop icons.
@MainActor
private final class Wallpaper {
    let window: NSWindow
    let view: MTKView
    let renderer: RainRenderer
    var stillDrawn = false   // with Reduce Motion on, one frame is drawn and then the animation stays frozen

    init?(screen: NSScreen) {
        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: MTLCreateSystemDefaultDevice())
        guard let renderer = RainRenderer(view: view) else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.orderFront(nil)
        self.window = window
        self.view = view
        self.renderer = renderer
    }
}

private func onBatteryPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
    else { return false }
    return type == kIOPSBatteryPowerValue
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var wallpapers: [Wallpaper] = []
    private var statusItem: NSStatusItem?
    private var welcome = WelcomeWindowController()
    private var hotKey: EventHotKeyRef?
    private var powerSource: CFRunLoopSource?
    private var userPaused = false
    private var screensAsleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        rebuildWindows()

        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePause),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)

        // Stop drawing while nobody can see it: screens asleep or session switched away. A locked screen or a
        // fully covered desktop is caught by the occlusion state of each window (updatePause).
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(hidden), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(shown), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(hidden), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(shown), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(updatePause),
                       name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        startPowerMonitor()
        registerHotKey()

        if !settings.welcomeShown {
            settings.welcomeShown = true
            welcome.show()
        }
    }

    // MARK: Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cloud.rain", accessibilityDescription: "Déjà Vu Rain")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The menu is rebuilt every time it opens, so checkmarks and the display list are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(entry("About Déjà Vu Rain", #selector(showAbout)))
        menu.addItem(.separator())

        let pause = entry(userPaused ? "Resume" : "Pause", #selector(togglePause), key: "r")
        pause.keyEquivalentModifierMask = [.control, .option, .command]   // also a global shortcut, see registerHotKey
        menu.addItem(pause)
        if reduceMotion {
            // No action, so the menu shows it greyed out: it only explains why the rain is still.
            menu.addItem(NSMenuItem(title: "Reduce Motion is on, so the rain is still", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())

        var colorItems = Settings.colors.enumerated().map { i, c in
            let item = entry(c.name, #selector(pickColor(_:)), tag: i, on: i == settings.colorIndex)
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [c.nsColor]))
            return item
        }
        let mixed = entry("Mixed", #selector(pickColor(_:)), tag: Settings.mixedIndex,
                          on: settings.colorIndex == Settings.mixedIndex)
        mixed.image = NSImage(systemSymbolName: "rainbow", accessibilityDescription: nil)?
            .withSymbolConfiguration(.preferringMulticolor())
        colorItems += [.separator(), mixed]
        menu.addItem(submenu("Color", colorItems))
        menu.addItem(submenu("Speed", Settings.speeds.enumerated().map { i, s in
            entry(s.name, #selector(pickSpeed(_:)), tag: i, on: i == settings.speedIndex)
        }))
        menu.addItem(submenu("Density", Settings.densities.enumerated().map { i, d in
            entry(d.name, #selector(pickDensity(_:)), tag: i, on: i == settings.densityIndex)
        }))
        menu.addItem(submenu("Brightness", Settings.brightnesses.enumerated().map { i, b in
            entry(b.name, #selector(pickBrightness(_:)), tag: i, on: i == settings.brightnessIndex)
        }))
        // Lists whatever screens this Mac has right now; identical monitor names get a number.
        let screens = NSScreen.screens
        let names = screens.map(\.localizedName)
        menu.addItem(submenu("Displays", screens.enumerated().compactMap { i, screen in
            guard let id = screen.uuidString else { return nil }
            let name = names[i]
            let same = names.filter { $0 == name }.count
            let label = same > 1 ? "\(name) (\(names[0...i].filter { $0 == name }.count))" : name
            return entry(label, #selector(toggleDisplay(_:)),
                         on: !settings.disabledDisplays.contains(id), object: id)
        }))
        menu.addItem(.separator())

        menu.addItem(entry("Pause on Battery Power", #selector(toggleBattery), on: settings.pauseOnBattery))
        menu.addItem(entry("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())

        menu.addItem(entry("Welcome Guide…", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Déjà Vu Rain", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func entry(_ title: String, _ action: Selector, key: String = "", tag: Int = 0,
                       on: Bool = false, object: Any? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.tag = tag
        item.state = on ? .on : .off
        item.representedObject = object
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }

    @objc private func pickColor(_ sender: NSMenuItem) { settings.colorIndex = sender.tag }
    @objc private func pickBrightness(_ sender: NSMenuItem) { settings.brightnessIndex = sender.tag }

    // Speed, density, color and brightness apply to the next drops only; the renderer reads them every frame.
    @objc private func pickSpeed(_ sender: NSMenuItem) { settings.speedIndex = sender.tag }
    @objc private func pickDensity(_ sender: NSMenuItem) { settings.densityIndex = sender.tag }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.toggleDisplay(id)
        rebuildWindows()
    }

    @objc private func toggleBattery() {
        settings.pauseOnBattery.toggle()
        updatePause()
    }

    @objc private func showWelcome() { welcome.show() }

    @objc private func showAbout() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let font = NSFont.systemFont(ofSize: 11)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: center]
        func link(_ text: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .link: url, .paragraphStyle: center])
        }
        let credits = NSMutableAttributedString(string: "Digital rain as your desktop wallpaper.\n\n", attributes: plain)
        credits.append(link("Chicletes para o Cérebro", Links.website))
        credits.append(NSAttributedString(string: "\n", attributes: plain))
        credits.append(link("Privacy Policy", Links.privacy))
        NSApp.activate()   // accessory apps are not frontmost by default
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Déjà Vu Rain",   // the bundle name is the ASCII "DejaVuRain"
            .credits: credits,                  // the © line comes from Info.plist
        ])
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Windows and pausing

    @objc private func rebuildWindows() {
        wallpapers.forEach { $0.window.close() }
        let enabled = NSScreen.screens.filter { screen in
            guard let id = screen.uuidString else { return true }
            return !settings.disabledDisplays.contains(id)
        }
        wallpapers = enabled.compactMap { Wallpaper(screen: $0) }
        updatePause()
    }

    @objc private func updatePause() {
        let batteryPause = settings.pauseOnBattery && onBatteryPower()
        let reduce = reduceMotion
        for w in wallpapers {
            let visible = w.window.occlusionState.contains(.visible)
            w.view.isPaused = userPaused || screensAsleep || batteryPause || !visible || reduce
            if reduce, visible, !w.stillDrawn {
                w.view.draw()          // a paused view does not draw by itself, so show one still frame
                w.stillDrawn = true
            } else if !reduce {
                w.stillDrawn = false
            }
        }
    }

    /// The system-wide "Reduce Motion" accessibility setting.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @objc private func hidden() { screensAsleep = true; updatePause() }
    @objc private func shown() { screensAsleep = false; updatePause() }

    @objc private func togglePause() {
        userPaused.toggle()
        updatePause()
    }

    private func startPowerMonitor() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.updatePause() }   // the source runs on the main run loop
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    /// Global shortcut ⌃⌥⌘R to pause or resume, from any app. Carbon hot keys work inside the sandbox.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.togglePause() }
            return noErr
        }, 1, &spec, context, nil)
        let id = EventHotKeyID(signature: OSType(0x4D585241), id: 1)   // 'MXRA'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
