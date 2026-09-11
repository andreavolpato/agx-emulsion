//  WhiteBalanceRows.swift — decode white balance, as the design draws it.
//
//  This file used to be `KelvinSlider.swift`, and its header used to say that
//  the drawing's "Color Temp. / As Shot ☐" rows had been replaced by one
//  compact block. That was a previous session's decision, not the user's, and
//  it has been reversed: the drawing is the spec, so what is here is the
//  drawing — a preset pill with the neutral picker at its right, then
//  Temperature and Tint, each on a track with its own "As Shot ☐" line.
//
//  What the boxes mean, and the rules that make them behave, live in
//  `WhiteBalanceBoxes` (`Model/Sidecar.swift`), where they can be tested
//  without a decode, a window or an engine. The short version: a ticked box
//  means "this axis is the camera's", which is `.asShot` *and* a `.custom`
//  setting that happens to hold the camera's value — the same picture, so the
//  same state.
//
//  Only RAW input can be re-balanced: a flat file has no camera white balance
//  to re-apply. The whole block dims and stops taking hits for one, and says
//  why in a tooltip rather than a caption — the drawing has no caption, and
//  the explanation is only wanted by the user who wonders why the controls are
//  dim.

import SwiftUI

struct WhiteBalanceRows: View {
    @Bindable var session: Session

    private var isRAW: Bool {
        session.decoded?.isRAW ?? (session.selection.map {
            ImageDecoder.rawExtensions.contains($0.pathExtension.lowercased())
        } ?? false)
    }
    /// Nothing to re-balance, and nothing to explain yet: no frame is open.
    private var dimmed: Bool { session.selection != nil && !isRAW }
    /// Ticking a box pins an axis to the camera's value, so with no decode
    /// there is nothing to pin to and the boxes are disabled.
    private var asShot: WhiteBalanceBoxes.AsShot? { session.asShotWhiteBalance }
    private var boxes: WhiteBalanceBoxes { session.whiteBalanceBoxes }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                PillMenu(label: "Camera WB",
                         options: DecodeSettings.WhiteBalance.allCases.filter { $0 != .custom },
                         title: { $0.rawValue },
                         selection: Binding(get: { session.decode.whiteBalance },
                                            set: { session.setWhiteBalance($0) }))
                Button { session.wbPickerActive.toggle() } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.wbPickerActive ? Theme.accent : Theme.text)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("Pick a neutral point on the image")
            }
            .frame(height: Theme.Metric.rowHeight)

            ScrubSlider(label: "Color Temp.",
                        sublabelView: asShotLine(Binding(get: { boxes.temp },
                                                         set: { session.setTempAsShot($0) })),
                        value: Binding(get: { session.decode.temperature },
                                       set: { session.setTemperature($0) }),
                        range: 2000...12000, zero: asShot?.temperature ?? 5500, snap: 100,
                        format: { "\(Int($0))" },
                        trackGradient: [Color(hex: 0x6E8FD8), Color(hex: 0xA9B4C4), Color(hex: 0xD9A45B)])

            ScrubSlider(label: "Color Tint",
                        sublabelView: asShotLine(Binding(get: { boxes.tint },
                                                         set: { session.setTintAsShot($0) })),
                        value: Binding(get: { session.decode.tint },
                                       set: { session.setTint($0) }),
                        range: -150...150, zero: asShot?.tint ?? 0, snap: 5,
                        format: { String(format: "%.1f", $0) },
                        trackGradient: [Color(hex: 0x7CBF7C), Color(hex: 0xB4B4B4), Color(hex: 0xC97CC0)])
        }
        .opacity(dimmed ? 0.5 : 1)
        .allowsHitTesting(!dimmed)
        .modifier(RawOnlyHelp(show: dimmed))
    }

    /// "As Shot ☐" — the second label line, as the drawing has it.
    ///
    /// The box's own padding is a hit area rather than layout (it is drawn
    /// 9 pt), so the negative vertical padding here keeps the row from growing
    /// to suit it — the same trick `ToggleRow` uses horizontally.
    private func asShotLine(_ isOn: Binding<Bool>) -> AnyView {
        AnyView(
            HStack(spacing: 3) {
                Text("As Shot").font(Theme.Font.sublabel).foregroundStyle(Theme.secondaryText)
                CheckBox(isOn: isOn).padding(.vertical, -6).disabled(asShot == nil)
            }
        )
    }
}

/// `.help` with an empty string still installs a tooltip, so the message has
/// to be attached conditionally rather than passed empty.
private struct RawOnlyHelp: ViewModifier {
    let show: Bool

    func body(content: Content) -> some View {
        if show { content.help("Decode white balance applies to RAW input only.") } else { content }
    }
}
