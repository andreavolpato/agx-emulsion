//  FeatureFlags.swift — the switches that decide what the interface offers.
//
//  There is exactly one rule for what belongs here: a feature whose *code* is
//  worth keeping but whose *design* is not settled. Deleting such a feature
//  loses the work; shipping it teaches the user a shape that is about to
//  change. A flag keeps both the code and the honesty.
//
//  Each flag says who owns the decision and what has to happen before it
//  flips. A flag with no such note is a flag nobody will ever dare remove.

import Foundation

enum FeatureFlags {

    /// The 蒙版 (mask) system: local adjustments with a region.
    ///
    /// **Off, deliberately, and not because the code is broken.** The model
    /// (`Model/Mask.swift`), the kernel (`maskCoverage` in `Shaders.metal`),
    /// the sublayer (`Panels/Sections/MasksSection.swift`), the canvas
    /// controls (`Canvas/MaskOverlay.swift`) and the tests (`MaskTests`) all
    /// work and all stay. What is not settled is the *interaction design* —
    /// the user is writing the PRD, the interaction data and the layout — and
    /// the version built from the Lightroom reference is not the one they
    /// want.
    ///
    /// What the flag actually gates, and why each one matters:
    ///
    /// - `Session.syncMasks` stops packing masks for the kernel. This is the
    ///   important one: it means a sidecar that *already* has masks in it
    ///   renders as though it did not. The masks are still read, still
    ///   written, and still round-trip (`Sidecar` is untouched), so nothing
    ///   is lost — but no saved mask silently affects a picture while the
    ///   feature is not on offer.
    /// - `RightPanel` drops the sublayer, `EditorWindow` drops the overlay,
    ///   `SpektrafilmApp` drops the Mask menu, and `Session.maskHandles`
    ///   returns nothing, so the canvas cannot be dragged by grips that are
    ///   not drawn.
    ///
    /// Flip it back on when the user's own mask PRD lands and the sublayer is
    /// rebuilt to it.
    static let masks = false
}
