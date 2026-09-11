//  BootWindow.swift — the small window the app shows while the engine starts.
//
//  Photoshop and Capture One both do this, and the reason is not decoration:
//  a photo application has a fixed, unavoidable amount of setup — here the
//  Python interpreter, numpy/MLX imports, the Metal device, and the pipeline
//  for one film/paper pair — and doing it silently behind an empty editor
//  makes a working app look broken.
//
//  **The rule.** This window covers work the app has to do anyway. Nothing in
//  it sleeps and nothing is padded; if the engine is already warm it is on
//  screen for a few frames. It is a place to *report* the wait, not a way to
//  manufacture one.
//
//  It also reports which engine started, which is the one thing an earlier
//  session most needed and did not have (HANDOFF-GPU-WIRING §0): a whole day's
//  work landed against a backend nobody was running, and the only symptom was
//  that things felt slow.

import AppKit
import SwiftUI

struct BootWindow: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Filmify")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("film simulation")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.dim)
                .padding(.top, 2)
            Spacer(minLength: 0)

            // The progress line. `.failed` is deliberately not a dead end —
            // the editor's blocking panel (contract §2) is where a service
            // problem is explained and where the restart button is, so boot
            // hands over rather than trapping the user here.
            HStack(spacing: 7) {
                if case .failed = session.bootPhase {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(Theme.accent)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                }
                Text(session.bootPhase.label)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let core = session.renderCore {
                    Text(core.uppercased())
                        .font(Theme.Font.caption.monospaced())
                        .foregroundStyle(core == "metal" ? Theme.accent : Theme.dim)
                        .help("The executor the render service started with.")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: BootWindowController.size.width, height: BootWindowController.size.height)
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }
}

/// Owns the boot window and the handover to the editor.
///
/// The editor window is **ordered out** rather than never created: SwiftUI
/// builds its `Window` scene at launch and there is no supported way to defer
/// that. Hiding it and bringing it forward when boot completes gives the
/// Photoshop shape — small window, then the real one — without fighting the
/// scene system.
@MainActor
final class BootWindowController {
    static let size = CGSize(width: 360, height: 190)

    private var window: NSWindow?
    private var editor: NSWindow?
    private var observer: Task<Void, Never>?

    /// Show it, hide the editor, and hand over when the session says it is up.
    func present(session: Session) {
        // An editor window that never appears is worse than a visible one, so
        // every path below has a `reveal()`.
        editor = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
        editor?.orderOut(nil)

        let w = NSWindow(contentRect: CGRect(origin: .zero, size: BootWindowController.size),
                         styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 0x2C / 255.0, green: 0x2D / 255.0, blue: 0x2B / 255.0, alpha: 1)
        w.contentView = NSHostingView(rootView: BootWindow(session: session))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w

        observer = Task { @MainActor [weak self] in
            // A hard ceiling, because a boot window that never goes away is
            // the worst outcome of the whole feature — worse than no boot
            // window at all. If warm-up is still running at the deadline the
            // editor comes up anyway and the work continues behind it; the
            // gate in `openInService` still holds, so nothing renders early.
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if session.booted { break }
                if case .failed = session.bootPhase { break }
                try? await Task.sleep(for: .milliseconds(60))
            }
            self?.reveal()
        }
    }

    private func reveal() {
        observer = nil
        window?.orderOut(nil)
        window = nil
        let target = editor ?? NSApp.windows.first { $0.contentView != nil }
        target?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor = nil
    }
}
