import AppKit
import SwiftUI

/// Starea curenta, cu aceeasi culoare in rombul din bara de meniu si in rombul din pastila de jos.
enum StatusTint: Hashable {
    case idle
    case recording
    case transcribing
    case correcting
    case inserting

    /// nil = repaus: iconul e sablon (alb/negru, ca restul iconurilor din bara).
    var tone: BrandTone? {
        switch self {
        case .idle: return nil
        case .recording: return .red
        case .transcribing: return .green
        case .correcting: return .orange
        case .inserting: return .purple
        }
    }
}

/// Iconul din bara de meniu: logo-ul din liniute (in culoarea barii); cand hau-di lucreaza, apare si rombul
/// din mijloc, in culoarea starii. In repaus e doar forma.
@MainActor
enum MenuBarIcon {
    private static var cache: [StatusTint: NSImage] = [:]

    static func image(for tint: StatusTint) -> NSImage {
        if let cached = cache[tint] { return cached }
        let layout = LogoGeometry.MenuBar.self
        let tone = tint.tone
        // Culori dinamice: se rezolva la desenare, dupa tema barii (deschisa / inchisa).
        // In repaus imaginea e sablon (negru, fara romb), iar macOS o coloreaza singur in alb sau negru.
        let stripeColor: NSColor = tone == nil ? .black : .labelColor
        let rhombusColor: NSColor? = tone?.adaptiveNSColor
        let image = NSImage(size: NSSize(width: layout.width, height: layout.height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            BrandArt.drawMenuBarLogo(in: context, stripeColor: stripeColor, rhombusColor: rhombusColor)
            return true
        }
        image.isTemplate = tone == nil
        image.accessibilityDescription = "hau-di"
        cache[tint] = image
        return image
    }
}
