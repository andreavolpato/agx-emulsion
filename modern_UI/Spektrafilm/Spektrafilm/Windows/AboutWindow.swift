//  AboutWindow.swift — who made this, under what licence, and where the
//  source is.
//
//  **Not a nicety.** Two of the three licences the bundle carries require
//  something visible, and one of them names this screen: CC BY-SA 4.0, on the
//  film and paper profiles, says the attribution must survive "whether the LUT
//  is shipped inside a .cube header, an ICC profile field, an app's About
//  screen, a paid plugin … the form can vary; the information cannot
//  disappear." The GPL requires the licence text and an offer of the
//  corresponding source. So: the credit is on the front, the full texts are
//  one click away, and both are read out of the bundle rather than retyped
//  here — a licence text that drifts from the file beside it is worse than
//  none (HANDOFF-DISTRIBUTION §2.3).

import AppKit
import SwiftUI

struct AboutWindow: View {
    @State private var showing: Licence?

    /// One licence text in the bundle. `body` is read lazily: five files, of
    /// which the GPL alone is 35 kB, and the panel usually shows none of them.
    struct Licence: Identifiable, Hashable {
        let id: String       // the file name
        let title: String
        var url: URL? { AboutWindow.licenceDirectory?.appending(path: id) }
        var body: String {
            (url.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
                ?? "\(id) is missing from this build. Run Tools/bundle-licenses.sh."
        }
    }

    static let licences = [
        Licence(id: "Spektrafilm-GPL-3.0.txt", title: "GNU GPL v3 — the application and the engine"),
        Licence(id: "Profiles-and-LUTs-CC-BY-SA-4.0.txt", title: "CC BY-SA 4.0 — the profiles and the print LUTs"),
        Licence(id: "Profiles-and-LUTs-CHANGELOG.txt", title: "What this build changed about the profiles and LUTs"),
        Licence(id: "metal-cpp-Apache-2.0.txt", title: "Apache 2.0 — metal-cpp"),
    ]

    /// `Bundle(for:)`, not `Bundle.main`, for `EngineClient`'s reason: the
    /// unit-test target is standalone, so `Bundle.main` is Xcode's test agent
    /// and every lookup misses.
    static var licenceDirectory: URL? {
        Bundle(for: BundleToken.self).url(forResource: "Licenses", withExtension: nil,
                                          subdirectory: "Resources")
    }
    private final class BundleToken {}

    private static var version: String {
        let info = Bundle(for: BundleToken.self).infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            credits
            Divider()
            licenceList
        }
        .frame(width: 460)
        .background(Theme.card)
        .sheet(item: $showing) { licence in
            LicenceSheet(licence: licence) { showing = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Spektrafilm").font(.system(size: 20, weight: .semibold))
                Text(AboutWindow.version).font(Theme.Font.sublabel).foregroundStyle(.secondary)
                Text("A spectral film and print simulation for macOS.")
                    .font(Theme.Font.sublabel).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The attribution the CC BY-SA licence requires, in the form it
            // suggests: author, canonical source, licence.
            VStack(alignment: .leading, spacing: 2) {
                Text("Film simulation, measured profiles and print model")
                    .font(Theme.Font.groupHeader).foregroundStyle(Theme.text)
                Text("Andrea Volpato — licensed CC BY-SA 4.0")
                    .font(Theme.Font.sublabel).foregroundStyle(.secondary)
                link("github.com/andreavolpato/spektrafilm",
                     "https://github.com/andreavolpato/spektrafilm")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("This application and its render engine")
                    .font(Theme.Font.groupHeader).foregroundStyle(Theme.text)
                // The GPL's written offer, and the only form of it that is
                // any use: a place to get the code.
                Text("Free software under the GNU GPL v3 or later. You have the right to the corresponding source.")
                    .font(Theme.Font.sublabel).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                link("github.com/andreavolpato/spektrafilm",
                     "https://github.com/andreavolpato/spektrafilm")
            }
            Text("The 8 baked print-preview LUTs are derivatives of the profiles and carry the same CC BY-SA 4.0 licence. What was changed, and what was not, is in the changelog below.")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var licenceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Licences").font(Theme.Font.groupHeader).foregroundStyle(Theme.text)
            ForEach(AboutWindow.licences) { licence in
                Button { showing = licence } label: {
                    HStack(spacing: 6) {
                        Text(licence.title).font(Theme.Font.listItem).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9))
                            .foregroundStyle(Theme.dim)
                    }
                    .frame(height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let dir = AboutWindow.licenceDirectory {
                Button("Show the licence files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .buttonStyle(.link).font(Theme.Font.caption)
            } else {
                // Said rather than hidden: a build with no licence texts is a
                // build that should not have been made.
                Text("This build carries no licence texts. Run Tools/bundle-licenses.sh and rebuild.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.accent)
            }
        }
        .padding(20)
    }

    private func link(_ label: String, _ url: String) -> some View {
        Button(label) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
            .buttonStyle(.link).font(Theme.Font.sublabel)
    }
}

/// One licence, in full, selectable and scrollable.
///
/// Rendered in the app rather than handed to TextEdit: a signed, notarised
/// bundle's resources are read-only and opening them in another app is one
/// more thing that can fail on a stranger's machine, when the obligation is
/// simply that the text be *available*.
private struct LicenceSheet: View {
    let licence: AboutWindow.Licence
    let dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(licence.title).font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
            HStack {
                if let url = licence.url {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link).font(Theme.Font.caption)
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 520)
        .task { text = licence.body }
    }
}
