//  SpektrafilmApp.swift
//
//  `Window`, not `WindowGroup` (UI-GUIDELINE §2): one session at a time,
//  matching API-SPEC §7.2's scope. A second window would imply a second
//  service session, which does not exist.

import SwiftUI
import UniformTypeIdentifiers

@main
struct SpektrafilmApp: App {
    @State private var session = Session()

    var body: some Scene {
        Window("Spektrafilm", id: "editor") {
            EditorWindow()
                .environment(session)
                // Forced. Every serious image editor does this, because a
                // light UI surrounding an image biases perception of its
                // tonality. Not a preference to expose.
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands { EditorCommands(session: session) }
    }
}

struct EditorCommands: Commands {
    let session: Session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { openFolder() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export…") { }
                .keyboardShortcut("e")
                .disabled(true)
        }
        // Frontend SPEC §5.4. `Tab` collapses both columns together; the
        // filmstrip has its own key because it is a different axis.
        CommandMenu("View") {
            Button("Hide Panels") {
                let hide = !(session.leftCollapsed && session.rightCollapsed)
                // Animated, unlike the divider drag: this is a discrete state
                // change, not a continuous one (UI-GUIDELINE §3).
                withAnimation(.easeOut(duration: 0.18)) {
                    session.leftCollapsed = hide
                    session.rightCollapsed = hide
                }
            }
            .keyboardShortcut(.tab, modifiers: [])

            Button("Hide Filmstrip") {
                withAnimation(.easeOut(duration: 0.18)) {
                    session.stripCollapsed.toggle()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button("Zoom to 100%") { session.zoomTo100() }
                .keyboardShortcut("z", modifiers: [])
            Button("Fit to Window") { session.fit() }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Zoom In")  { session.zoomIn() }
                .keyboardShortcut("=", modifiers: [.command])
            Button("Zoom Out") { session.zoomOut() }
                .keyboardShortcut("-", modifiers: [.command])
        }
        CommandMenu("Frame") {
            Button("Previous") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next")     { step(+1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private func step(_ delta: Int) {
        guard let current = session.selection,
              let index = session.frames.firstIndex(where: { $0.id == current })
        else { return }
        let next = (index + delta).clamped(to: 0...(session.frames.count - 1))
        session.selection = session.frames[next].id
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // The open panel states the expected form rather than silently
        // accepting whatever arrives (frontend SPEC §2.4).
        panel.message = "Open a folder. Externally prepared files should be "
                      + "linear scene-referred, ProPhoto RGB, colorimetric."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.open(url)
    }
}
