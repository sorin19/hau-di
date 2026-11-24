// The cx.ro logo data in this file is NOT licensed under the GNU GPL (or any other license).
// Copyright (C) 2026 CEXA DIGITAL SRL [CIF 35370537] (https://cx.ro). All rights reserved. See BRANDING.md.

import Foundation

/// The cx.ro logo data (shape only, no text), in cx-ro-logo.svg units: centered on the origin, y pointing down.
/// The rest of the code (stripes, outline, drawing) uses it through `LogoGeometry`.
public enum BrandMark {
    /// The wall of a loop: an ellipse sector (rx, ry) between the arms that end at (tipX, tipY).
    public static let outer = (rx: 4359.0, ry: 2449.0, tipX: 1633.0, tipY: 2271.0)
    /// The hole in the loop, subtracted from the wall.
    public static let hole = (rx: 3376.0, ry: 1897.0, tipX: 2124.0, tipY: 1475.0)
    public static let halfWidth = 4361.0
    public static let halfHeight = 2271.0

    /// The rhombus in "cx.ro": width / height.
    public static let rhombusAspect = 1.0061
    /// The normalized rhombus outline: centered on the origin, height 1, y pointing down; quadratic curves.
    public static let rhombusStart = (x: -0.50306, y: 0.0)
    public static let rhombusCurves: [(cx: Double, cy: Double, x: Double, y: Double)] = [
        (-0.50306, -0.03061, -0.48265, -0.05306),
        (-0.46224, -0.07755, -0.43163, -0.11837),
        (-0.36224, -0.19796, -0.27245, -0.28367),
        (-0.17857, -0.37143, -0.08673, -0.45306),
        (-0.02755, -0.50000, 0.00102, -0.50000),
        (0.02755, -0.50000, 0.09082, -0.45306),
        (0.28673, -0.28571, 0.43163, -0.11837),
        (0.46224, -0.07959, 0.48265, -0.05510),
        (0.50306, -0.03061, 0.50306, 0.00000),
        (0.50306, 0.03265, 0.48061, 0.05714),
        (0.46020, 0.08163, 0.42959, 0.12449),
        (0.36020, 0.20000, 0.27041, 0.28571),
        (0.18265, 0.37143, 0.09082, 0.45306),
        (0.03163, 0.50000, 0.00102, 0.50000),
        (-0.02551, 0.50000, -0.09082, 0.45306),
        (-0.19082, 0.37143, -0.27653, 0.28571),
        (-0.36224, 0.19796, -0.43163, 0.11837),
        (-0.46224, 0.07959, -0.48265, 0.05714),
        (-0.50306, 0.03265, -0.50306, 0.00000),
    ]
}
