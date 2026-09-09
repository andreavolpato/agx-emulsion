//  TrafficLights.swift — put the three window buttons on the left card's
//  header centreline, the way Xcode puts them on its navigator header's.
//
//  The problem this solves, measured off `reference_layout/traffic_light_bug.png`:
//
//      close button      x 18…31.5   y 9…22.5    centre y 15.75
//      header glyph row  (card top 7 + 44/2)     centre y 29
//
//  Thirteen points apart. The lights floated high and slightly left of a
//  glyph row that sat low and to the right, and nothing in the corner shared
//  a line with anything else. `panelHeaderLeading = 70` had been tuned so the
//  import glyph *cleared* the lights horizontally, which is a different
//  problem from the two rows agreeing about where the row is.
//
//  Why the buttons move rather than the header:
//
//  The alternative is to reserve a titlebar strip and start the cards below
//  it. That fixes the alignment by removing the shared row — and it costs
//  ~21 pt off the top of all four cards, which is a change to the geometry
//  `Tools/compare-layout.py` measures against the drawing. The cards stay
//  where they are drawn; the buttons come to them.
//
//  Why the buttons are reparented rather than repositioned:
//
//  `.windowStyle(.hiddenTitleBar)` leaves the buttons inside a titlebar view
//  that is about 28 pt tall and clips its subviews. A centre 29 pt from the
//  window's top is *below* that view's bottom edge, so setting the frame in
//  place makes the buttons disappear rather than move. Moving them into the
//  theme frame — the full-window view that the titlebar view itself is a
//  subview of — takes them out of AppKit's titlebar layout entirely, which
//  is also what stops it putting them back on the next resize.
//
//  AppKit reclaims them across a fullscreen transition, so the alignment is
//  re-applied on the window notifications that bracket one. Everything here
//  fails soft: a window with no standard buttons (the borderless snapshot
//  window) is a no-op, not a crash.

import AppKit
import SwiftUI

/// Attach to the view whose centreline the buttons should share. Invisible,
/// zero-sized, and does nothing at all in snapshot mode — the borderless
/// capture window has no standard window buttons to align.
struct TrafficLightAlignment: NSViewRepresentable {
    /// Distance from the top of the window to the centre of the button row.
    let centreY: CGFloat
    /// Distance from the left of the window to the leading edge of the close
    /// button.
    let leading: CGFloat

    func makeNSView(context: Context) -> NSView { AlignerView(centreY: centreY, leading: leading) }

    func updateNSView(_ view: NSView, context: Context) {
        guard let v = view as? AlignerView else { return }
        v.centreY = centreY
        v.leading = leading
        v.apply()
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? AlignerView)?.stopObserving()
    }

    final class AlignerView: NSView {
        var centreY: CGFloat
        var leading: CGFloat
        private var observers: [any NSObjectProtocol] = []

        init(centreY: CGFloat, leading: CGFloat) {
            self.centreY = centreY
            self.leading = leading
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            // AppKit reclaims the standard buttons — pulls them back out of
            // our container and re-lays them out in the titlebar — on more
            // occasions than "the window resized". Losing key is one of them,
            // which is why the first version of this measured correct in a
            // log and captured wrong: `Tools/capture-live.sh` photographs a
            // window that is *not* key, and by then AppKit had taken them
            // back. These are the notifications that do it.
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification,
                         NSWindow.didResignMainNotification,
                         NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.applyAfterAppKit() }
                    })
            }
            apply()
            applyAfterAppKit()
        }

        /// Re-apply on the next runloop turn. AppKit does its own titlebar
        /// layout *during* several of these notifications, so applying
        /// synchronously inside one of them is applying before it and being
        /// undone immediately afterwards.
        func applyAfterAppKit() {
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        /// The container the buttons are moved into. Giving them a superview
        /// of our own is the whole trick: `NSThemeFrame` repositions the
        /// standard buttons on every layout pass, and it only does that for
        /// the ones that are still its direct subviews. Setting their frames
        /// in place measured correct in the log and was silently undone
        /// before the next frame reached the screen.
        private var box: NSView?

        /// Move the three buttons onto the header centreline. Safe to call as
        /// often as you like: it is idempotent and returns early on a window
        /// that has no standard buttons.
        func apply() {
            func log(_ m: String) {
                guard ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1" else { return }
                FileHandle.standardError.write(Data("lights: \(m)\n".utf8))
            }
            guard let window else { log("no window"); return }
            guard
                  // In fullscreen the buttons belong to the fullscreen
                  // toolbar and the cards are not where they are on the desk.
                  !window.styleMask.contains(.fullScreen) else { log("fullscreen"); return }
            guard let host = window.contentView?.superview else { log("no theme frame"); return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let buttons = kinds.compactMap { window.standardWindowButton($0) }
            guard buttons.count == kinds.count else { log("only \(buttons.count) buttons"); return }

            let diameter = buttons[0].frame.height
            let width = TrafficLightAlignment.spacing * 2 + buttons[2].frame.width
            let box = self.box ?? {
                let v = NSView(frame: .zero)
                self.box = v
                return v
            }()
            if box.superview !== host { box.removeFromSuperview(); host.addSubview(box) }
            // The theme frame is not flipped, and its height is the window's,
            // so a distance from the top becomes one from the bottom here.
            box.frame = CGRect(x: leading, y: (host.bounds.height - centreY - diameter / 2).rounded(),
                               width: width, height: diameter)
            var reclaimed = false
            for (i, b) in buttons.enumerated() {
                if b.superview !== box { b.removeFromSuperview(); box.addSubview(b); reclaimed = true }
                b.setFrameOrigin(CGPoint(x: TrafficLightAlignment.spacing * CGFloat(i), y: 0))
            }
            guard reclaimed else { return }
            log("aligned centreY=\(centreY) box=\(box.frame) in \(type(of: host)) h=\(host.bounds.height)")
        }
    }

    /// Centre-to-centre spacing of the three buttons, which is AppKit's own
    /// (measured 20 pt) and is not ours to restyle: a person's muscle memory
    /// for the close button is built on every other window on the machine.
    static let spacing: CGFloat = 20

    /// Width of the whole button row, from the close button's leading edge to
    /// the zoom button's trailing edge. Two gaps plus one button.
    static var rowWidth: CGFloat { spacing * 2 + buttonDiameter }
    static let buttonDiameter: CGFloat = 14
}
