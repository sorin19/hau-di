import Foundation

/// The logo geometry (shape data in BrandMark.swift, excluded from the GPL), centered on the origin, y pointing down.
/// Two symmetric loops; each is an ellipse sector (the wall) from which a smaller sector (the hole) is subtracted.
/// The menu bar icon, the waveform in the pill and the app icon draw it with vertical stripes.
public enum LogoGeometry {
    /// The right sector: from the center to the ellipse, between the arms y = ±x·tipY/tipX. The left one is mirrored.
    public struct Sector: Sendable {
        public let rx: Double
        public let ry: Double
        /// The tip of the arm, where the line from the center meets the ellipse.
        public let tipX: Double
        public let tipY: Double

        /// The parametric angle of the arm tip on the ellipse (x = rx·cos t, y = ry·sin t).
        public var angle: Double { atan2(tipY / ry, tipX / rx) }

        func contains(x: Double, y: Double) -> Bool {
            guard x >= 0 else { return false }
            let insideArms = abs(y) * tipX <= x * tipY
            let insideEllipse = (x / rx) * (x / rx) + (y / ry) * (y / ry) <= 1
            return insideArms && insideEllipse
        }
    }

    public static let outer = Sector(rx: BrandMark.outer.rx, ry: BrandMark.outer.ry,
                                     tipX: BrandMark.outer.tipX, tipY: BrandMark.outer.tipY)
    public static let hole = Sector(rx: BrandMark.hole.rx, ry: BrandMark.hole.ry,
                                    tipX: BrandMark.hole.tipX, tipY: BrandMark.hole.tipY)

    public static let halfWidth = BrandMark.halfWidth
    public static let halfHeight = BrandMark.halfHeight
    public static var width: Double { 2 * halfWidth }
    public static var height: Double { 2 * halfHeight }

    /// The point is in the solid shape (the wall), not in the hole and not outside.
    public static func contains(x: Double, y: Double) -> Bool {
        let ax = abs(x)
        return outer.contains(x: ax, y: y) && !hole.contains(x: ax, y: y)
    }

    /// The vertical stripes, from left to right: [x0, x1] intervals in logo units.
    /// `ratio` = the stripe width as a fraction of the pitch (0.3 = 30%).
    public static func stripes(count: Int, ratio: Double) -> [ClosedRange<Double>] {
        guard count > 0 else { return [] }
        let pitch = width / Double(count)
        let stripeWidth = pitch * ratio
        return (0..<count).map { index in
            let x0 = -halfWidth + Double(index) * pitch + (pitch - stripeWidth) / 2
            return x0...(x0 + stripeWidth)
        }
    }

    // MARK: - The rhombus in "cx.ro"

    /// Width / height.
    public static let rhombusAspect = BrandMark.rhombusAspect
    /// The normalized rhombus outline: centered on the origin, height 1, y pointing down; quadratic curves.
    public static let rhombusStart = BrandMark.rhombusStart
    public static let rhombusCurves = BrandMark.rhombusCurves

    // MARK: - The menu bar icon

    /// Aligned to Retina (2x) pixels: 1 px stripes at a 3 px pitch, a 17 px rhombus.
    public enum MenuBar {
        public static let stripeCount = 19
        /// 1 px of stripe per 3 px of pitch.
        public static let stripeRatio = 1.0 / 3.0
        /// The stripe pitch, in points (3 px at 2x).
        public static let pitch = 1.5
        public static var width: Double { Double(stripeCount) * pitch }
        public static let height = 15.0
        /// The colored rhombus: 8.5 pt = 17 px at 2x (~55% of the logo height).
        public static let rhombusHeight = 8.5
        /// The empty space around the rhombus; it stays constant and does not grow with the rhombus.
        public static let gap = 1.0

        /// Points per logo unit.
        public static var scale: Double { width / LogoGeometry.width }
        public static var center: (x: Double, y: Double) { (width / 2, height / 2) }
        /// How much the rhombus grows to cut the gap out of the stripes (gap perpendicular to the sides = `gap`).
        public static var haloScale: Double { 1 + gap * 2.0.squareRoot() / (rhombusHeight / 2) }

        /// The stripes in points: (x, width), from left to right.
        public static var stripes: [(x: Double, width: Double)] {
            LogoGeometry.stripes(count: stripeCount, ratio: stripeRatio).map { range in
                (x: center.x + range.lowerBound * scale, width: (range.upperBound - range.lowerBound) * scale)
            }
        }
    }
}

/// The colors from cx-ro-logo.svg (HSL). On a light background, the logo uses the same hue with +16% lightness.
public enum BrandTone: String, CaseIterable, Sendable {
    case blue, purple, red, orange, yellow, green, gray

    public var hsl: (h: Double, s: Double, l: Double) {
        switch self {
        case .blue: return (219, 0.99, 0.53)
        case .purple: return (279, 0.67, 0.52)
        case .red: return (1, 0.99, 0.60)
        case .orange: return (34, 0.91, 0.45)
        case .yellow: return (45, 1.00, 0.57)
        case .green: return (124, 0.67, 0.47)
        case .gray: return (260, 0.01, 0.53)
        }
    }

    /// The lightness added on a light background (gray stays the same).
    public var lightBoost: Double { self == .gray ? 0 : 0.16 }

    /// sRGB 0...1.
    public func rgb(onDark: Bool) -> (r: Double, g: Double, b: Double) {
        let value = hsl
        return Self.hslToRGB(h: value.h, s: value.s, l: min(1, value.l + (onDark ? 0 : lightBoost)))
    }

    public static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let chroma = (1 - abs(2 * l - 1)) * s
        let sector = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = l - chroma / 2
        return (r + m, g + m, b + m)
    }
}
