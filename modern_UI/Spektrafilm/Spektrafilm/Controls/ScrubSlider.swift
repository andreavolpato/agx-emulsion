//  ScrubSlider.swift — the one slider in the app.
//
//  UI-GUIDELINE §5: build it once, use it everywhere, and do not let a second
//  slider implementation appear. SwiftUI's `Slider` fails every requirement
//  below, and this control is used for every parameter, so it is the one
//  component worth building carefully.
//
//  The requirement that shapes the rest of the app is the last one:
//
//      continuous value updates during drag, with a distinct commit on release
//
//  The release is what fires `reprint`. Everything downstream — the ~193 ms
//  budget, the `preview` badge, sending shoot-layer changes only on release
//  because `cancel` cannot arrive mid-render — depends on drag and commit
//  being two different events rather than one stream.

import SwiftUI

struct ScrubSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Where the tick goes, and what a double-click resets to.
    ///
    /// For print-side controls this is the **auto-solve value**, not the
    /// parameter's mathematical zero. Frontend SPEC §5.2 puts PRD §0's model
    /// — sliders exist to override the auto-solve — directly into the
    /// interface, and it is what makes paste-settings meaningful across
    /// frames: pasting offsets means "same print recipe, each frame solves
    /// its own exposure", which is what a lab does across a roll.
    var zero: Double = 0

    /// Display as an offset from `zero` rather than as an absolute value.
    var showsOffset = false
    var unit: String?
    var decimals: Int = 2
    /// Track tint. Only the two filter-pack sliders pass one — UI-GUIDELINE
    /// §5 makes them the only coloured controls in the app.
    var tint: LinearGradient?
    /// Fires once, on release. Not on every drag event.
    var onCommit: () -> Void = {}

    @State private var dragStart: Double?
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    private var fraction: Double {
        (value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne)
    }
    private var zeroFraction: Double {
        (zero - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne)
    }
    private var displayed: Double { showsOffset ? value - zero : value }

    private var text: String {
        let v = displayed
        let sign = (showsOffset && v > 0) ? "+" : ""
        return sign + String(format: "%.\(decimals)f", v) + (unit.map { " \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                valueField
            }
            track
        }
        .onHover { hovering = $0 }
    }

    // MARK: - the editable numeric field

    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .onSubmit(commitDraft)
                    .onExitCommand { editing = false }
            } else {
                Text(text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .onTapGesture(count: 2) { beginEditing() }
            }
        }
        // Fixed width with tabular figures so the field does not jump while
        // the value changes under a drag.
        .frame(width: 64, alignment: .trailing)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
            editing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.hairline),
            lineWidth: 1))
    }

    private func beginEditing() {
        draft = String(format: "%.\(decimals)f", displayed)
        editing = true
        fieldFocused = true
    }

    private func commitDraft() {
        if let typed = Double(draft.trimmingCharacters(in: .whitespaces)) {
            value = (showsOffset ? typed + zero : typed).clamped(to: range)
            onCommit()
        }
        editing = false
    }

    // MARK: - the track

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                if let tint {
                    Capsule().fill(tint).frame(height: 4).opacity(0.8)
                }

                // Fill drawn from the zero tick outward, not from the left
                // edge. On a bipolar control (the filter shifts) filling from
                // the left would read as "how much" when the value is "which
                // direction, how far".
                let x0 = min(zeroFraction, fraction) * w
                let x1 = max(zeroFraction, fraction) * w
                Capsule()
                    .fill(tint == nil ? AnyShapeStyle(Color.accentColor)
                                      : AnyShapeStyle(Color.accentColor.opacity(0.45)))
                    .frame(width: max(x1 - x0, 0), height: 4)
                    .offset(x: x0)

                // The zero tick. Must be legible: print-side sliders show
                // offset from the solve, so this is where "no override" is.
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 1, height: 9)
                    .offset(x: zeroFraction * w - 0.5)

                Circle()
                    .fill(.white)
                    .frame(width: hovering || dragStart != nil ? 11 : 9)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
                    .offset(x: fraction * w - (hovering || dragStart != nil ? 5.5 : 4.5))
            }
            .frame(height: 14)
            .contentShape(.rect)
            // Drag anywhere on the track, not just on the knob.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers([])
                    .onChanged { g in scrub(g, width: w, sensitivity: 1.0, snap: false) }
                    .onEnded { _ in endScrub() }
            )
            // ⌥ for fine adjustment at 1/4 sensitivity; ⇧ to snap. Separate
            // gestures rather than reading NSEvent modifiers inside one,
            // because SwiftUI delivers modifier state on the gesture, not on
            // the value.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers(.option)
                    .onChanged { g in scrub(g, width: w, sensitivity: 0.25, snap: false) }
                    .onEnded { _ in endScrub() }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers(.shift)
                    .onChanged { g in scrub(g, width: w, sensitivity: 1.0, snap: true) }
                    .onEnded { _ in endScrub() }
            )
            .onTapGesture(count: 2) {
                value = zero
                onCommit()
            }
        }
        .frame(height: 14)
    }

    private func scrub(_ g: DragGesture.Value, width: CGFloat,
                       sensitivity: Double, snap: Bool) {
        // Capture the start on begin, then add scaled translation. Reading
        // `g.location` directly would make ⌥ fine-adjust impossible, since a
        // position-based track has no notion of sensitivity.
        if dragStart == nil { dragStart = value }
        guard let start = dragStart, width > 0 else { return }
        let span = range.upperBound - range.lowerBound
        var next = start + (g.translation.width / width) * span * sensitivity
        if snap {
            let step = span > 20 ? 5.0 : (span > 4 ? 0.5 : 0.1)
            next = (next / step).rounded() * step
        }
        value = next.clamped(to: range)
    }

    private func endScrub() {
        dragStart = nil
        // The one call. Everything downstream of a parameter change hangs off
        // this, not off the drag.
        onCommit()
    }
}
