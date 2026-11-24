import Foundation

// Portable code (no AppKit): it also compiles and is tested on Linux.

/// A physical modifier key that can be part of the dictation key combination.
public enum ModifierKey: String, Codable, CaseIterable, Hashable, Sendable {
    case function
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    public enum Family: String, Codable, CaseIterable, Hashable, Sendable {
        case function, control, option, shift, command

        /// Apple's display order: fn ⌃ ⌥ ⇧ ⌘
        var sortIndex: Int {
            switch self {
            case .function: return 0
            case .control: return 1
            case .option: return 2
            case .shift: return 3
            case .command: return 4
            }
        }

        public var symbol: String {
            switch self {
            case .function: return "fn"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        public var name: String {
            switch self {
            case .function: return "Fn (Globe)"
            case .control: return "Control"
            case .option: return "Option"
            case .shift: return "Shift"
            case .command: return "Command"
            }
        }

        /// Side-independent mask (CGEventFlags.maskControl etc.)
        public var flagMask: UInt64 {
            switch self {
            case .function: return 0x0080_0000 // maskSecondaryFn
            case .control: return 0x0004_0000  // maskControl
            case .option: return 0x0008_0000   // maskAlternate
            case .shift: return 0x0002_0000    // maskShift
            case .command: return 0x0010_0000  // maskCommand
            }
        }

        /// The key used when the event does not tell us the side (left/right).
        var defaultKey: ModifierKey {
            switch self {
            case .function: return .function
            case .control: return .leftControl
            case .option: return .leftOption
            case .shift: return .leftShift
            case .command: return .leftCommand
            }
        }
    }

    public var family: Family {
        switch self {
        case .function: return .function
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftCommand, .rightCommand: return .command
        }
    }

    public var isRightSide: Bool {
        switch self {
        case .rightControl, .rightOption, .rightShift, .rightCommand: return true
        default: return false
        }
    }

    /// The key's macOS virtual key code (kVK_*).
    public var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftCommand: return 55
        case .rightCommand: return 54
        }
    }

    /// The device-dependent bit in CGEventFlags (NX_DEVICE*KEYMASK from IOKit).
    /// fn has no per-side bit, so maskSecondaryFn is used.
    public var deviceFlagMask: UInt64 {
        switch self {
        case .function: return 0x0080_0000
        case .leftControl: return 0x0000_0001
        case .rightControl: return 0x0000_2000
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        }
    }

    public static func key(forKeyCode code: UInt16) -> ModifierKey? {
        allCases.first { $0.keyCode == code }
    }

    /// Computes the set of pressed modifiers from the raw flags of an event.
    /// `changedKeyCode` (the key that generated the flagsChanged event) helps when
    /// the keyboard does not report the left/right bits (e.g. some external keyboards / remote desktop).
    public static func pressedKeys(flags: UInt64, changedKeyCode: UInt16? = nil) -> Set<ModifierKey> {
        var result = Set<ModifierKey>()
        for key in allCases where key != .function && (flags & key.deviceFlagMask) != 0 {
            result.insert(key)
        }
        if (flags & Family.function.flagMask) != 0 {
            result.insert(.function)
        }
        for family in Family.allCases where family != .function {
            guard (flags & family.flagMask) != 0 else { continue }
            if !result.contains(where: { $0.family == family }) {
                if let code = changedKeyCode, let key = key(forKeyCode: code), key.family == family {
                    result.insert(key)
                } else {
                    result.insert(family.defaultKey)
                }
            }
        }
        // If the family is no longer active, drop the leftover device-dependent bits (some drivers do not clear them).
        result = result.filter { (flags & $0.family.flagMask) != 0 }
        return result
    }
}

/// The key combination held down to dictate (modifiers only, including fn).
public struct Hotkey: Codable, Hashable, Sendable {
    public var keys: Set<ModifierKey>
    /// true = the side matters (e.g. only the right ⌥). false = any ⌥.
    public var sideSpecific: Bool

    public init(keys: Set<ModifierKey>, sideSpecific: Bool = true) {
        self.keys = keys
        self.sideSpecific = sideSpecific
    }

    public static let fn = Hotkey(keys: [.function], sideSpecific: true)
    public static let rightOption = Hotkey(keys: [.rightOption], sideSpecific: true)
    public static let rightCommand = Hotkey(keys: [.rightCommand], sideSpecific: true)
    public static let controlOption = Hotkey(keys: [.leftControl, .leftOption], sideSpecific: false)
    public static let fnControl = Hotkey(keys: [.function, .leftControl], sideSpecific: false)
    public static let commandOption = Hotkey(keys: [.leftCommand, .leftOption], sideSpecific: false)

    public static let presets: [HotkeyPreset] = [
        HotkeyPreset(title: "fn (Globe)", hotkey: .fn),
        HotkeyPreset(title: "⌥ Right Option", hotkey: .rightOption),
        HotkeyPreset(title: "⌘ Right Command", hotkey: .rightCommand),
        HotkeyPreset(title: "⌃ Control + ⌥ Option", hotkey: .controlOption),
        HotkeyPreset(title: "fn + ⌃ Control", hotkey: .fnControl),
        HotkeyPreset(title: "⌘ Command + ⌥ Option", hotkey: .commandOption),
    ]

    public var isValid: Bool { !keys.isEmpty }

    private var families: Set<ModifierKey.Family> { Set(keys.map(\.family)) }

    /// The combination is held exactly (no other modifiers).
    public func isExactlyHeld(_ pressed: Set<ModifierKey>) -> Bool {
        guard isValid else { return false }
        if sideSpecific { return pressed == keys }
        return Set(pressed.map(\.family)) == families
    }

    /// All the keys of the combination are held (possibly others too).
    public func isFullyHeld(in pressed: Set<ModifierKey>) -> Bool {
        guard isValid else { return false }
        if sideSpecific { return keys.isSubset(of: pressed) }
        return families.isSubset(of: Set(pressed.map(\.family)))
    }

    /// At least one key of the combination is held.
    public func overlaps(_ pressed: Set<ModifierKey>) -> Bool {
        if sideSpecific { return !keys.isDisjoint(with: pressed) }
        return !families.isDisjoint(with: Set(pressed.map(\.family)))
    }

    /// Risky combination: a single "common" modifier (⌘/⌃/⌥/⇧) with no side specified
    /// or on the left side - it is pressed all the time in shortcuts.
    public var isRiskySingleModifier: Bool {
        guard keys.count == 1, let key = keys.first else { return false }
        if key == .function { return false }
        return !(sideSpecific && key.isRightSide)
    }

    public var displayString: String {
        guard isValid else { return "Not set" }
        let sorted = keys.sorted { lhs, rhs in
            if lhs.family.sortIndex != rhs.family.sortIndex { return lhs.family.sortIndex < rhs.family.sortIndex }
            return !lhs.isRightSide && rhs.isRightSide
        }
        var parts: [String] = []
        var seenFamilies = Set<ModifierKey.Family>()
        for key in sorted {
            if !sideSpecific {
                if seenFamilies.insert(key.family).inserted { parts.append(key.family.symbol) }
                continue
            }
            switch key {
            case .function: parts.append("fn")
            default: parts.append((key.isRightSide ? "Right " : "Left ") + key.family.symbol)
            }
        }
        return parts.joined(separator: sideSpecific ? " + " : "")
    }

    /// Builds the combination from a recording (all the keys pressed during the gesture).
    /// If no right-side key is involved, we assume the side does not matter.
    public static func fromRecording(_ keys: Set<ModifierKey>) -> Hotkey {
        let anyRight = keys.contains(where: \.isRightSide)
        return Hotkey(keys: keys, sideSpecific: anyRight || keys == [.function])
    }
}

public struct HotkeyPreset: Identifiable, Hashable, Sendable {
    public var id: String { title }
    public let title: String
    public let hotkey: Hotkey
}

/// Events emitted by the hotkey state machine.
public enum HotkeyEvent: Equatable, Sendable {
    /// The combination was pressed: start recording (push-to-talk).
    case pressBegan
    /// The combination was released after a long press: stop and process.
    case pressEnded
    /// The combination was used in another shortcut (another key was pressed): discard.
    case pressAborted
    /// Press too short: discard (it may become a double tap).
    case tapped
    /// Double tap: hands-free recording (continues after release).
    case handsFreeStarted
    /// In hands-free mode, the combination was pressed again: stop and process.
    case handsFreeStopRequested
}

/// Pure state machine for push-to-talk + hands-free double tap.
/// It receives the set of pressed modifiers and the regular key presses, with timestamps.
public struct HotkeyStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case pressed(since: TimeInterval)
        case awaitingSecondTap(releasedAt: TimeInterval)
        case handsFreeHeld
        case handsFree
        case waitingForRelease
    }

    public var hotkey: Hotkey
    public var handsFreeEnabled: Bool
    /// Below this threshold, the press counts as a "tap" (not dictation).
    public var tapThreshold: TimeInterval
    /// The window in which the second tap activates hands-free mode.
    public var doubleTapWindow: TimeInterval
    /// How long after the press another key (or another modifier) means a shortcut (e.g. fn + arrows) and cancels
    /// the dictation. After that, a key pressed by mistake, or to stop the screensaver, no longer loses the recording.
    public var shortcutWindow: TimeInterval

    public private(set) var state: State = .idle
    public private(set) var pressed: Set<ModifierKey> = []

    public init(hotkey: Hotkey, handsFreeEnabled: Bool = true, tapThreshold: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.4,
                shortcutWindow: TimeInterval = 1.5) {
        self.hotkey = hotkey
        self.handsFreeEnabled = handsFreeEnabled
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
        self.shortcutWindow = shortcutWindow
    }

    public mutating func modifiersChanged(_ newPressed: Set<ModifierKey>, at time: TimeInterval) -> [HotkeyEvent] {
        pressed = newPressed
        let exact = hotkey.isExactlyHeld(newPressed)
        let full = hotkey.isFullyHeld(in: newPressed)
        let overlap = hotkey.overlaps(newPressed)

        switch state {
        case .idle:
            if exact {
                state = .pressed(since: time)
                return [.pressBegan]
            }
            return []

        case .pressed(let since):
            if exact { return [] }
            if full {
                // Another modifier was added: early on it is another shortcut; after the window we ignore it.
                guard time - since < shortcutWindow else { return [] }
                state = .waitingForRelease
                return [.pressAborted]
            }
            // At least one key of the combination was released.
            if time - since < tapThreshold {
                if handsFreeEnabled {
                    state = .awaitingSecondTap(releasedAt: time)
                } else {
                    state = overlap ? .waitingForRelease : .idle
                }
                return [.tapped]
            }
            state = overlap ? .waitingForRelease : .idle
            return [.pressEnded]

        case .awaitingSecondTap(let releasedAt):
            if exact {
                if time - releasedAt <= doubleTapWindow {
                    state = .handsFreeHeld
                    return [.handsFreeStarted]
                }
                state = .pressed(since: time)
                return [.pressBegan]
            }
            if time - releasedAt > doubleTapWindow { state = .idle }
            return []

        case .handsFreeHeld:
            if !overlap { state = .handsFree }
            return []

        case .handsFree:
            if exact {
                state = .waitingForRelease
                return [.handsFreeStopRequested]
            }
            return []

        case .waitingForRelease:
            if !overlap { state = .idle }
            return []
        }
    }

    /// A regular (non-modifier) key was pressed.
    public mutating func keyDown(at time: TimeInterval) -> [HotkeyEvent] {
        switch state {
        case .pressed(let since):
            // After the shortcut window, the dictation continues (see shortcutWindow).
            guard time - since < shortcutWindow else { return [] }
            state = .waitingForRelease
            return [.pressAborted]
        case .awaitingSecondTap:
            state = .idle
            return []
        default:
            return []
        }
    }

    /// Puts the machine back to idle (e.g. after canceling with Esc).
    public mutating func reset() {
        state = hotkey.overlaps(pressed) ? .waitingForRelease : .idle
    }

    public mutating func updateConfiguration(hotkey: Hotkey, handsFreeEnabled: Bool) {
        self.hotkey = hotkey
        self.handsFreeEnabled = handsFreeEnabled
        reset()
    }
}

/// Records a new combination: collects every key pressed until everything is released.
public struct HotkeyCapture: Sendable {
    public private(set) var collected: Set<ModifierKey> = []

    public init() {}

    /// Returns the combination once all the keys have been released.
    public mutating func update(_ pressed: Set<ModifierKey>) -> Hotkey? {
        if !pressed.isEmpty {
            collected.formUnion(pressed)
            return nil
        }
        guard !collected.isEmpty else { return nil }
        defer { collected = [] }
        return Hotkey.fromRecording(collected)
    }
}
