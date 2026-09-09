//  Mask.swift — local adjustments (蒙版), on Lightroom's model.
//
//  ## Why not the dodge-and-burn model
//
//  `HANDOFF-MASKS.md` §1 specified a mask as "a shape, a value in stops, and
//  a target", deliberately narrow because that is what a printer's hands can
//  do under an enlarger. It is the physically honest model and it was
//  rejected on use: holding back light is a *technique*, not a control, and
//  reproducing the technique faithfully means the user does arithmetic in
//  stops to say "make the sky less bright and less blue". Lightroom's model —
//  a mask is a region, and a region carries its own set of adjustments — asks
//  for the outcome instead. That is the whole difference and it is a user
//  decision, not a physics one.
//
//  The consequence is architectural and worth stating plainly: because a mask
//  now carries adjustments rather than an exposure offset, masking is
//  **Layer 2 by construction**. It is a local version of what the right panel
//  already does, it runs in the same kernel, it costs the same sub-millisecond
//  the global one does, and it reaches no service. That is why the engine's
//  `exposure_mask` surface was withdrawn from the frontend/backend contract
//  rather than built: it no longer has a customer.
//
//  ## The model
//
//      mask ─┬─ components   how the region is defined; add or subtract
//            ├─ adjustments  what happens inside it
//            ├─ amount       how much of it happens (Lightroom's mask opacity)
//            └─ inverted     the region, or everything else
//
//  A **component** is one shape. A mask is a union of its `add` components
//  minus its `subtract` components — "the sky, minus the trees" is two
//  components in one mask, not two masks. Every component is closed-form
//  except `brush`, so coverage is evaluated per pixel in the shader at
//  whatever resolution the canvas is showing: a radial gradient is exact at
//  400 % zoom and costs no memory at any tier.
//
//  ## Geometry, and why it is stored and not rasterised
//
//  Geometry is small and resolution-independent; a rasterised mask is neither
//  (90 MB per mask at 45 MP). The same argument `CropRect` and `Geometry` are
//  built on. `brush` is the exception and it says so: strokes are stored as
//  points and stamped into one small texture per mask.

import CoreGraphics
import Foundation
import simd

// MARK: - components

enum MaskComponentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case linearGradient, radialGradient, luminanceRange, colorRange, brush

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linearGradient: "Linear Gradient"
        case .radialGradient: "Radial Gradient"
        case .luminanceRange: "Luminance Range"
        case .colorRange: "Colour Range"
        case .brush: "Brush"
        }
    }

    var systemImage: String {
        switch self {
        case .linearGradient: "square.righthalf.filled"
        case .radialGradient: "circle.righthalf.filled"
        case .luminanceRange: "sun.max"
        case .colorRange: "eyedropper"
        case .brush: "paintbrush"
        }
    }

    /// Whether this kind needs a rasterised texture rather than being
    /// evaluated per pixel from its parameters.
    var isRaster: Bool { self == .brush }

    /// Whether the canvas draws draggable handles for it.
    var hasHandles: Bool { self == .linearGradient || self == .radialGradient }
}

/// One stamp along a brush stroke. Radius is normalised to the image's long
/// edge so a stroke keeps its size when the frame is re-rendered at another
/// tier.
struct BrushStamp: Codable, Equatable, Sendable {
    var x: Double, y: Double
    var radius: Double
    var flow: Double
    /// An erasing stamp subtracts from the stroke it is part of. `⌥` while
    /// painting, as in every painting app.
    var erase: Bool = false
}

struct MaskComponent: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: MaskComponentKind = .linearGradient
    /// Subtracted from the mask rather than added to it. The first component
    /// is always additive whatever this says — there is nothing to subtract
    /// from yet.
    var subtract = false
    var inverted = false

    // Linear gradient: the axis. Coverage is 0 before `a`, 1 after `b`.
    var a = CGPoint(x: 0.5, y: 0.2)
    var b = CGPoint(x: 0.5, y: 0.8)
    // Radial gradient: `a` is the centre, `radii` the semi-axes (normalised
    // to the long edge), `angle` its rotation in degrees.
    var radii = CGSize(width: 0.3, height: 0.2)
    var angle: Double = 0
    /// 0…1. For a radial, the fraction of the radius the falloff occupies.
    var feather: Double = 0.5

    // Luminance range: everything between `low` and `high`, with `softness`
    // ramps outside both ends.
    var low: Double = 0
    var high: Double = 1
    var softness: Double = 0.15
    // Colour range: the picked colour and how far from it still counts.
    var color = SIMD3<Double>(0.5, 0.5, 0.5)
    var tolerance: Double = 0.25

    var strokes: [BrushStamp] = []

    static func make(_ kind: MaskComponentKind) -> MaskComponent {
        var c = MaskComponent()
        c.kind = kind
        // Sensible starting shapes, so adding a component does something
        // visible rather than nothing.
        switch kind {
        case .linearGradient: c.a = CGPoint(x: 0.5, y: 0.15); c.b = CGPoint(x: 0.5, y: 0.55)
        case .radialGradient: c.a = CGPoint(x: 0.5, y: 0.5); c.radii = CGSize(width: 0.3, height: 0.3)
        case .luminanceRange: c.low = 0.6; c.high = 1.0; c.softness = 0.2
        case .colorRange: c.tolerance = 0.25
        case .brush: break
        }
        return c
    }

    var summary: String {
        switch kind {
        case .luminanceRange: String(format: "%.0f–%.0f %%", low * 100, high * 100)
        case .brush: "\(strokes.count) stroke\(strokes.count == 1 ? "" : "s")"
        default: ""
        }
    }
}

// MARK: - what happens inside a mask

/// The subset of Layer 2 a mask carries. Curves, colour balance and vignette
/// are deliberately absent: a curve is a global statement about a tone scale,
/// and a vignette is a lens, and neither means anything applied to a region.
/// Lightroom's local panel draws the same line.
struct MaskAdjustments: Codable, Equatable, Sendable {
    var exposure: Double = 0      // stops, −3…3
    var contrast: Double = 0      // −50…50
    var brightness: Double = 0    // −50…50
    var saturation: Double = 0    // −100…100
    var highlights: Double = 0    // −100…100
    var shadows: Double = 0       // −100…100
    var blackPoint: Double = 0    // 0…50
    var whitePoint: Double = 0    // 0…50
    var temperature: Double = 0   // −100…100
    var tint: Double = 0          // −100…100

    static let `default` = MaskAdjustments()
    var isNeutral: Bool { self == MaskAdjustments() }

    /// The same arithmetic the global Layer 2 uses, through the one shared
    /// function, so "+1 stop on a mask" and "+1 stop globally" cannot drift
    /// apart.
    var uniforms: Layer2Uniforms {
        Layer2Uniforms.tone(temperature: temperature, tint: tint, exposure: exposure,
                            contrast: contrast, brightness: brightness, saturation: saturation,
                            highlights: highlights, shadows: shadows,
                            blackPoint: blackPoint, whitePoint: whitePoint)
    }
}

// MARK: - the mask

struct EditMask: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String = "Mask"
    var enabled = true
    /// The whole region, or everything outside it.
    var inverted = false
    /// Lightroom's mask opacity: 0…1 over the whole thing.
    var amount: Double = 1
    var components: [MaskComponent] = []
    var adjustments = MaskAdjustments()

    /// The most masks the shader carries. Eight is what fits comfortably in
    /// one uniform buffer and one texture array, and it is more than a
    /// photograph has ever needed; the list refuses to add a ninth rather
    /// than silently dropping it.
    static let maxCount = 8
    /// Per mask. A union of six shapes is already an unusual mask.
    static let maxComponents = 6

    var isEmpty: Bool { components.isEmpty }
    var needsRaster: Bool { components.contains { $0.kind.isRaster } }

    static func make(_ kind: MaskComponentKind, named name: String? = nil) -> EditMask {
        var m = EditMask()
        m.name = name ?? kind.label
        m.components = [.make(kind)]
        return m
    }

    var summary: String {
        guard !components.isEmpty else { return "empty" }
        let parts = components.map { ($0.subtract ? "− " : "") + $0.kind.label }
        return parts.joined(separator: ", ")
    }
}

// MARK: - the uniforms the kernel reads

/// One component, packed. Must match `MaskComponentUniform` in Shaders.metal
/// field for field and in order.
struct MaskComponentUniform: Sendable {
    var kind: UInt32 = 0
    var subtract: UInt32 = 0
    var inverted: UInt32 = 0
    var pad0: UInt32 = 0
    var a = SIMD2<Float>(0, 0)
    var b = SIMD2<Float>(0, 0)
    var radii = SIMD2<Float>(0, 0)
    var cosSin = SIMD2<Float>(1, 0)
    var range = SIMD4<Float>(0, 1, 0.15, 0)   // low, high, softness, tolerance
    var color = SIMD4<Float>(0, 0, 0, 0)
    var feather: Float = 0.5
    var pad1 = SIMD3<Float>(0, 0, 0)
}

/// One mask, packed. Must match `MaskUniform` in Shaders.metal.
struct MaskUniform: Sendable {
    var adjustments = Layer2Uniforms()
    var components = (MaskComponentUniform(), MaskComponentUniform(), MaskComponentUniform(),
                      MaskComponentUniform(), MaskComponentUniform(), MaskComponentUniform())
    var componentCount: UInt32 = 0
    var inverted: UInt32 = 0
    var amount: Float = 1
    /// Slice in the mask texture array, or `noRaster`.
    var rasterSlice: Int32 = MaskUniform.noRaster

    static let noRaster: Int32 = -1
}

extension EditMask {
    /// Pack for the kernel. `rasterSlice` is assigned by the rasteriser, and
    /// is −1 for a mask with no brush component — which is most of them, and
    /// is why the texture array is usually empty.
    func uniform(rasterSlice: Int32 = MaskUniform.noRaster) -> MaskUniform {
        var u = MaskUniform()
        u.adjustments = adjustments.uniforms
        u.inverted = inverted ? 1 : 0
        u.amount = Float(amount)
        u.rasterSlice = needsRaster ? rasterSlice : MaskUniform.noRaster
        let list = components.prefix(EditMask.maxComponents).enumerated().map { i, c -> MaskComponentUniform in
            var cu = MaskComponentUniform()
            cu.kind = UInt32(MaskComponentKind.allCases.firstIndex(of: c.kind) ?? 0)
            // The first component has nothing to subtract from, so it is
            // additive whatever the flag says.
            cu.subtract = (i > 0 && c.subtract) ? 1 : 0
            cu.inverted = c.inverted ? 1 : 0
            cu.a = SIMD2(Float(c.a.x), Float(c.a.y))
            cu.b = SIMD2(Float(c.b.x), Float(c.b.y))
            cu.radii = SIMD2(Float(max(c.radii.width, 1e-4)), Float(max(c.radii.height, 1e-4)))
            let r = c.angle * .pi / 180
            cu.cosSin = SIMD2(Float(cos(r)), Float(sin(r)))
            cu.range = SIMD4(Float(c.low), Float(c.high), Float(max(c.softness, 1e-4)), Float(max(c.tolerance, 1e-4)))
            cu.color = SIMD4(Float(c.color.x), Float(c.color.y), Float(c.color.z), 0)
            cu.feather = Float(c.feather)
            return cu
        }
        u.componentCount = UInt32(list.count)
        for (i, c) in list.enumerated() {
            switch i {
            case 0: u.components.0 = c
            case 1: u.components.1 = c
            case 2: u.components.2 = c
            case 3: u.components.3 = c
            case 4: u.components.4 = c
            default: u.components.5 = c
            }
        }
        return u
    }
}

// MARK: - the shared tone arithmetic

extension Layer2Uniforms {
    /// The Layer 2 tone block, built once and used by both the global
    /// adjustments and every mask. Two copies of these formulas is two
    /// chances for "+1 stop" to mean two different things depending on where
    /// the slider was.
    static func tone(temperature: Double, tint: Double, exposure: Double, contrast: Double,
                     brightness: Double, saturation: Double, highlights: Double, shadows: Double,
                     blackPoint: Double, whitePoint: Double) -> Layer2Uniforms {
        var u = Layer2Uniforms()
        u.enabled = 1
        let t = Float(temperature) / 100, g = Float(tint) / 100
        u.wbGain = SIMD3<Float>(1 + 0.18 * t, 1 - 0.12 * g, 1 - 0.18 * t)
        u.exposureGain = Float(pow(2.0, exposure))
        u.contrast = Float(contrast) / 100
        u.brightness = Float(brightness) / 100
        u.saturation = 1 + Float(saturation) / 100
        u.highlights = Float(highlights) / 100
        u.shadows = Float(shadows) / 100
        u.blackPoint = Float(blackPoint) / 100
        u.whitePoint = Float(whitePoint) / 100
        return u
    }
}
