import Foundation
import CoreGraphics
import SwiftUI

/// Shared wheel geometry. Math coordinates: origin at the wheel centre, y up, angles counter-clockwise from +x
/// (the same space as a non-flipped NSView). SwiftUI drawing flips y; AppKit hit testing uses it as is.
struct WheelGeometry: Equatable {
    static let pageSize = 18
    static let singleRingMax = 10

    struct Sector: Equatable {
        var index: Int          // index into the full item list
        var ring: Int
        var lo: CGFloat         // radians, lo < hi
        var hi: CGFloat
        var innerRadius: CGFloat
        var outerRadius: CGFloat
        var mid: CGFloat { (lo + hi) / 2 }
        var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
    }

    let size: CGFloat
    let count: Int
    let page: Int
    private(set) var pageCount = 1
    private(set) var sectors: [Sector] = []
    private(set) var hubRadius: CGFloat = 0
    private(set) var discRadius: CGFloat = 0
    let gap: CGFloat

    var radius: CGFloat { size / 2 }
    var ringCount: Int { (sectors.map(\.ring).max() ?? -1) + 1 }

    init(count: Int, page: Int, size: CGFloat) {
        self.size = size; self.count = count
        let R = size / 2
        pageCount = max(1, (count + WheelGeometry.pageSize - 1) / WheelGeometry.pageSize)
        self.page = min(max(0, page), pageCount - 1)
        discRadius = R * 0.97
        gap = max(3, size * 0.016)
        let start = self.page * WheelGeometry.pageSize
        let n = min(WheelGeometry.pageSize, max(0, count - start))
        guard n > 0 else { hubRadius = R * 0.36; return }
        let rings: [(Int, CGFloat, CGFloat)]
        if n <= WheelGeometry.singleRingMax {
            hubRadius = R * 0.36
            rings = [(n, R * 0.42, R * 0.88)]
        } else {
            hubRadius = R * 0.25
            let inner = max(4, min(8, Int((Double(n) * 0.4).rounded())))
            rings = [(inner, R * 0.29, R * 0.56), (n - inner, R * 0.59, R * 0.90)]
        }
        var next = start
        for (ringIndex, ring) in rings.enumerated() {
            let (m, rIn, rOut) = ring
            guard m > 0 else { continue }
            let step = 2 * CGFloat.pi / CGFloat(m)
            for j in 0..<m {
                let center = CGFloat.pi / 2 - CGFloat(j) * step
                sectors.append(Sector(index: next, ring: ringIndex, lo: center - step / 2, hi: center + step / 2,
                                      innerRadius: rIn, outerRadius: rOut))
                next += 1
            }
        }
    }

    /// Item index under a point in view coordinates (non-flipped, origin bottom-left). The whole angular share
    /// of a sector counts, so the thin gaps never act as dead zones.
    func sectorIndex(at point: CGPoint) -> Int? {
        let dx = point.x - size / 2, dy = point.y - size / 2
        let r = hypot(dx, dy)
        guard r > hubRadius else { return nil }
        var angle = atan2(dy, dx)
        for s in sectors {
            let rIn = s.ring == 0 ? hubRadius : s.innerRadius - gap / 2
            let rOut = s.outerRadius + (s.outerRadius >= radius * 0.85 ? radius * 0.07 : gap / 2)
            guard r >= rIn, r <= rOut else { continue }
            // normalise the angle into [lo, lo + 2pi)
            while angle < s.lo { angle += 2 * .pi }
            while angle >= s.lo + 2 * .pi { angle -= 2 * .pi }
            if angle <= s.hi { return s.index }
        }
        return nil
    }
    func inHub(_ point: CGPoint) -> Bool { hypot(point.x - size / 2, point.y - size / 2) <= hubRadius }
    func sector(forIndex index: Int) -> Sector? { sectors.first(where: { $0.index == index }) }

    /// Rounded annular sector in math coordinates around the origin. Radial gaps are applied as an angular inset
    /// at the sector's mid radius; corners are true tangent arcs.
    func path(for s: Sector, grow: CGFloat = 0) -> CGPath {
        let rIn = s.innerRadius - grow, rOut = s.outerRadius + grow
        let inset = (gap / 2) / max(1, s.midRadius)
        let lo = s.lo + inset, hi = s.hi - inset
        let c = max(1, min(size * 0.028, (rOut - rIn) / 3))
        let dOut = asin(c / (rOut - c)), dIn = asin(c / (rIn + c))
        func p(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: r * cos(a), y: r * sin(a)) }
        let footOut = sqrt((rOut - c) * (rOut - c) - c * c)
        let footIn = sqrt((rIn + c) * (rIn + c) - c * c)
        let path = CGMutablePath()
        path.move(to: p(footOut, lo))
        path.addArc(center: p(rOut - c, lo + dOut), radius: c, startAngle: lo - .pi / 2, endAngle: lo + dOut, clockwise: false)
        path.addArc(center: .zero, radius: rOut, startAngle: lo + dOut, endAngle: hi - dOut, clockwise: false)
        path.addArc(center: p(rOut - c, hi - dOut), radius: c, startAngle: hi - dOut, endAngle: hi + .pi / 2, clockwise: false)
        path.addLine(to: p(footIn, hi))
        path.addArc(center: p(rIn + c, hi - dIn), radius: c, startAngle: hi + .pi / 2, endAngle: hi - dIn + .pi, clockwise: false)
        path.addArc(center: .zero, radius: rIn, startAngle: hi - dIn, endAngle: lo + dIn, clockwise: true)
        path.addArc(center: p(rIn + c, lo + dIn), radius: c, startAngle: lo + dIn + .pi, endAngle: lo + 1.5 * .pi, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// SwiftUI shape drawing one sector; flips the math-space path into SwiftUI's y-down space.
struct WheelSectorShape: Shape {
    var geometry: WheelGeometry
    var sector: WheelGeometry.Sector
    var grow: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: 1, y: -1)
        guard let moved = geometry.path(for: sector, grow: grow).copy(using: &t) else { return Path() }
        return Path(moved)
    }
}
