import AppKit
import SwiftUI

// Drawings from the cx.ro logo: the shape made of stripes and the status rhombus.
// The geometry (portable, tested on Linux) is in Core/LogoGeometry.swift.

extension BrandTone {
    func nsColor(onDark: Bool) -> NSColor {
        let components = self.rgb(onDark: onDark)
        return NSColor(srgbRed: components.r, green: components.g, blue: components.b, alpha: 1)
    }

    /// An NSColor that picks its own variant based on the theme it is drawn in.
    var adaptiveNSColor: NSColor {
        NSColor(name: nil) { appearance in
            nsColor(onDark: appearance.isDark)
        }
    }

    func color(onDark: Bool) -> Color {
        Color(nsColor: nsColor(onDark: onDark))
    }

    /// Adapts to the theme of the place where it is drawn (light theme: +16% lightness, as in the logo).
    var adaptiveColor: Color {
        Color(nsColor: adaptiveNSColor)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

enum BrandArt {
    /// The filled shape of the logo (filled with the even-odd rule). `scale` = points per logo unit.
    static func logoPath(center: CGPoint, scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for sector in [LogoGeometry.outer, LogoGeometry.hole] {
            let angle = CGFloat(sector.angle)
            for side: CGFloat in [1, -1] {
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .scaledBy(x: side * CGFloat(sector.rx) * scale, y: CGFloat(sector.ry) * scale)
                path.move(to: center)
                // The arc passes through angle 0 (outward); the line from the center and the closing form the arms.
                path.addArc(center: .zero, radius: 1, startAngle: -angle, endAngle: angle, clockwise: false,
                            transform: transform)
                path.closeSubpath()
            }
        }
        return path
    }

    /// The rhombus from "cx.ro", with the given height (y pointing down, as in SVG).
    static func rhombusPath(center: CGPoint, height: CGFloat) -> CGPath {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(x) * height, y: center.y + CGFloat(y) * height)
        }
        let path = CGMutablePath()
        path.move(to: point(LogoGeometry.rhombusStart.x, LogoGeometry.rhombusStart.y))
        for curve in LogoGeometry.rhombusCurves {
            path.addQuadCurve(to: point(curve.x, curve.y), control: point(curve.cx, curve.cy))
        }
        path.closeSubpath()
        return path
    }

    /// The largest rhombus that fits in the rectangle, centered.
    static func rhombusPath(in rect: CGRect) -> CGPath {
        let height = min(rect.height, rect.width / CGFloat(LogoGeometry.rhombusAspect))
        return rhombusPath(center: CGPoint(x: rect.midX, y: rect.midY), height: height)
    }

    /// The menu bar icon: the logo's stripes in the menu bar color and, while hau-di is working, the middle rhombus
    /// in the state color (`rhombusColor` nil = idle: only the shape, no rhombus).
    /// The context must be flipped (y pointing down), with the origin at the icon's corner.
    static func drawMenuBarLogo(in context: CGContext, stripeColor: NSColor, rhombusColor: NSColor?) {
        let layout = LogoGeometry.MenuBar.self
        let center = CGPoint(x: layout.center.x, y: layout.center.y)
        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        let rhombusHeight = CGFloat(layout.rhombusHeight)

        context.saveGState()
        context.addPath(logoPath(center: center, scale: CGFloat(layout.scale)))
        context.clip(using: .evenOdd)
        if rhombusColor != nil {
            // The gap around the rhombus: the whole icon minus the enlarged rhombus.
            context.addRect(bounds)
            context.addPath(rhombusPath(center: center, height: rhombusHeight * CGFloat(layout.haloScale)))
            context.clip(using: .evenOdd)
        }
        stripeColor.setFill()
        for stripe in layout.stripes {
            context.fill(CGRect(x: stripe.x, y: 0, width: stripe.width, height: layout.height))
        }
        context.restoreGState()

        guard let rhombusColor else { return }
        rhombusColor.setFill()
        context.addPath(rhombusPath(center: center, height: rhombusHeight))
        context.fillPath()
    }
}

// MARK: - Status rhombus

enum StatusGlyph {
    case check, exclamation, info
}

struct RhombusShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(BrandArt.rhombusPath(in: rect))
    }
}

/// The sign inside the rhombus (checkmark, !, i), drawn at the rhombus's scale.
struct StatusGlyphShape: Shape {
    let glyph: StatusGlyph

    func path(in rect: CGRect) -> Path {
        let height = min(rect.height, rect.width / CGFloat(LogoGeometry.rhombusAspect))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x * height, y: center.y + y * height)
        }
        func dot(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) -> CGRect {
            let r = radius * height
            let c = point(x, y)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        var line = Path()
        var path = Path()
        switch glyph {
        case .check:
            line.move(to: point(-0.23163, 0.03061))
            line.addLine(to: point(-0.07857, 0.18367))
            line.addLine(to: point(0.21735, -0.14286))
            path.addPath(line.strokedPath(StrokeStyle(lineWidth: 0.10612 * height, lineCap: .round, lineJoin: .round)))
        case .exclamation:
            line.move(to: point(0, -0.29592))
            line.addLine(to: point(0, 0.09184))
            path.addPath(line.strokedPath(StrokeStyle(lineWidth: 0.11429 * height, lineCap: .round)))
            path.addEllipse(in: dot(0, 0.27551, radius: 0.06939))
        case .info:
            line.move(to: point(0, -0.08163))
            line.addLine(to: point(0, 0.24490))
            path.addPath(line.strokedPath(StrokeStyle(lineWidth: 0.11429 * height, lineCap: .round)))
            path.addEllipse(in: dot(0, -0.24082, radius: 0.06735))
        }
        return path
    }
}

/// The rhombus from "cx.ro" used as a status icon (pill, settings, menu).
struct StatusDiamond: View {
    var color: Color
    var glyph: StatusGlyph?
    var glyphColor: Color = .white
    var pulsing = false

    var body: some View {
        let diamond = ZStack {
            RhombusShape().fill(color)
            if let glyph {
                StatusGlyphShape(glyph: glyph).fill(glyphColor)
            }
        }
        .aspectRatio(CGFloat(LogoGeometry.rhombusAspect), contentMode: .fit)

        if pulsing {
            diamond.phaseAnimator([1.0, 0.35]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        } else {
            diamond
        }
    }
}

/// The state of a setting: gray = not set, green = set, red = error.
enum SetupStatus {
    case notSet, ok, error

    init(_ ok: Bool) {
        self = ok ? .ok : .notSet
    }

    var tone: BrandTone {
        switch self {
        case .notSet: return .gray
        case .ok: return .green
        case .error: return .red
        }
    }
}

struct SetupStatusIcon: View {
    let status: SetupStatus
    /// Pulses while work is in progress (e.g. the model is downloading).
    var busy = false
    var size: CGFloat = 16

    var body: some View {
        StatusDiamond(color: status.tone.adaptiveColor, pulsing: busy)
            .frame(width: size, height: size)
    }
}

extension TranscriptionService {
    var setupStatus: SetupStatus {
        switch state {
        case .ready: return .ok
        case .failed: return .error
        case .idle, .downloading, .preparing: return .notSet
        }
    }
}
