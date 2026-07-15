import AppKit
import ServiceManagement
import Carbon
import HengJieCore

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let pinHotKeyCode = "pinHotKeyCode"
        static let pinHotKeyModifiers = "pinHotKeyModifiers"
        static let textHotKeyCode = "textHotKeyCode"
        static let textHotKeyModifiers = "textHotKeyModifiers"
        static let gifHotKeyCode = "gifHotKeyCode"
        static let gifHotKeyModifiers = "gifHotKeyModifiers"
        static let gifFramesPerSecond = "gifFramesPerSecond"
        static let gifQuality = "gifQuality"
        static let gifShowsCursor = "gifShowsCursor"
        static let saveFormat = "saveFormat"
        static let defaultDriver = "defaultDriver"
    }

    var hotKeyCode: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.hotKeyCode) as? Int
            return UInt32(value ?? 0) // ANSI A
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.hotKeyCode) }
    }

    var hotKeyModifiers: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.hotKeyModifiers) as? Int
            return UInt32(value ?? (optionKey | shiftKey))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.hotKeyModifiers) }
    }

    var pinHotKeyCode: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.pinHotKeyCode) as? Int
            return UInt32(value ?? 35) // ANSI P
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.pinHotKeyCode) }
    }

    var pinHotKeyModifiers: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.pinHotKeyModifiers) as? Int
            return UInt32(value ?? (optionKey | shiftKey))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.pinHotKeyModifiers) }
    }

    var textHotKeyCode: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.textHotKeyCode) as? Int
            return UInt32(value ?? 31) // ANSI O
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.textHotKeyCode) }
    }

    var textHotKeyModifiers: UInt32 {
        get {
            let value = UserDefaults.standard.object(forKey: Key.textHotKeyModifiers) as? Int
            return UInt32(value ?? (optionKey | shiftKey))
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.textHotKeyModifiers) }
    }

    var gifHotKeyCode: UInt32 {
        get { UInt32((UserDefaults.standard.object(forKey: Key.gifHotKeyCode) as? Int) ?? 5) } // ANSI G
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.gifHotKeyCode) }
    }

    var gifHotKeyModifiers: UInt32 {
        get { UInt32((UserDefaults.standard.object(forKey: Key.gifHotKeyModifiers) as? Int) ?? (optionKey | shiftKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.gifHotKeyModifiers) }
    }

    var gifFramesPerSecond: Int {
        get { min(30, max(1, UserDefaults.standard.object(forKey: Key.gifFramesPerSecond) as? Int ?? 15)) }
        set { UserDefaults.standard.set(min(30, max(1, newValue)), forKey: Key.gifFramesPerSecond) }
    }

    var gifQuality: GIFQuality {
        get { GIFQuality(rawValue: UserDefaults.standard.string(forKey: Key.gifQuality) ?? "standard") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.gifQuality) }
    }

    var gifShowsCursor: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.gifShowsCursor) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Key.gifShowsCursor)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.gifShowsCursor) }
    }

    var saveFormat: String {
        get { UserDefaults.standard.string(forKey: Key.saveFormat) ?? "png" }
        set { UserDefaults.standard.set(newValue, forKey: Key.saveFormat) }
    }

    var defaultDriver: String {
        get { UserDefaults.standard.string(forKey: Key.defaultDriver) ?? "manual" }
        set { UserDefaults.standard.set(newValue, forKey: Key.defaultDriver) }
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
