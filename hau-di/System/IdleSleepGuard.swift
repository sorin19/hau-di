import Foundation
import IOKit.pwr_mgt

/// Cat timp se inregistreaza, Mac-ul nu porneste screensaver-ul si nu stinge ecranul (ca un player video).
/// O tasta tinuta apasata nu conteaza ca activitate: fara asta, dupa intervalul din setarile sistemului
/// screensaver-ul pornea in mijlocul dictarii. Setarile utilizatorului raman neatinse; cand se elibereaza tastele
/// (un eveniment de tastatura), numaratoarea pentru screensaver o ia de la zero, ca dupa orice apasare.
@MainActor
final class IdleSleepGuard {
    private var assertion: IOPMAssertionID = 0
    private var active = false

    func begin() {
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "hau-di: dictation in progress" as CFString,
                                                 &assertion)
        active = result == kIOReturnSuccess
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertion)
        active = false
    }
}
