import AppKit
import SwiftUI

/// The current state, with the same color in the menu bar rhombus and in the rhombus of the bottom pill.
enum StatusTint: Hashable {
    case idle
    case recording
    case transcribing
    case correcting
    case inserting

    /// nil = idle: the icon is a template (white/black, like the other icons in the menu bar).
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

/// The menu bar icon: the striped logo (in the menu bar color); while hau-di is working, the middle rhombus
/// also appears, in the state color. When idle it is only the shape.
@MainActor
enum MenuBarIcon {
    private static var cache: [StatusTint: NSImage] = [:]

    static func image(for tint: StatusTint) -> NSImage {
        if let cached = cache[tint] { return cached }
        let layout = LogoGeometry.MenuBar.self
        let tone = tint.tone
        // Dynamic colors: resolved at draw time, based on the menu bar theme (light / dark).
        // When idle the image is a template (black, no rhombus), and macOS itself colors it white or black.
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
