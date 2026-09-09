//  CurveMath.swift — the tone curve as data, with no view code in it.
//
//  A curve is a sorted list of control points in the unit square. The
//  interpolation is a monotone cubic (Fritsch–Carlson), which is what keeps a
//  curve from overshooting between two close points — the classic
//  Catmull-Rom "S" wobble that makes a curve editor feel wrong. Sampling it to
//  a 1-D table is what the shader consumes.

import CoreGraphics
import Foundation

enum CurveChannel: String, CaseIterable, Codable, Sendable, Identifiable {
    case rgb, luma, red, green, blue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .luma: "Luma"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

struct Curve: Codable, Equatable, Sendable {
    /// Always sorted by x, always at least two points, first at x=0 and last at x=1.
    var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    static let identity = Curve()
    var isIdentity: Bool { points == Curve.identity.points }

    static let tableSize = 256

    /// The point index nearest to `x` within `tolerance`, or nil.
    func index(near p: CGPoint, tolerance: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, q) in points.enumerated() {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= tolerance && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best?.0
    }

    /// Insert a point, keeping the list sorted. Returns its index.
    @discardableResult
    mutating func insert(_ p: CGPoint) -> Int {
        let q = CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
        let i = points.firstIndex { $0.x > q.x } ?? points.count
        points.insert(q, at: i)
        return i
    }

    /// Move point `i` to `p`. End points keep their x; interior points cannot
    /// cross their neighbours (a 0.01 guard keeps the spline well-conditioned).
    mutating func move(_ i: Int, to p: CGPoint) {
        guard points.indices.contains(i) else { return }
        var q = CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
        if i == 0 { q.x = 0 } else if i == points.count - 1 { q.x = 1 } else {
            let lo = points[i - 1].x + 0.01, hi = points[i + 1].x - 0.01
            q.x = q.x.clamped(to: min(lo, hi)...max(lo, hi))
        }
        points[i] = q
    }

    mutating func remove(_ i: Int) {
        guard points.count > 2, i > 0, i < points.count - 1 else { return }
        points.remove(at: i)
    }

    /// Fritsch–Carlson monotone cubic evaluation at `x` ∈ [0, 1].
    func evaluate(_ x: CGFloat) -> CGFloat {
        let n = points.count
        if n < 2 { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }
        // Secants and tangents.
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(points[i + 1].x - points[i].x, 1e-6)
            d[i] = (points[i + 1].y - points[i].y) / dx
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        // Locate the segment.
        var i = 0
        while i < n - 2 && x > points[i + 1].x { i += 1 }
        let h = max(points[i + 1].x - points[i].x, 1e-6)
        let t = (x - points[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        let y = h00 * points[i].y + h10 * h * m[i] + h01 * points[i + 1].y + h11 * h * m[i + 1]
        return y.clamped(to: 0...1)
    }

    /// The 1-D table for the shader.
    func table(size: Int = Curve.tableSize) -> [Float] {
        (0..<size).map { Float(evaluate(CGFloat($0) / CGFloat(size - 1))) }
    }
}

struct CurveSet: Codable, Equatable, Sendable {
    var rgb = Curve.identity
    var luma = Curve.identity
    var red = Curve.identity
    var green = Curve.identity
    var blue = Curve.identity

    var isIdentity: Bool { rgb.isIdentity && luma.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }

    subscript(channel: CurveChannel) -> Curve {
        get {
            switch channel {
            case .rgb: rgb
            case .luma: luma
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .luma: luma = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// Five rows of `Curve.tableSize` floats: rgb, luma, r, g, b — the layout
    /// of the `curveTable` texture (width = tableSize, height = 5, r32Float).
    func tables() -> [Float] {
        CurveChannel.allCases.flatMap { self[$0].table() }
    }
}
