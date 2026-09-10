//  SpektrafilmApp.swift — @main. One window, one session, one service.
//
//  `--snapshot WxH out.png [--open path] [--wait s]` renders the window at
//  that size and writes a PNG: the harness `Tools/snapshot.sh` uses it to
//  compare the built interface against the drawing at three window sizes.

import AppKit
import SwiftUI

@main
struct SpektrafilmApp: App {
    /// One session for the app's lifetime; the delegate reaches it here.
    @MainActor static let session = Session()
    private var session: Session { Self.session }
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let snapshot = SnapshotRequest.parse(CommandLine.arguments)

    var body: some Scene {
        Window("Spektrafilm", id: "editor") {
            EditorWindow(session: session)
                .environment(\.snapshotMode, snapshot != nil)
                .frame(minWidth: Theme.Metric.minWindow.width, minHeight: Theme.Metric.minWindow.height)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1920, height: 1080)
        .commands { EditorCommands(session: session) }
    }
}

struct EditorCommands: Commands {
    let session: Session
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { session.openPanel() }.keyboardShortcut("o")
            Button("Export…") { session.showExport = true }.keyboardShortcut("e").disabled(session.selection == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session.undo() }.keyboardShortcut("z").disabled(!session.canUndo)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Settings") { session.copySettings() }
                .keyboardShortcut("c").disabled(session.selection == nil)
            Button("Paste Settings") { session.pasteSettings() }
                .keyboardShortcut("v").disabled(!session.canPasteSettings)
        }
        CommandMenu("View") {
            Button("Zoom In") { session.zoomStep(1) }.keyboardShortcut("+")
            Button("Zoom Out") { session.zoomStep(-1) }.keyboardShortcut("-")
            Button("Zoom to Fit") { session.zoomToFit() }.keyboardShortcut("0")
            Button("Zoom to 100 %") { session.zoomTo(fraction: 1) }.keyboardShortcut("1")
            Divider()
            Button("Toggle Side Panels") {
                withAnimation(.easeOut(duration: 0.18)) {
                    let c = !(session.leftCollapsed && session.rightCollapsed)
                    session.leftCollapsed = c; session.rightCollapsed = c
                }
            }.keyboardShortcut("\\")
            Button("Toggle Filmstrip") { withAnimation { session.filmstripCollapsed.toggle() } }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Bypass Adjustments") { var a = session.adjustments; a.enabled.toggle(); session.adjustments = a }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button(session.comparing ? "Hide Before / After" : "Before / After") { session.comparing.toggle() }
                .keyboardShortcut("\\", modifiers: [.option])
                .disabled(!session.canCompare)
            Divider()
            Button("Restart Render Service") { session.restartService() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(session.selection == nil)
            Button("Browse This Folder") { session.browseSession() }.disabled(session.frames.count < 2)
        }
        CommandMenu("Frame") {
            Button("Previous") { session.selectRelative(-1) }.keyboardShortcut("[")
            Button("Next") { session.selectRelative(1) }.keyboardShortcut("]")
        }
        // Withdrawn with the rest of the mask system (`FeatureFlags.masks`):
        // a menu is a promise, and this one cannot be kept while the feature
        // is not on offer.
        if FeatureFlags.masks {
            CommandMenu("Mask") {
                Button("Add Linear Gradient") { session.addMask(.linearGradient) }
                    .keyboardShortcut("m", modifiers: [.shift])
                Button("Add Radial Gradient") { session.addMask(.radialGradient) }
                    .keyboardShortcut("m", modifiers: [.shift, .option])
                Button("Add Luminance Range") { session.addMask(.luminanceRange) }
                Button("Add Colour Range") { session.addMask(.colorRange) }
                Divider()
                Button("Show Mask Overlay") { session.maskOverlayVisible.toggle() }
                    .keyboardShortcut("o", modifiers: [.shift])
                Button("Invert Mask") {
                    if var m = session.selectedMask { m.inverted.toggle(); session.selectedMask = m }
                }.disabled(session.selectedMask == nil)
                Divider()
                Button("Delete Mask") { if let id = session.selectedMaskID { session.deleteMask(id) } }
                    .disabled(session.selectedMaskID == nil)
            }
        }
        CommandMenu("Crop") {
            Button("Rotate Left") { session.geometry = session.geometry.turned(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Rotate Right") { session.geometry = session.geometry.turned(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Flip Horizontally") { var g = session.geometry; g.flipH.toggle(); session.geometry = g }
            Button("Flip Vertically") { var g = session.geometry; g.flipV.toggle(); session.geometry = g }
            Divider()
            Button("Reset Crop") { session.geometry = .default }
        }
        CommandMenu("Tool") {
            Button("Select") { session.tool = .select }.keyboardShortcut("v", modifiers: [])
            Button("Hand") { session.tool = .hand }.keyboardShortcut("h", modifiers: [])
            Button("Crop") { session.tool = .crop }.keyboardShortcut("c", modifiers: [])
        }
    }
}

struct SnapshotRequest {
    var size: CGSize
    var output: URL
    var open: URL?
    var wait: Double = 1.5
    /// Optional zoom fraction (1 = 100 %). Drives the detail-tier path so the
    /// resolution escalation can be captured without a person at the keyboard.
    var zoom: CGFloat?
    /// `--geometry x,y,w,h,angle[,turns]` — a crop to apply before capturing,
    /// so the geometry path has a regression capture like everything else.
    /// Unlike the canvas itself, this one *is* visible offscreen: the
    /// geometry is applied while sampling, and `renderOffscreen` samples.
    var geometry: Geometry?
    /// `--mask kind,exposure[,overlay]` — add one mask before capturing, so
    /// the mask path has a regression capture. Like the geometry, this one is
    /// visible offscreen: it happens in the `layer2` kernel and
    /// `renderOffscreen` runs it.
    var mask: (kind: MaskComponentKind, exposure: Double, overlay: Bool)?
    /// `--compare [position]` — put the before/after split up before
    /// capturing. Like the geometry and the mask, this one *is* visible
    /// offscreen: the split happens in `canvasFragment` and `renderOffscreen`
    /// draws through it. Only the shader half is captured — the line, the
    /// handle and the labels are SwiftUI over the canvas, and `SnapshotCanvas`
    /// stands in for the Metal view — which is exactly the half that a test
    /// cannot otherwise see.
    var compare: Double?

    static func parse(_ args: [String]) -> SnapshotRequest? {
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return nil }
        let dims = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard dims.count == 2 else { return nil }
        var r = SnapshotRequest(size: CGSize(width: dims[0], height: dims[1]), output: URL(fileURLWithPath: args[i + 2]))
        if let j = args.firstIndex(of: "--open"), args.count > j + 1 { r.open = URL(fileURLWithPath: args[j + 1]) }
        if let j = args.firstIndex(of: "--wait"), args.count > j + 1, let w = Double(args[j + 1]) { r.wait = w }
        if let j = args.firstIndex(of: "--zoom"), args.count > j + 1, let z = Double(args[j + 1]) { r.zoom = CGFloat(z) }
        if let j = args.firstIndex(of: "--mask"), args.count > j + 1 {
            let f = args[j + 1].split(separator: ",").map(String.init)
            if let kind = MaskComponentKind(rawValue: f[0]) {
                r.mask = (kind, f.count > 1 ? Double(f[1]) ?? -1 : -1, f.count > 2 && f[2] == "overlay")
            }
        }
        if let j = args.firstIndex(of: "--compare") {
            r.compare = args.count > j + 1 ? (Double(args[j + 1]) ?? 0.5) : 0.5
        }
        if let j = args.firstIndex(of: "--geometry"), args.count > j + 1 {
            let f = args[j + 1].split(separator: ",").compactMap { Double($0) }
            if f.count >= 5 {
                var g = Geometry()
                g.crop = CropRect(x: f[0], y: f[1], width: f[2], height: f[3])
                g.angle = f[4]
                if f.count > 5 { g.quarterTurns = Int(f[5]) }
                r.geometry = g
            }
        }
        return r
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: Session? { SpektrafilmApp.session }
    var snapshot: SnapshotRequest?
    private let boot = BootWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Parsed here, not handed over from the scene: this fires before any
        // view's onAppear.
        guard let snapshot = SnapshotRequest.parse(CommandLine.arguments) else {
            openCommandLineArguments()
            // Not in snapshot mode: `Tools/snapshot.sh` builds its own window
            // and must not have a second one taking key, and a capture that
            // photographed a splash screen would be worthless.
            if let session { boot.present(session: session) }
            return
        }
        self.snapshot = snapshot
        Task { await runSnapshot(snapshot) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        session?.open(urls: urls)
    }

    /// A path passed on the command line opens too, so a capture or a script
    /// can launch one instance with a frame already in it rather than
    /// launching and then sending an open event to a second copy.
    func openCommandLineArguments() {
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { session?.open(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session?.flushSave()
        if let c = session?.client { Task { await c.stop() } }
    }

    private var snapshotWindow: NSWindow?

    private func runSnapshot(_ req: SnapshotRequest) async {
        guard let session else { exit(2) }
        // Own window, own hosting view: the capture must not depend on when
        // (or whether) the SwiftUI scene's window is ordered in.
        let host = NSHostingView(rootView: EditorWindow(session: session).environment(\.snapshotMode, true))
        // Borderless, and never `center()`. A titled window is constrained to
        // the screen's visible frame, so asking for 1920×1080 on a smaller
        // display silently produced a 1800-point-wide capture — and every
        // measurement taken against it was then wrong by that ratio. The
        // capture must not depend on which display happens to be attached.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: req.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrame(CGRect(origin: .zero, size: req.size), display: true)
        host.frame = CGRect(origin: .zero, size: req.size)
        window.makeKeyAndOrderFront(nil)
        snapshotWindow = window
        // A capture must show the interface, not whatever panel the last
        // session happened to leave folded: the collapse flags persist in
        // UserDefaults, and a filmstrip collapsed days ago silently removed a
        // whole card from the measurement.
        session.leftCollapsed = false
        session.rightCollapsed = false
        session.topCollapsed = false
        session.filmstripCollapsed = false
        try? await Task.sleep(for: .milliseconds(300))
        if let open = req.open { session.open(urls: [open]) }
        let deadline = Date().addingTimeInterval(req.wait)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if req.open == nil { if Date() > deadline.addingTimeInterval(-req.wait + 1.0) { break } }
            // A live service session id, not the sidecar's `state`: a frame
            // edited in an earlier run is `.processed` on disk before this run
            // has rendered anything, and the loop used to exit on it.
            else if session.serviceSessionIDForExport != nil, !session.previewSoft,
                    let sel = session.selection, !session.busy,
                    session.frameStates[sel] == .processed { break }
        }
        try? await Task.sleep(for: .milliseconds(400))
        if let m = req.mask {
            session.addMask(m.kind)
            if var mask = session.selectedMask {
                mask.adjustments.exposure = m.exposure
                session.selectedMask = mask
            }
            session.maskOverlayVisible = m.overlay
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let g = req.geometry {
            session.geometry = g.fitted(in: session.sourceImageSize)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let position = req.compare {
            session.comparePosition = position
            session.comparing = true
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let zoom = req.zoom {
            session.zoomTo(fraction: zoom)
            // Wait for the detail render the zoom asked for. The renderer's
            // `showsDetail` is the condition, not `detailTier`, because the
            // tier flips as soon as the request is queued.
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                if !session.detailPending && (session.detailTier == .live || session.renderer.showsDetail) { break }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        host.frame = CGRect(origin: .zero, size: req.size)
        host.layoutSubtreeIfNeeded()
        let view: NSView = host
        guard view.bounds.size == req.size,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: wanted \(req.size), view is \(view.bounds.size)\n".utf8))
            exit(3)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
        try? png.write(to: req.output)
        print("snapshot \(Int(req.size.width))x\(Int(req.size.height)) → \(req.output.path)")
        exit(0)
    }
}
