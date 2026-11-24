import Foundation

/// Geometria logo-ului (datele formei sunt in BrandMark.swift, exclus din GPL), centrata in origine, cu y in jos.
/// Doua bucle simetrice; fiecare e un sector de elipsa (peretele) din care se scade un sector mai mic (golul).
/// Iconul din bara, unda din pastila si iconul aplicatiei o deseneaza din liniute verticale.
public enum LogoGeometry {
    /// Sectorul din dreapta: din centru pana la elipsa, intre bratele y = ±x·tipY/tipX. Stanga e oglindit.
    public struct Sector: Sendable {
        public let rx: Double
        public let ry: Double
        /// Capatul bratului, unde linia din centru intalneste elipsa.
        public let tipX: Double
        public let tipY: Double

        /// Unghiul parametric al capatului bratului pe elipsa (x = rx·cos t, y = ry·sin t).
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

    /// Punctul e in forma plina (perete), nu in gol si nu in afara.
    public static func contains(x: Double, y: Double) -> Bool {
        let ax = abs(x)
        return outer.contains(x: ax, y: y) && !hole.contains(x: ax, y: y)
    }

    /// Liniutele verticale, de la stanga la dreapta: intervale [x0, x1] in unitatile logo-ului.
    /// `ratio` = latimea liniutei din pas (0,3 = 30%).
    public static func stripes(count: Int, ratio: Double) -> [ClosedRange<Double>] {
        guard count > 0 else { return [] }
        let pitch = width / Double(count)
        let stripeWidth = pitch * ratio
        return (0..<count).map { index in
            let x0 = -halfWidth + Double(index) * pitch + (pitch - stripeWidth) / 2
            return x0...(x0 + stripeWidth)
        }
    }

    // MARK: - Rombul din „cx.ro”

    /// Latime / inaltime.
    public static let rhombusAspect = BrandMark.rhombusAspect
    /// Conturul rombului normalizat: centrat in origine, inaltime 1, y in jos; curbe patratice.
    public static let rhombusStart = BrandMark.rhombusStart
    public static let rhombusCurves = BrandMark.rhombusCurves

    // MARK: - Iconul din bara de meniu

    /// Aliniat la pixelii de pe Retina (2x): liniute de 1 px la pas de 3 px, rombul de 17 px.
    public enum MenuBar {
        public static let stripeCount = 19
        /// 1 px liniuta din 3 px pas.
        public static let stripeRatio = 1.0 / 3.0
        /// Pasul liniutelor, in puncte (3 px pe 2x).
        public static let pitch = 1.5
        public static var width: Double { Double(stripeCount) * pitch }
        public static let height = 15.0
        /// Rombul colorat: 8,5 pt = 17 px pe 2x (~55% din inaltimea logo-ului).
        public static let rhombusHeight = 8.5
        /// Spatiul gol din jurul rombului; ramane constant, nu creste odata cu rombul.
        public static let gap = 1.0

        /// Puncte per unitate de logo.
        public static var scale: Double { width / LogoGeometry.width }
        public static var center: (x: Double, y: Double) { (width / 2, height / 2) }
        /// Cat se mareste rombul ca sa decupeze golul din liniute (gol perpendicular pe laturi = `gap`).
        public static var haloScale: Double { 1 + gap * 2.0.squareRoot() / (rhombusHeight / 2) }

        /// Liniutele in puncte: (x, latime), de la stanga la dreapta.
        public static var stripes: [(x: Double, width: Double)] {
            LogoGeometry.stripes(count: stripeCount, ratio: stripeRatio).map { range in
                (x: center.x + range.lowerBound * scale, width: (range.upperBound - range.lowerBound) * scale)
            }
        }
    }
}

/// Culorile din cx-ro-logo.svg (HSL). Pe fundal deschis, logo-ul foloseste aceeasi nuanta cu +16% luminozitate.
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

    /// Luminozitatea adaugata pe fundal deschis (gri ramane la fel).
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
