//  CurveEditor.swift — Capture One's curve tool: channel tabs, the histogram
//  behind the curve, draggable points, input/output readout, an eyedropper.
//
//  Interaction: click on the curve adds a point, drag moves it, drag a point
//  well outside the plot (or right-click it) removes it, double-click resets
//  the channel. The plot is a `Canvas`; hit-testing is done in the unit
//  square so it is resolution-independent.

import SwiftUI

struct CurveEditor: View {
    @Bindable var session: Session
    @State private var channel: CurveChannel = .rgb
    @State private var dragging: Int? = nil
    @State private var hover: CGPoint? = nil

    private var curve: Curve {
        get { session.adjustments.curves[channel] }
    }
    private func setCurve(_ c: Curve) {
        var a = session.adjustments
        a.curves[channel] = c
        session.adjustments = a
    }

    var body: some View {
        VStack(spacing: 6) {
            tabs
            plot
                .aspectRatio(1.05, contentMode: .fit)
            readout
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(CurveChannel.allCases) { ch in
                let on = ch == channel
                Button { channel = ch } label: {
                    VStack(spacing: 4) {
                        Text(ch.title).font(Theme.Font.tab)
                            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                        Rectangle().fill(on ? Theme.accent : Theme.dim.opacity(0.5)).frame(height: on ? 1.5 : 0.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                HistogramPlot(bins: session.histogram, channels: [channel], showGrid: true, lineWidth: 1)
                Canvas { ctx, size in
                    // Diagonal reference.
                    var d = Path(); d.move(to: CGPoint(x: 0, y: size.height)); d.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(d, with: .color(Theme.dim.opacity(0.6)), lineWidth: 0.5)
                    // The curve.
                    var p = Path()
                    for i in 0...128 {
                        let x = CGFloat(i) / 128
                        let y = curve.evaluate(x)
                        let pt = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(curveColor), lineWidth: 1.5)
                    // Points.
                    for (i, q) in curve.points.enumerated() {
                        let r: CGFloat = i == dragging ? 4.5 : 3.5
                        let rect = CGRect(x: q.x * size.width - r, y: (1 - q.y) * size.height - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(rect), with: .color(Theme.plot))
                        ctx.stroke(Path(rect), with: .color(Theme.accent), lineWidth: 1.2)
                    }
                    // Hover input/output guide.
                    if let h = hover {
                        var g = Path()
                        g.move(to: CGPoint(x: h.x * size.width, y: 0)); g.addLine(to: CGPoint(x: h.x * size.width, y: size.height))
                        ctx.stroke(g, with: .color(Theme.text.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let u = unit(g.location, size)
                        if dragging == nil {
                            let tol = 10 / min(size.width, size.height)
                            if let i = curve.index(near: unitClamped(g.startLocation, size), tolerance: tol) { dragging = i }
                            else { var c = curve; dragging = c.insert(unitClamped(g.startLocation, size)); setCurve(c) }
                        }
                        if let i = dragging {
                            var c = curve
                            let outside = u.x < -0.2 || u.x > 1.2 || u.y < -0.2 || u.y > 1.2
                            if outside && i > 0 && i < c.points.count - 1 {
                                c.remove(i); dragging = nil
                            } else {
                                c.move(i, to: u)
                            }
                            setCurve(c)
                        }
                        hover = unitClamped(g.location, size)
                    }
                    .onEnded { _ in dragging = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { setCurve(.identity) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = unitClamped(p, size)
                case .ended: hover = nil
                }
            }
        }
    }

    private var curveColor: Color {
        switch channel {
        case .rgb, .luma: Theme.text
        case .red: Theme.histR
        case .green: Theme.histG
        case .blue: Theme.histB
        }
    }

    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x / size.width, y: 1 - p.y / size.height) }
    private func unitClamped(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let u = unit(p, size); return CGPoint(x: u.x.clamped(to: 0...1), y: u.y.clamped(to: 0...1))
    }

    private var readout: some View {
        HStack(spacing: 16) {
            let input: Double? = hover.map { Double($0.x) } ?? session.hoverValue.map { Double(0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z) }
            Text("Input: \(input.map { String(format: "%.0f", $0 * 255) } ?? "--")")
            Text("Output: \(input.map { String(format: "%.0f", curve.evaluate(CGFloat($0)) * 255) } ?? "--")")
            Spacer()
            Button { session.curvePickerActive.toggle() } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.curvePickerActive ? Theme.accent : Theme.text)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .help("Pick a point from the image")
        }
        .font(Theme.Font.value)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 6)
    }
}
