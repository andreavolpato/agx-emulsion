//  CropSection.swift — aspect, straighten, quarter turns, flips.
//
//  Placed after Camera, and in the *left* panel, because the frame's geometry
//  is a camera-side decision: format, then what part of the frame the picture
//  actually is. It is not Layer 1 (it reaches no engine parameter today) and
//  it is not Layer 2 (it is not an adjustment to a scan) — it is upstream of
//  both, which is also why it is the first thing `Exporter` applies after the
//  print comes back.
//
//  Every control here goes through a `Geometry` method that returns something
//  already fitted to the frame, so nothing in this file can produce a crop
//  with a corner hanging outside the image. That is the "fallback": drag the
//  angle to 45° on a full-frame crop and it shrinks to what still fits,
//  visibly, rather than exporting a picture with transparent triangles in it.

import SwiftUI

struct CropSection: View {
    @Bindable var session: Session

    private var size: CGSize { session.sourceImageSize }
    private var g: Geometry { session.geometry }

    var body: some View {
        PanelSection("Crop", systemImage: "crop", key: "crop", menu: { AnyView(menu) }) {
            Well {
                VStack(spacing: 4) {
                    PillMenu(label: "Aspect", options: CropAspect.allCases, title: { $0.label },
                             selection: Binding(get: { g.aspect },
                                                set: { a in
                                                    var next = g
                                                    next.aspect = a
                                                    session.geometry = next.constrained(in: size)
                                                }))
                    // Scrubbed through `scrubStraighten`, not written straight
                    // to `geometry`: a scrub is a stream of writes and the
                    // canvas must not rescale under it. The refit happens once,
                    // on `onCommit` — the release, or the typed value.
                    ScrubSlider(label: "Straighten", sublabel: "degrees",
                                value: Binding(get: { g.angle },
                                               set: { session.scrubStraighten(to: $0) }),
                                range: -Geometry.maxAngle...Geometry.maxAngle, snap: 1,
                                format: { String(format: "%+.1f°", $0) },
                                onCommit: { session.straightenScrubEnded() })
                    turnsRow
                    Text(dimensions)
                        .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Quarter turns and flips. These are exact — a 90° turn resamples
    /// nothing — which is why they are buttons rather than part of the
    /// straighten slider's range.
    private var turnsRow: some View {
        HStack(spacing: 0) {
            Text("Rotate").font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            HStack(spacing: 6) {
                glyph("rotate.left", "Rotate left (⌥⌘[)") { session.geometry = g.turned(by: -1) }
                glyph("rotate.right", "Rotate right (⌥⌘])") { session.geometry = g.turned(by: 1) }
                glyph("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally",
                      active: g.flipH) { var n = g; n.flipH.toggle(); session.geometry = n }
                glyph("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically",
                      active: g.flipV) { var n = g; n.flipV.toggle(); session.geometry = n }
                Spacer()
            }
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func glyph(_ name: String, _ help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// What the crop actually costs, in the units a photographer cares about.
    /// A 12° straighten on a full frame is not free and this is where that
    /// shows: the number goes down as the angle goes up.
    private var dimensions: String {
        guard session.sourceLongEdge > 0, size.width > 1 else { return "—" }
        let scale = session.sourceLongEdge / max(size.width, size.height)
        let out = g.outputSize(for: size)
        let w = Int((out.width * scale).rounded()), h = Int((out.height * scale).rounded())
        let mp = Double(w * h) / 1_000_000
        return g.isIdentity ? "\(w) × \(h)  ·  full frame"
                            : String(format: "%d × %d  ·  %.1f MP", w, h, mp)
    }

    private var menu: some View {
        Group {
            Button("Reset crop") { session.geometry = .default }
            Button("Straighten to 0°") { session.geometry = g.straightened(to: 0, in: size) }
            Divider()
            Button("Crop to whole frame") {
                var n = g
                n.crop = .full
                n.angle = 0
                // The whole frame is not a size anyone chose — it is the
                // absence of one, so the next straighten treats it as
                // maximal-fit again instead of pinning it to 1×1.
                n.intendedSize = nil
                session.geometry = n
            }
        }
    }
}
