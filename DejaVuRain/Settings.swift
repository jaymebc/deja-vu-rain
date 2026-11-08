import AppKit

enum Links {
    static let website = URL(string: "https://chicletes.jaymebc.com")!
    // The page exists in Portuguese today. Add the English text before submitting to the App Store.
    static let privacy = URL(string: "https://chicletes.jaymebc.com/privacidade/")!
}

/// User choices from the menu bar, saved in UserDefaults.
@MainActor
final class Settings {
    static let shared = Settings()

    struct ColorPreset {
        let name: String
        let rgb: SIMD3<Float>
        var nsColor: NSColor { NSColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1) }
    }

    private static func preset(_ name: String, _ hex: UInt32) -> ColorPreset {
        ColorPreset(name: name, rgb: SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255)
    }

    static let colors: [ColorPreset] = [
        preset("Classic Green", 0x00FF41),
        preset("Emerald", 0x00DD3C),
        preset("Lime", 0x7DFF3A),
        preset("Amber", 0xFFB000),
        preset("Cyan", 0x00E5FF),
        preset("Violet", 0xB26BFF),
        preset("Red", 0xFF3030),
        preset("White", 0xFFFFFF),
    ]
    static let speeds: [(name: String, factor: Float)] = [("Slow", 0.6), ("Normal", 1), ("Fast", 1.6)]
    static let densities: [(name: String, factor: Float)] = [("Sparse", 0.5), ("Normal", 1), ("Dense", 2)]
    static let brightnesses: [(name: String, factor: Float)] = [("100%", 1), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25)]

    private let defaults = UserDefaults.standard

    var colorIndex: Int { didSet { defaults.set(colorIndex, forKey: "colorIndex") } }
    var speedIndex: Int { didSet { defaults.set(speedIndex, forKey: "speedIndex") } }
    var densityIndex: Int { didSet { defaults.set(densityIndex, forKey: "densityIndex") } }
    var brightnessIndex: Int { didSet { defaults.set(brightnessIndex, forKey: "brightnessIndex") } }
    var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    var welcomeShown: Bool { didSet { defaults.set(welcomeShown, forKey: "welcomeShown") } }
    private(set) var disabledDisplays: Set<String>

    /// Menu choice 8 (one past the presets) is "Mixed": every new drop gets its own random color.
    static let mixedIndex = colors.count
    /// Colors used by Mixed. White is left out, because the head of each drop is already white.
    static let mixedColors: [Int] = colors.indices.filter { colors[$0].name != "White" }

    /// What the rain engine should use for new drops.
    var engineColor: Int { colorIndex == Self.mixedIndex ? RainEngine.mixed : colorIndex }
    var speedFactor: Float { Self.speeds[speedIndex].factor }
    var density: Float { Self.densities[densityIndex].factor }
    var brightness: Float { Self.brightnesses[brightnessIndex].factor }

    private init() {
        func index(_ key: String, _ fallback: Int, _ count: Int) -> Int {
            let v = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
            return (0..<count).contains(v) ? v : fallback
        }
        colorIndex = index("colorIndex", 0, Self.colors.count + 1)   // +1 for Mixed
        speedIndex = index("speedIndex", 1, Self.speeds.count)
        densityIndex = index("densityIndex", 1, Self.densities.count)
        brightnessIndex = index("brightnessIndex", 0, Self.brightnesses.count)
        pauseOnBattery = UserDefaults.standard.bool(forKey: "pauseOnBattery")
        welcomeShown = UserDefaults.standard.bool(forKey: "welcomeShown")
        disabledDisplays = Set(UserDefaults.standard.stringArray(forKey: "disabledDisplays") ?? [])
    }

    func toggleDisplay(_ id: String) {
        if disabledDisplays.contains(id) { disabledDisplays.remove(id) } else { disabledDisplays.insert(id) }
        defaults.set(Array(disabledDisplays), forKey: "disabledDisplays")
    }
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike the numeric display ID.
    var uuidString: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
