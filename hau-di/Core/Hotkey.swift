import Foundation

// Cod portabil (fara AppKit): se compileaza si se testeaza si pe Linux.

/// O tasta modificatoare fizica ce poate face parte din combinatia de dictare.
public enum ModifierKey: String, Codable, CaseIterable, Hashable, Sendable {
    case function
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    public enum Family: String, Codable, CaseIterable, Hashable, Sendable {
        case function, control, option, shift, command

        /// Ordinea Apple de afisare: fn ⌃ ⌥ ⇧ ⌘
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

        /// Masca independenta de parte (CGEventFlags.maskControl etc.)
        public var flagMask: UInt64 {
            switch self {
            case .function: return 0x0080_0000 // maskSecondaryFn
            case .control: return 0x0004_0000  // maskControl
            case .option: return 0x0008_0000   // maskAlternate
            case .shift: return 0x0002_0000    // maskShift
            case .command: return 0x0010_0000  // maskCommand
            }
        }

        /// Tasta folosita cand evenimentul nu ne spune partea (stanga/dreapta).
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

    /// Codul virtual macOS (kVK_*) al tastei.
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

    /// Bitul dependent de dispozitiv din CGEventFlags (NX_DEVICE*KEYMASK din IOKit).
    /// Pentru fn nu exista bit pe parte, se foloseste maskSecondaryFn.
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

    /// Calculeaza setul de modificatori apasati din flag-urile brute ale unui eveniment.
    /// `changedKeyCode` (tasta care a generat evenimentul flagsChanged) ajuta cand
    /// tastatura nu raporteaza bitii stanga/dreapta (ex: unele tastaturi externe / remote desktop).
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
        // Daca familia nu mai e activa, eliminam bitii dependenti ramasi (unele drivere nu ii curata).
        result = result.filter { (flags & $0.family.flagMask) != 0 }
        return result
    }
}

/// Combinatia de taste tinuta apasat pentru dictare (doar modificatori, inclusiv fn).
public struct Hotkey: Codable, Hashable, Sendable {
    public var keys: Set<ModifierKey>
    /// true = conteaza partea (ex: doar ⌥ din dreapta). false = orice ⌥.
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

    /// Combinatia e tinuta exact (fara alti modificatori).
    public func isExactlyHeld(_ pressed: Set<ModifierKey>) -> Bool {
        guard isValid else { return false }
        if sideSpecific { return pressed == keys }
        return Set(pressed.map(\.family)) == families
    }

    /// Toate tastele combinatiei sunt tinute (posibil si altele).
    public func isFullyHeld(in pressed: Set<ModifierKey>) -> Bool {
        guard isValid else { return false }
        if sideSpecific { return keys.isSubset(of: pressed) }
        return families.isSubset(of: Set(pressed.map(\.family)))
    }

    /// Macar o tasta din combinatie e tinuta.
    public func overlaps(_ pressed: Set<ModifierKey>) -> Bool {
        if sideSpecific { return !keys.isDisjoint(with: pressed) }
        return !families.isDisjoint(with: Set(pressed.map(\.family)))
    }

    /// Combinatie riscanta: un singur modificator "comun" (⌘/⌃/⌥/⇧) fara parte specificata
    /// sau partea stanga - se apasa constant in scurtaturi.
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

    /// Construieste combinatia dintr-o inregistrare (toate tastele apasate in timpul gestului).
    /// Daca nu e implicata nicio tasta din dreapta, consideram ca partea nu conteaza.
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

/// Evenimente emise de masina de stari a combinatiei.
public enum HotkeyEvent: Equatable, Sendable {
    /// Combinatia a fost apasata: porneste inregistrarea (push-to-talk).
    case pressBegan
    /// Combinatia a fost eliberata dupa o apasare lunga: opreste si proceseaza.
    case pressEnded
    /// Combinatia a fost folosita in alta scurtatura (s-a apasat alta tasta): renunta.
    case pressAborted
    /// Apasare prea scurta: renunta (poate deveni dublu-tap).
    case tapped
    /// Dublu-tap: inregistrare hands-free (continua dupa eliberare).
    case handsFreeStarted
    /// In modul hands-free combinatia a fost apasata din nou: opreste si proceseaza.
    case handsFreeStopRequested
}

/// Masina de stari pura pentru push-to-talk + dublu-tap hands-free.
/// Primeste setul de modificatori apasati si apasarile de taste obisnuite, cu timestamp.
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
    /// Sub acest prag, apasarea e considerata "tap" (nu dictare).
    public var tapThreshold: TimeInterval
    /// Fereastra in care al doilea tap activeaza hands-free.
    public var doubleTapWindow: TimeInterval
    /// Cat timp de la apasare o alta tasta (sau alt modificator) inseamna o scurtatura (ex: fn + sageti) si anuleaza
    /// dictarea. Dupa aceea, o tasta apasata din greseala, sau ca sa opresti screensaver-ul, nu mai pierde inregistrarea.
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
                // S-a adaugat alt modificator: la inceput e alta scurtatura; dupa fereastra il ignoram.
                guard time - since < shortcutWindow else { return [] }
                state = .waitingForRelease
                return [.pressAborted]
            }
            // Cel putin o tasta din combinatie a fost eliberata.
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

    /// O tasta obisnuita (non-modificator) a fost apasata.
    public mutating func keyDown(at time: TimeInterval) -> [HotkeyEvent] {
        switch state {
        case .pressed(let since):
            // Dupa fereastra scurtaturilor, dictarea continua (vezi shortcutWindow).
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

    /// Readuce masina in repaus (ex: dupa anulare cu Esc).
    public mutating func reset() {
        state = hotkey.overlaps(pressed) ? .waitingForRelease : .idle
    }

    public mutating func updateConfiguration(hotkey: Hotkey, handsFreeEnabled: Bool) {
        self.hotkey = hotkey
        self.handsFreeEnabled = handsFreeEnabled
        reset()
    }
}

/// Inregistreaza o combinatie noua: retine toate tastele apasate pana se elibereaza totul.
public struct HotkeyCapture: Sendable {
    public private(set) var collected: Set<ModifierKey> = []

    public init() {}

    /// Returneaza combinatia cand toate tastele au fost eliberate.
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
