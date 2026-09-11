//  EngineMessage.swift — an engine failure, said to the person who is looking
//  at it.
//
//  `spk_last_error` is written for whoever is changing the engine, and it
//  should be: "run engine/build.sh bundle" is the fastest possible answer for
//  a developer and completely useless to a photographer, who has no checkout,
//  no build script and nothing to do with either. That was the last item on
//  HANDOFF-DISTRIBUTION §2.6, and it is a shipping problem rather than a
//  cosmetic one — a message a user cannot act on turns a fixable install into
//  an app that "just doesn't work".
//
//  Two rules here, and the second is the one that keeps this honest:
//
//  1. **Only the classes that actually reach a user are rewritten.** A
//     mistranslated error is worse than a technical one, so anything not
//     recognised is passed through rather than replaced with a shrug.
//  2. **The technical text is never destroyed.** `technical(_:)` is what a
//     log line and a bug report carry, and the rewritten message keeps the
//     original in parentheses wherever it might narrow the problem down.
//     Hiding it would trade one unusable report for another.

import Foundation

enum EngineMessage {

    /// The engine's own words, unabridged. For a log, a bug report, and the
    /// canvas trace — never the only thing a user is shown.
    static func technical(_ error: Error) -> String { "\(error)" }

    /// The same failure, for someone who did not build this.
    static func userFacing(_ error: Error) -> String {
        let raw = "\(error)"
        let lower = raw.lowercased()

        // A cancelled render is not a failure and must not read like one.
        if lower.contains("cancelled") { return "The render was cancelled." }

        // An incomplete install. This is the case the handoff named: the
        // engine says "the engine's resources are missing at … ; run
        // engine/build.sh bundle", which is right for a checkout and
        // meaningless for a download.
        if lower.contains("resources are missing") || lower.contains("build.sh")
            || lower.contains("bake_resources") || lower.contains("metallib") {
            return "This copy of Spektrafilm is missing part of itself and cannot render. "
                 + "Download it again, or move it out of the disk image into Applications "
                 + "if it is still running from there. (\(raw))"
        }

        // The fast-math guard fired. The engine refused to start rather than
        // render inaccurately, which is the right call and needs saying as
        // one — the app is not broken, this build of it is.
        if lower.contains("fast math") {
            return "This build of Spektrafilm was compiled with a maths setting that would "
                 + "render colours slightly wrong, so it refused to start rather than lie to "
                 + "you. Please report the build you downloaded. (\(raw))"
        }

        // No Metal device, or one the engine could not use.
        if lower.contains("no metal") || lower.contains("mtldevice")
            || lower.contains("metal device") {
            return "Spektrafilm needs a Metal-capable GPU and could not find one on this Mac."
        }

        // The frame is bigger than the engine will accept.
        if lower.contains("too large") || lower.contains("max_mp") || lower.contains("megapixel") {
            return "This frame is larger than Spektrafilm can render. (\(raw))"
        }

        // A print stock with no baked preview LUT. The engine's message
        // already lists what is available, which is the useful half; what it
        // does not say is that the *print itself* is unaffected.
        if lower.contains("print-preview lut") || lower.contains("print_luts.json") {
            return "There is no baked preview for that paper, so the fast flip is unavailable "
                 + "for it — printing on it still works normally. (\(raw))"
        }

        // Out of memory, most likely at the full tier.
        if lower.contains("out of memory") || lower.contains("allocation") {
            return "Spektrafilm ran out of memory rendering this frame at full resolution. "
                 + "Closing other applications, or zooming out so a smaller tier is used, "
                 + "usually gets past it. (\(raw))"
        }

        // Not recognised: pass it through. A wrong guess about what a user
        // should do is worse than an unfamiliar sentence.
        return raw
    }
}
