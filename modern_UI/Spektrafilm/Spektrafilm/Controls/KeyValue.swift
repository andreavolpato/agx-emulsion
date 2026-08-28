//  KeyValue.swift — a read-only label/value row.

import SwiftUI

struct KeyValue: View {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
    }
}

/// A label with a trailing control, at a consistent height.
struct LabeledRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label; self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            control.frame(maxWidth: 170)
        }
    }
}
