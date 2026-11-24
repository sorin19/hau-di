// Logo-ul cx.ro: datele formei si ale rombului din acest fisier NU fac parte din licenta GPL a proiectului.
// Copyright (C) 2026 CEXA DIGITAL SRL [CIF 35370537] (https://cx.ro). Toate drepturile rezervate. Vezi BRANDING.md.
//
// The cx.ro logo data in this file is NOT licensed under the GNU GPL (or any other license).
// Copyright (C) 2026 CEXA DIGITAL SRL [CIF 35370537] (https://cx.ro). All rights reserved. See BRANDING.md.

import Foundation

/// Datele logo-ului cx.ro (forma, fara text), in unitatile din cx-ro-logo.svg: centrat in origine, y in jos.
/// Restul codului (liniute, contur, desenare) le foloseste prin `LogoGeometry`.
public enum BrandMark {
    /// Peretele unei bucle: sector de elipsa (rx, ry), intre bratele care ajung in (tipX, tipY).
    public static let outer = (rx: 4359.0, ry: 2449.0, tipX: 1633.0, tipY: 2271.0)
    /// Golul din bucla, scazut din perete.
    public static let hole = (rx: 3376.0, ry: 1897.0, tipX: 2124.0, tipY: 1475.0)
    public static let halfWidth = 4361.0
    public static let halfHeight = 2271.0

    /// Rombul din „cx.ro”: latime / inaltime.
    public static let rhombusAspect = 1.0061
    /// Conturul rombului normalizat: centrat in origine, inaltime 1, y in jos; curbe patratice.
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
