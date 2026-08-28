//  DecodeProbe.swift — headless check of the real decode path.
//
//  Compiles the app's own ImageDecoder.swift, runs a file through it, renders
//  to a texture with exactly the app's settings, reads the pixels back and
//  prints per-channel statistics.
//
//  This exists because "the canvas looks wrong" localises to one of three
//  places — decode, upload, or shader — and only the first two can be
//  inspected without a display. Anything this probe reports as correct is a
//  shader problem; anything it reports as wrong is not.
//
//  Build:  see Tools/probe.sh

import Foundation
import CoreImage
import Metal

func stats(_ label: String, _ values: [Float], stride: Int, offset: Int) -> String {
    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude, sum = 0.0
    var n = 0
    for i in Swift.stride(from: offset, to: values.count, by: stride) {
        lo = min(lo, values[i]); hi = max(hi, values[i])
        sum += Double(values[i]); n += 1
    }
    return String(format: "%@  min %.4f  max %.4f  mean %.4f", label, lo, hi, sum / Double(max(n, 1)))
}

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: DecodeProbe <file> [more files...]"); exit(1)
}

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    print("no Metal device"); exit(1)
}
let ciContext = CIContext(mtlDevice: device, options: [
    .workingColorSpace: ImageDecoder.compositingSpace as Any,
    .cacheIntermediates: false,
])

for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    print("\n=== \(url.lastPathComponent)")
    do {
        let d = try ImageDecoder.decode(url)
        print("  decoder      \(d.decoder.rawValue)")
        print("  pixels       \(Int(d.pixelSize.width)) x \(Int(d.pixelSize.height))")
        print("  linear       \(d.isLinear)")
        print("  working      \((d.workingSpace.name as String?) ?? "unnamed")")
        print("  CIImage cs   \((d.image.colorSpace?.name as String?) ?? "nil")")
        print("  extent       \(d.image.extent)")

        // Same call the renderer makes, but into a readable texture.
        let maxEdge = 512
        let extent = d.image.extent
        let scale = min(1.0, Double(maxEdge) / Double(max(extent.width, extent.height)))
        let scaled = scale < 1 ? d.image.transformed(by: .init(scaleX: scale, y: scale)) : d.image
        let target = scaled.extent.integral

        // Try each candidate format. Core Image silently renders nothing
        // into a format it does not support as an output, so "did anything
        // arrive" has to be measured, not assumed.
        let candidates: [(String, MTLPixelFormat, MTLTextureUsage)] = [
            // Left in as a regression check: the first entry is the broken
            // configuration and must report ALL ZERO, the second is what the
            // app ships. If the first ever starts working, the comment in
            // ImageDecoder.makeTexture is stale.
            ("without shaderWrite (must be ALL ZERO)", .rgba16Unorm, [.shaderRead, .renderTarget]),
            ("as shipped                            ", .rgba16Unorm, [.shaderRead, .renderTarget, .shaderWrite]),
        ]
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { continue }
        for (name, format, usage) in candidates {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: Int(target.width), height: Int(target.height), mipmapped: false)
            desc.usage = usage
            desc.storageMode = .shared      // .private in the app; shared to read back
            guard let tex = device.makeTexture(descriptor: desc),
                  let buf = queue.makeCommandBuffer() else {
                print("  \(name): texture creation failed"); continue
            }
            ciContext.render(scaled.transformed(by: .init(translationX: -target.origin.x,
                                                          y: -target.origin.y)),
                             to: tex, commandBuffer: buf,
                             bounds: CGRect(origin: .zero, size: target.size),
                             colorSpace: p3)
            buf.commit(); buf.waitUntilCompleted()
            if let e = buf.error { print("  \(name): command buffer error \(e)"); continue }

            let bpp = format == .rgba8Unorm ? 4 : (format == .rgba16Float ? 8 : 8)
            var f: [Float]
            if format == .rgba8Unorm {
                var raw = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
                raw.withUnsafeMutableBytes { p in
                    tex.getBytes(p.baseAddress!, bytesPerRow: tex.width * bpp,
                                 from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
                f = raw.map { Float($0) / 255.0 }
            } else if format == .rgba16Float {
                var raw = [Float16](repeating: 0, count: tex.width * tex.height * 4)
                raw.withUnsafeMutableBytes { p in
                    tex.getBytes(p.baseAddress!, bytesPerRow: tex.width * bpp,
                                 from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
                f = raw.map { Float($0) }
            } else {
                var raw = [UInt16](repeating: 0, count: tex.width * tex.height * 4)
                raw.withUnsafeMutableBytes { p in
                    tex.getBytes(p.baseAddress!, bytesPerRow: tex.width * bpp,
                                 from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0) }
                f = raw.map { Float($0) / 65535.0 }
            }
            let allZero = !f.contains { $0 != 0 }
            print("  \(name): \(allZero ? "ALL ZERO" : "ok")")
            if !allZero {
                print("    " + stats("R", f, stride: 4, offset: 0))
                print("    " + stats("G", f, stride: 4, offset: 1))
                print("    " + stats("B", f, stride: 4, offset: 2))
            }
        }
    } catch {
        print("  !! \(error)")
    }
}
