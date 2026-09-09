//  ScrubSlider.swift — the one slider. Label | track with a pill knob | value.
//
//  Built once and used everywhere. Drag anywhere on the track, ⌥ for ×0.25
//  sensitivity, ⇧ snaps to `snap`, double-click resets to `zero`, and the
//  value column is an editable field. `onCommit` fires on release; continuous
//  updates go through the binding while dragging.

import SwiftUI

struct ScrubSlider: View {
    let label: String
    var sublabel: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var zero: Double = 0
    var snap: Double = 0.5
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var parse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
    var trackGradient: [Color]? = nil
    var disabled = false
    var onCommit: () -> Void = {}

    @State private var dragStart: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Theme.Font.label)
                if let sublabel { Text(sublabel).font(Theme.Font.sublabel).foregroundStyle(Theme.secondaryText) }
            }
            .foregroundStyle(disabled ? Theme.dim : Theme.text)
            .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            .lineLimit(1)
            track
            valueField
                .frame(width: Theme.Metric.sliderValueWidth, alignment: .trailing)
        }
        .frame(height: sublabel == nil ? Theme.Metric.rowHeight + 4 : Theme.Metric.rowHeight + 14)
        .opacity(disabled ? 0.6 : 1)
        .allowsHitTesting(!disabled)
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }
    private var zeroFraction: CGFloat {
        CGFloat((zero - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobW = Theme.Metric.knobSize.width
            let x = fraction * (w - knobW) + knobW / 2
            ZStack(alignment: .leading) {
                Group {
                    if let g = trackGradient {
                        Capsule().fill(LinearGradient(colors: g, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Theme.dim)
                    }
                }
                .frame(height: Theme.Metric.trackHeight)
                .padding(.horizontal, knobW / 2)
                // Zero tick, only when zero is not at an end.
                if zeroFraction > 0.001 && zeroFraction < 0.999 && abs(fraction - zeroFraction) > 0.02 {
                    Rectangle().fill(Theme.text.opacity(0.55)).frame(width: 1, height: 6)
                        .offset(x: zeroFraction * (w - knobW) + knobW / 2 - 0.5)
                }
                RoundedRectangle(cornerRadius: Theme.Metric.knobRadius, style: .continuous)
                    .fill(Theme.knob)
                    .frame(width: knobW, height: Theme.Metric.knobSize.height)
                    .offset(x: x - knobW / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let mods = NSEvent.modifierFlags
                        let span = range.upperBound - range.lowerBound
                        if dragStart == nil {
                            dragStart = value
                            // Jump to the click point on a fresh press.
                            let f = ((g.startLocation.x - knobW / 2) / max(w - knobW, 1)).clamped(to: 0...1)
                            let target = range.lowerBound + Double(f) * span
                            if abs(target - value) > span * 0.03 { dragStart = target }
                        }
                        let sens: Double = mods.contains(.option) ? 0.25 : 1
                        var v = (dragStart ?? value) + Double(g.translation.width / max(w - knobW, 1)) * span * sens
                        if mods.contains(.shift) { v = (v / snap).rounded() * snap }
                        value = v.clamped(to: range)
                    }
                    .onEnded { _ in dragStart = nil; onCommit() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = zero; onCommit() })
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.value)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, f in if !f { commitText() } }
            } else {
                Text(format(value))
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { text = format(value); editing = true; focused = true }
            }
        }
        .lineLimit(1)
    }

    private func commitText() {
        if let v = parse(text) { value = v.clamped(to: range); onCommit() }
        editing = false
    }
}

/// A checkbox drawn as the design draws it: a 9 pt hollow square, filled when on.
struct CheckBox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 1.5).stroke(Theme.text, lineWidth: 1.2)
                if isOn { RoundedRectangle(cornerRadius: 1).fill(Theme.text).padding(2.2) }
            }
            .frame(width: Theme.Metric.checkbox, height: Theme.Metric.checkbox)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label at the left, checkbox at the right — the Features rows.
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
            Spacer()
            CheckBox(isOn: $isOn).padding(.trailing, -6)
        }
        .frame(height: Theme.Metric.rowHeight + 3)
    }
}
