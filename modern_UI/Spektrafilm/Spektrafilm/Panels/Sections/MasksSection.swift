//  MasksSection.swift — the mask list, and the sublayer inside it.
//
//  ## Why the right panel
//
//  `HANDOFF-MASKS.md` §3.1 argued for the *left* panel: a mask's value was
//  exposure in stops, and the physically correct place to apply it is the
//  enlarger, which is Layer 1. That followed from the dodge-and-burn model,
//  which the user rejected. On Lightroom's model a mask carries a set of
//  adjustments, it runs in the Layer 2 kernel, it costs under a millisecond
//  and it reaches no service — so it belongs in the Layer 2 column, and
//  putting it on the left would say the opposite of what it does. The panel a
//  control sits in *is* its layer, and that rule is worth more than the
//  earlier argument for breaking it.
//
//  ## The sublayer
//
//  Selecting a mask opens a second level *inside* the section: the mask's
//  components, then the mask's own adjustments. It is inset, it carries an
//  accent rail down its leading edge, and its header is the mask's name.
//  Those three things together are what stop the local Exposure slider
//  reading as another global one — which is the single way this interface can
//  mislead, because the sliders are otherwise identical to the ones two
//  sections above.
//
//      ▽ ⬚ Masks                                    •••
//      ┌────────────────────────────────────────────┐
//      │  ◉  Sky              Linear Gradient   👁 ⌫ │   ← the list
//      │  ○  Her face         Radial Gradient   👁 ⌫ │
//      ├─┬──────────────────────────────────────────┤
//      │▌│  Sky                        overlay  ⊘    │   ← the sublayer
//      │▌│  ┌ components ───────────────────────┐   │
//      │▌│  │ + Linear Gradient      invert  ⌫  │   │
//      │▌│  │ − Luminance Range      invert  ⌫  │   │
//      │▌│  └───────────────────────────────────┘   │
//      │▌│  Amount ──────●────                      │
//      │▌│  Exposure ───●──────  Contrast ──●─────  │
//      └─┴──────────────────────────────────────────┘

import SwiftUI

struct MasksSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection("Masks", systemImage: "theatermasks", key: "masks",
                     initiallyExpanded: false, menu: { AnyView(menu) }) {
            VStack(spacing: 6) {
                Well(vertical: 6) {
                    if session.masks.isEmpty {
                        Text("No masks. Add one from ••• — or ⇧M.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(session.masks) { m in row(m) }
                        }
                    }
                }
                if let selected = session.selectedMask { Sublayer(session: session, mask: selected) }
            }
        }
    }

    private func row(_ m: EditMask) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Theme.text, lineWidth: 1)
                .background(Circle().fill(m.id == session.selectedMaskID ? Theme.text : .clear))
                .frame(width: 7, height: 7)
            Text(m.name).font(Theme.Font.listItem).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(m.summary).font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
            Button {
                var list = session.masks
                if let i = list.firstIndex(where: { $0.id == m.id }) { list[i].enabled.toggle(); session.masks = list }
            } label: {
                Image(systemName: m.enabled ? "eye" : "eye.slash")
                    .font(.system(size: 10)).foregroundStyle(m.enabled ? Theme.text : Theme.dim)
                    .frame(width: 16, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(m.enabled ? "Hide this mask" : "Show this mask")
            Button { session.deleteMask(m.id) } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .frame(width: 16, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete this mask")
        }
        .frame(height: Theme.Metric.listRowHeight)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(m.id == session.selectedMaskID ? Theme.selectionFrame : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { session.selectedMaskID = m.id }
    }

    private var menu: some View {
        Group {
            Menu("Add Mask") {
                ForEach(MasksSection.addable) { kind in
                    Button(kind.label) { session.addMask(kind) }
                }
            }
            Button("Duplicate") { if let id = session.selectedMaskID { session.duplicateMask(id) } }
                .disabled(session.selectedMaskID == nil)
            Divider()
            Toggle("Show Overlay", isOn: Binding(get: { session.maskOverlayVisible },
                                                 set: { session.maskOverlayVisible = $0 }))
            Divider()
            Button("Delete All Masks") { session.masks = []; session.selectedMaskID = nil }
                .disabled(session.masks.isEmpty)
        }
    }

    /// `brush` is in the model and in the shader — it is component kind 4 and
    /// `MaskUniform.rasterSlice` is where its texture would go — but nothing
    /// rasterises strokes yet, so offering it would offer a mask that does
    /// nothing. It is deliberately not in this list until it does.
    static let addable: [MaskComponentKind] = [.linearGradient, .radialGradient, .luminanceRange, .colorRange]
}

// MARK: - the sublayer

private struct Sublayer: View {
    @Bindable var session: Session
    let mask: EditMask

    private func update(_ change: (inout EditMask) -> Void) {
        var m = mask
        change(&m)
        session.selectedMask = m
    }

    var body: some View {
        HStack(spacing: 0) {
            // The rail. One accent line down the leading edge is what makes
            // the whole block read as one level in rather than as a sixth
            // section of the panel.
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.accent)
                .frame(width: 2)
                .padding(.vertical, 8)
            VStack(spacing: 5) {
                header
                components
                ScrubSlider(label: "Amount",
                            value: Binding(get: { mask.amount * 100 },
                                           set: { v in update { $0.amount = v / 100 } }),
                            range: 0...100, snap: 5, format: { String(format: "%.0f %%", $0) })
                Divider().overlay(Theme.dim.opacity(0.4)).padding(.vertical, 2)
                adjustments
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .padding(.vertical, 8)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Metric.wellRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.wellRadius, style: .continuous)
                .strokeBorder(Theme.dim.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.Metric.wellInset)
    }

    private var header: some View {
        HStack(spacing: 6) {
            TextField("", text: Binding(get: { mask.name }, set: { n in update { $0.name = n } }))
                .textFieldStyle(.plain)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            toggle("circle.lefthalf.filled", "Invert the whole mask", on: mask.inverted) {
                update { $0.inverted.toggle() }
            }
            toggle(session.maskOverlayVisible ? "eye.trianglebadge.exclamationmark" : "eye.slash",
                   session.maskOverlayVisible ? "Hide the red overlay" : "Show the red overlay",
                   on: session.maskOverlayVisible) { session.maskOverlayVisible.toggle() }
        }
    }

    private var components: some View {
        VStack(spacing: 3) {
            ForEach(mask.components) { c in
                HStack(spacing: 5) {
                    // The first component has nothing to subtract from, so
                    // its chip is a label rather than a control — the same
                    // rule `Mask.swift` packs and the shader applies.
                    let first = mask.components.first?.id == c.id
                    Button {
                        guard !first else { return }
                        update { m in
                            if let i = m.components.firstIndex(where: { $0.id == c.id }) { m.components[i].subtract.toggle() }
                        }
                    } label: {
                        Text(first ? "+" : (c.subtract ? "−" : "+"))
                            .font(Theme.Font.tab)
                            .foregroundStyle(first ? Theme.dim : Theme.text)
                            .frame(width: 14, height: 14)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: 3))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(first ? "The first component is what the mask starts from" : "Add to / subtract from the mask")

                    Image(systemName: c.kind.systemImage).font(.system(size: 9)).foregroundStyle(Theme.dim)
                    Text(c.kind.label).font(Theme.Font.sublabel).foregroundStyle(Theme.text).lineLimit(1)
                    if !c.summary.isEmpty {
                        Text(c.summary).font(Theme.Font.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 2)
                    toggle("arrow.left.arrow.right", "Invert this component", on: c.inverted, size: 9) {
                        update { m in
                            if let i = m.components.firstIndex(where: { $0.id == c.id }) { m.components[i].inverted.toggle() }
                        }
                    }
                    Button {
                        update { m in m.components.removeAll { $0.id == c.id } }
                    } label: {
                        Image(systemName: "delete.left").font(.system(size: 9)).foregroundStyle(Theme.dim)
                            .frame(width: 14, height: 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Remove this component")
                }
                .frame(height: 16)
                // A component with parameters that are not draggable on the
                // canvas needs them here; the geometric ones are dragged.
                if c.kind == .luminanceRange { rangeControls(c) }
                if c.kind == .colorRange { colorControls(c) }
                if c.kind.hasHandles { featherControl(c) }
            }
            Menu {
                ForEach(MasksSection.addable) { kind in
                    Button(kind.label) {
                        update { m in
                            guard m.components.count < EditMask.maxComponents else { return }
                            m.components.append(.make(kind))
                        }
                    }
                }
            } label: {
                Text("Add component").font(Theme.Font.caption).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .disabled(mask.components.count >= EditMask.maxComponents)
        }
        .padding(6)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 6))
    }

    private func rangeControls(_ c: MaskComponent) -> some View {
        VStack(spacing: 2) {
            component(c, "Low", \.low, 0...1) { String(format: "%.0f %%", $0 * 100) }
            component(c, "High", \.high, 0...1) { String(format: "%.0f %%", $0 * 100) }
            component(c, "Softness", \.softness, 0.001...0.5) { String(format: "%.0f %%", $0 * 100) }
        }
        .padding(.leading, 18)
    }

    private func colorControls(_ c: MaskComponent) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("Colour").font(Theme.Font.sublabel).foregroundStyle(Theme.text)
                    .frame(width: Theme.Metric.sliderLabelWidth - 18, alignment: .leading)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: c.color.x, green: c.color.y, blue: c.color.z))
                    .frame(width: 22, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.dim, lineWidth: 0.5))
                Button {
                    session.maskColorPick = c.id
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 10))
                        .foregroundStyle(session.maskColorPick == c.id ? Theme.accent : Theme.text)
                        .frame(width: 16, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Pick the colour from the canvas")
                Spacer()
            }
            .frame(height: Theme.Metric.rowHeight)
            component(c, "Tolerance", \.tolerance, 0.01...1) { String(format: "%.0f %%", $0 * 100) }
        }
        .padding(.leading, 18)
    }

    private func featherControl(_ c: MaskComponent) -> some View {
        component(c, "Feather", \.feather, 0...1) { String(format: "%.0f %%", $0 * 100) }
            .padding(.leading, 18)
    }

    private func component(_ c: MaskComponent, _ label: String, _ key: WritableKeyPath<MaskComponent, Double>,
                           _ range: ClosedRange<Double>, _ format: @escaping (Double) -> String) -> some View {
        ScrubSlider(label: label,
                    value: Binding(get: { c[keyPath: key] },
                                   set: { v in
                                       update { m in
                                           if let i = m.components.firstIndex(where: { $0.id == c.id }) {
                                               m.components[i][keyPath: key] = v
                                           }
                                       }
                                   }),
                    range: range, snap: (range.upperBound - range.lowerBound) / 20, format: format)
    }

    /// The mask's own tone controls. Deliberately the same set, the same
    /// ranges and the same arithmetic as the global panel two sections above
    /// — `Layer2Uniforms.tone` is shared — so "+1 stop" means one stop
    /// wherever it was typed. What is absent is as deliberate: no curves, no
    /// colour balance, no vignette.
    private var adjustments: some View {
        VStack(spacing: 4) {
            slider("Exposure", \.exposure, -3...3, 1.0 / 3) { String(format: "%+.2f", $0) }
            slider("Contrast", \.contrast, -50...50, 5) { String(format: "%+.0f", $0) }
            slider("Brightness", \.brightness, -50...50, 5) { String(format: "%+.0f", $0) }
            slider("Saturation", \.saturation, -100...100, 5) { String(format: "%+.0f", $0) }
            slider("Highlights", \.highlights, -100...100, 5) { String(format: "%+.0f", $0) }
            slider("Shadows", \.shadows, -100...100, 5) { String(format: "%+.0f", $0) }
            slider("Black", \.blackPoint, 0...50, 1) { String(format: "%.0f", $0) }
            slider("White", \.whitePoint, 0...50, 1) { String(format: "%.0f", $0) }
            slider("Temp.", \.temperature, -100...100, 5) { String(format: "%+.0f", $0) }
            slider("Tint", \.tint, -100...100, 5) { String(format: "%+.0f", $0) }
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<MaskAdjustments, Double>,
                        _ range: ClosedRange<Double>, _ snap: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        ScrubSlider(label: label,
                    value: Binding(get: { mask.adjustments[keyPath: key] },
                                   set: { v in update { $0.adjustments[keyPath: key] = v } }),
                    range: range, snap: snap, format: format)
    }

    private func toggle(_ image: String, _ help: String, on: Bool, size: CGFloat = 11,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: size))
                .foregroundStyle(on ? Theme.accent : Theme.dim)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}
