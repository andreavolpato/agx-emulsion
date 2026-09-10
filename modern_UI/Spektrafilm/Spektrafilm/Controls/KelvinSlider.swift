//  KelvinSlider.swift — white balance at decode, designed rather than copied.
//
//  The drawing's "Color Temp. / As Shot ☐" rows are replaced by one compact
//  block: a preset pill (As Shot · Daylight · … · Custom), a neutral-picker
//  button, then temperature on a blue→amber track and tint on a green→magenta
//  track. Dragging either flips the preset to Custom; choosing As Shot
//  restores the camera's values. Only RAW input can be re-balanced, so the
//  whole block dims for flat files and says why.

import SwiftUI

struct WhiteBalanceBlock: View {
    @Bindable var session: Session
    private var isRAW: Bool { session.decoded?.isRAW ?? (session.selection.map { ImageDecoder.rawExtensions.contains($0.pathExtension.lowercased()) } ?? false) }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("Camera WB").font(Theme.Font.label).foregroundStyle(Theme.text)
                    .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
                Menu {
                    ForEach(DecodeSettings.WhiteBalance.allCases.filter { $0 != .custom }, id: \.self) { m in
                        Button(m.rawValue) { session.setWhiteBalance(m) }
                    }
                } label: {
                    HStack {
                        Text(session.decode.whiteBalance.rawValue).font(Theme.Font.label).foregroundStyle(Theme.text).padding(.leading, 12)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text).padding(.trailing, 8)
                    }
                    .frame(height: 14).frame(maxWidth: .infinity)
                    .background(Theme.field, in: Capsule()).contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
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
            ScrubSlider(label: "Temp.",
                        value: Binding(get: { session.decode.temperature },
                                       set: { var d = session.decode; d.temperature = $0; d.whiteBalance = .custom; session.decode = d }),
                        range: 2000...12000, zero: session.decoded?.asShotTemperature ?? 5500, snap: 100,
                        format: { "\(Int($0)) K" },
                        trackGradient: [Color(hex: 0x6E8FD8), Color(hex: 0xA9B4C4), Color(hex: 0xD9A45B)])
            ScrubSlider(label: "Tint",
                        value: Binding(get: { session.decode.tint },
                                       set: { var d = session.decode; d.tint = $0; d.whiteBalance = .custom; session.decode = d }),
                        range: -150...150, zero: session.decoded?.asShotTint ?? 0, snap: 5,
                        format: { String(format: "%+.0f", $0) },
                        trackGradient: [Color(hex: 0x7CBF7C), Color(hex: 0xB4B4B4), Color(hex: 0xC97CC0)])
            if session.selection != nil {
                // Two blocks in this window are called white balance. This is
                // the decode one — a lens filter, not a print control
                // (HANDOFF §6).
                Text(isRAW ? "Decode — re-reads the RAW." : "Decode white balance applies to RAW input only.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(isRAW || session.selection == nil ? 1 : 0.5)
        .allowsHitTesting(isRAW)
    }
}
