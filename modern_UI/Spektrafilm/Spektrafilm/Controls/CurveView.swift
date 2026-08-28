//  CurveView.swift — the read-only characteristic curves.
//
//  SwiftUI `Canvas` and `Path` (UI-GUIDELINE §5). No control points, no
//  dragging, no editing: these are scopes. Frontend SPEC §5.2 item 5 calls
//  this the one place in the interface that explains *why* the highlight
//  rolloff looks the way it does, which is the difference between this app
//  and a filter.
//
//  Curve data comes from the profile JSON directly — CC BY-SA, in-repo, no
//  RPC needed. Histograms come from the live negative texture via
//  MPSImageHistogram on the GPU, not a CPU loop. Neither is wired in step
//  one; the shape below is the placeholder geometry so the layout and the
//  axis labelling are settled before real data arrives.

import SwiftUI

struct CurveView: View {
    enum Kind {
        /// log H → density, with the frame's exposure histogram overlaid.
        /// Shows how much of the frame sits in the toe and the shoulder; the
        /// auto-solve EV is what positions the histogram on the curve.
        case film
        /// The paper's curve with the negative's density histogram overlaid.
        /// Print exposure translates this window along the curve.
        case paper

        var title: String { self == .film ? "film · log H → density" : "paper · density → print" }
    }

    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kind.title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(rect), with: .color(.black.opacity(0.25)))

                // Grid
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4
                    let y = size.height * CGFloat(i) / 4
                    grid.move(to: .init(x: x, y: 0)); grid.addLine(to: .init(x: x, y: size.height))
                    grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(Theme.hairline), lineWidth: 0.5)

                // Characteristic curve: toe, straight section, shoulder. The
                // shoulder is the shape the whole app is about — it is what a
                // flat gain on exported pixels cannot reproduce (API-SPEC §2
                // measured mean abs diff 0.126 for exactly that substitution).
                var curve = Path()
                let n = 64
                for i in 0...n {
                    let t = Double(i) / Double(n)
                    let d = characteristic(t)
                    let p = CGPoint(x: size.width * t, y: size.height * (1 - d))
                    i == 0 ? curve.move(to: p) : curve.addLine(to: p)
                }
                ctx.stroke(curve, with: .color(.accentColor), lineWidth: 1.2)
            }
            .frame(height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    /// A logistic stand-in with a visible toe and shoulder. Replaced by the
    /// profile's own `channel_density` table once the catalogue is read.
    private func characteristic(_ t: Double) -> Double {
        let gamma = kind == .film ? 5.0 : 7.0
        return 1.0 / (1.0 + exp(-gamma * (t - 0.5)))
    }
}
