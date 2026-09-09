//  Adjustments.swift — Layer 2: adjustments to the print output, client-side.
//
//  These operate on the encoded print output the way a scan of a print is
//  adjusted afterwards (frontend SPEC §3.1). They live entirely in the Metal
//  shader (`Shaders.metal`, `layer2`) and cost < 1 ms; nothing here reaches
//  the service. Order of operations is fixed and matches the shader:
//
//      white balance → exposure/contrast/brightness → highlights/shadows
//      → black/white point → saturation → colour balance → curves → vignette
//
//  Zero is "nothing applied" for every field, so a fresh image reads as the
//  pure simulation, and `enabled = false` bypasses the whole layer.

import Foundation
import simd

struct ColorZone: Codable, Equatable, Sendable {
    /// Hue angle in degrees, saturation 0…1 (wheel radius), luminance −1…1.
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var isNeutral: Bool { saturation == 0 && luminance == 0 }

    /// The RGB offset this zone applies, in the shader's units.
    var rgbOffset: SIMD3<Float> {
        let h = hue * .pi / 180
        // Hue on the wheel → unit RGB direction (0° = red, 120° = green, 240° = blue).
        let r = cos(h), g = cos(h - 2 * .pi / 3), b = cos(h + 2 * .pi / 3)
        let s = Float(saturation) * 0.25
        return SIMD3<Float>(Float(r), Float(g), Float(b)) * s
    }
}

struct ColorBalance: Codable, Equatable, Sendable {
    var master = ColorZone()
    var shadows = ColorZone()
    var midtones = ColorZone()
    var highlights = ColorZone()
    var isNeutral: Bool { master.isNeutral && shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }
}

struct Vignette: Codable, Equatable, Sendable {
    var amount: Double = 0      // −100…100, negative darkens the corners
    var midpoint: Double = 50   // 0…100, radius at which falloff starts
    var isNeutral: Bool { amount == 0 }
}

struct Adjustments: Codable, Equatable, Sendable {
    var enabled: Bool = true
    // White balance, post-print (Capture One's model, but as an offset).
    var temperature: Double = 0    // −100…100, blue ↔ amber
    var tint: Double = 0           // −100…100, green ↔ magenta
    // Exposure group (Capture One's four).
    var exposure: Double = 0       // stops, −3…3
    var contrast: Double = 0       // −50…50
    var brightness: Double = 0     // −50…50
    var saturation: Double = 0     // −100…100
    // Tone-region recovery.
    var highlights: Double = 0     // −100…100
    var shadows: Double = 0        // −100…100
    var blackPoint: Double = 0     // 0…50  (percent of range lifted to black)
    var whitePoint: Double = 0     // 0…50
    var curves = CurveSet()
    var colorBalance = ColorBalance()
    var vignette = Vignette()

    static let `default` = Adjustments()
    var isNeutral: Bool { self == Adjustments(enabled: enabled) }

    /// The per-frame uniform block the shader reads. Computed on the CPU once
    /// per change, not per pixel.
    var uniforms: Layer2Uniforms {
        var u = Layer2Uniforms()
        u.enabled = enabled ? 1 : 0
        // Temperature/tint as channel gains. ±100 → roughly ±0.18 on the
        // opposing channels, which matches the visual range of a scan WB
        // correction rather than a scene one.
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
        u.cbMaster = colorBalance.master.rgbOffset
        u.cbShadows = colorBalance.shadows.rgbOffset
        u.cbMidtones = colorBalance.midtones.rgbOffset
        u.cbHighlights = colorBalance.highlights.rgbOffset
        u.cbLum = SIMD4<Float>(Float(colorBalance.master.luminance), Float(colorBalance.shadows.luminance),
                               Float(colorBalance.midtones.luminance), Float(colorBalance.highlights.luminance)) * 0.25
        u.vignetteAmount = Float(vignette.amount) / 100
        u.vignetteMidpoint = Float(vignette.midpoint) / 100
        u.curvesActive = curves.isIdentity ? 0 : 1
        return u
    }
}

/// Must match `Layer2Uniforms` in Shaders.metal field for field and in order.
struct Layer2Uniforms: Sendable {
    var wbGain = SIMD3<Float>(repeating: 1)
    var exposureGain: Float = 1
    var cbMaster = SIMD3<Float>(repeating: 0)
    var contrast: Float = 0
    var cbShadows = SIMD3<Float>(repeating: 0)
    var brightness: Float = 0
    var cbMidtones = SIMD3<Float>(repeating: 0)
    var saturation: Float = 1
    var cbHighlights = SIMD3<Float>(repeating: 0)
    var highlights: Float = 0
    var cbLum = SIMD4<Float>(repeating: 0)
    var shadows: Float = 0
    var blackPoint: Float = 0
    var whitePoint: Float = 0
    var vignetteAmount: Float = 0
    var vignetteMidpoint: Float = 0.5
    var curvesActive: UInt32 = 0
    var enabled: UInt32 = 1
    var _pad: UInt32 = 0
}
