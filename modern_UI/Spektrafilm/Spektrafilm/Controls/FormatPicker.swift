//  FormatPicker.swift — the dark pill with an up/down chevron (the Camera
//  section's Format row). A generic "pill menu" used wherever a value is
//  chosen from a short list.

import SwiftUI

struct PillMenu<T: Hashable>: View {
    let label: String
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: {
                        if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                    }
                }
            } label: {
                HStack {
                    Text(title(selection)).font(Theme.Font.label).foregroundStyle(Theme.text).padding(.leading, 12)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text).padding(.trailing, 8)
                }
                .frame(height: 14)
                .frame(maxWidth: .infinity)
                .background(Theme.field, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .frame(height: Theme.Metric.rowHeight)
    }
}
