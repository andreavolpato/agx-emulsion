//  ColorWheel.swift — Capture One's Color Balance: Master / 3-way tabs, a hue
//  wheel with a draggable point (angle = hue, radius = saturation) and a
//  luminance slider beside it.

import SwiftUI

struct ColorBalanceEditor: View {
    @Bindable var session: Session
    @State private var mode: Mode = .master
    enum Mode: String, CaseIterable, Identifiable { case master = "Master", threeWay = "3-Way"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Mode.allCases) { m in
                    let on = m == mode
                    Button { mode = m } label: {
                        VStack(spacing: 4) {
                            Text(m.rawValue).font(Theme.Font.tab).foregroundStyle(on ? Theme.accent : Theme.secondaryText)
                            Rectangle().fill(on ? Theme.accent : Theme.dim.opacity(0.5)).frame(height: on ? 1.5 : 0.5)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if mode == .master {
                ZoneWheel(title: nil, zone: Binding(get: { session.adjustments.colorBalance.master },
                                                    set: { var a = session.adjustments; a.colorBalance.master = $0; session.adjustments = a }), size: 110)
            } else {
                HStack(spacing: 4) {
                    ZoneWheel(title: "Shadow", zone: zone(\.shadows), size: 66)
                    ZoneWheel(title: "Midtone", zone: zone(\.midtones), size: 66)
                    ZoneWheel(title: "Highlight", zone: zone(\.highlights), size: 66)
                }
            }
        }
    }

    private func zone(_ kp: WritableKeyPath<ColorBalance, ColorZone>) -> Binding<ColorZone> {
        Binding(get: { session.adjustments.colorBalance[keyPath: kp] },
                set: { var a = session.adjustments; a.colorBalance[keyPath: kp] = $0; session.adjustments = a })
    }
}

struct ZoneWheel: View {
    let title: String?
    @Binding var zone: ColorZone
    let size: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if let title { Text(title).font(Theme.Font.sublabel).foregroundStyle(Theme.secondaryText) }
            HStack(spacing: 6) {
                wheel
                lumSlider
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var wheel: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [
                Color(hue: 0, saturation: 0.6, brightness: 0.9), Color(hue: 1/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 2/6, saturation: 0.6, brightness: 0.85), Color(hue: 3/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 4/6, saturation: 0.6, brightness: 0.95), Color(hue: 5/6, saturation: 0.6, brightness: 0.9),
                Color(hue: 0, saturation: 0.6, brightness: 0.9)], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
            Circle().fill(RadialGradient(colors: [Theme.card, Theme.card.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            Circle().stroke(Theme.dim.opacity(0.6), lineWidth: 0.5)
            let r = CGFloat(zone.saturation) * (size / 2 - 5)
            let a = zone.hue * .pi / 180
            Circle().fill(Theme.text).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.card, lineWidth: 1))
                .offset(x: cos(a) * r, y: -sin(a) * r)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let c = CGPoint(x: size / 2, y: size / 2)
            let dx = g.location.x - c.x, dy = c.y - g.location.y
            let rr = min(hypot(dx, dy) / (size / 2 - 5), 1)
            var deg = atan2(dy, dx) * 180 / .pi
            if deg < 0 { deg += 360 }
            zone.hue = Double(deg)
            zone.saturation = Double(rr)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { zone = ColorZone() })
    }

    private var lumSlider: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let y = (1 - CGFloat(zone.luminance + 1) / 2) * (h - 8) + 4
            ZStack(alignment: .top) {
                Capsule().fill(LinearGradient(colors: [Theme.text.opacity(0.8), Theme.dim, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3)
                RoundedRectangle(cornerRadius: 2).fill(Theme.knob).frame(width: 9, height: 7).offset(y: y - 3.5)
            }
            .frame(width: 12, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = ((g.location.y - 4) / max(h - 8, 1)).clamped(to: 0...1)
                zone.luminance = Double(1 - 2 * f)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { zone.luminance = 0 })
        }
        .frame(width: 12, height: size)
    }
}
