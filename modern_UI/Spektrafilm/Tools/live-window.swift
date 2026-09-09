//  Tools/live-window.swift — print the app's on-screen window ids, largest first.
//
//  `screencapture -l<id>` needs a window id, and only the window server sees
//  what a `CAMetalLayer` actually put on screen. Compiled on demand by
//  capture-live.sh.

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Spektrafilm"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list
    .filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
    .compactMap { w -> (Int, Double, Double)? in
        guard let n = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return nil }
        return (n, width, height)
    }
    .sorted { $0.1 * $0.2 > $1.1 * $1.2 }
for (n, w, h) in windows { print("\(n) \(Int(w))x\(Int(h))") }
if windows.isEmpty { exit(1) }
