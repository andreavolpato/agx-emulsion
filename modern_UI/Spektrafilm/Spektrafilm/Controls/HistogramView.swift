//  HistogramView.swift — 256-bin RGB + luma, drawn with `Canvas`, from the
//  bins the renderer publishes after each Layer 2 pass.

import SwiftUI

struct HistogramPlot: View {
    /// 4 × 256 normalised bins: r, g, b, luma.
    let bins: [Float]
    var channels: Set<CurveChannel> = [.rgb]
    var showGrid = true
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            if showGrid {
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    let y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(Theme.plotGrid), lineWidth: 0.5)
            }
            guard bins.count >= 1024 else { return }
            func path(row: Int) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 {
                    let v = CGFloat(bins[row * 256 + i])
                    let x = size.width * CGFloat(i) / 255
                    let y = size.height - v * size.height * 0.96
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            let showRGB = channels.contains(.rgb)
            if showRGB || channels.contains(.luma) {
                ctx.fill(path(row: 3), with: .color(Theme.histY.opacity(0.30)))
                ctx.stroke(path(row: 3), with: .color(Theme.histY.opacity(0.7)), lineWidth: lineWidth)
            }
            let rows: [(Int, Color, CurveChannel)] = [(0, Theme.histR, .red), (1, Theme.histG, .green), (2, Theme.histB, .blue)]
            for (row, color, ch) in rows where showRGB || channels.contains(ch) {
                ctx.fill(path(row: row), with: .color(color.opacity(0.12)))
                ctx.stroke(path(row: row), with: .color(color.opacity(0.95)), lineWidth: lineWidth)
            }
        }
        .background(Theme.plot)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
