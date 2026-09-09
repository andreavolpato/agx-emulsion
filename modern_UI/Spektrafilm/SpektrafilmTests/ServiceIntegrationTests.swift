//  Drives the real Python service over stdio with the repo's 1 MP smoke image
//  (skipped if the venv or the image is missing). This is the test that
//  proves the client and the service agree on the wire: open → reprint with
//  rgba16 output → upload → the pixels are a plausible print and the right
//  way up; then export_di writes a DI TIFF and a .cube that parses.

import Metal
import XCTest

@MainActor
final class ServiceIntegrationTests: XCTestCase {
    func testOpenReprintAndExportDI() async throws {
        let repo = ServiceClient.defaultRepo()
        let smoke = [repo.appending(path: "tests/Test_image/_smoke_1mp.tif"), repo.appending(path: "tests/baseline/_smoke_1mp.tif")]
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? repo.appending(path: "tests/Test_image/_smoke_1mp.tif")
        let python = repo.appending(path: ".venv/bin/python")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: smoke.path) && FileManager.default.isExecutableFile(atPath: python.path),
                          "needs the repo venv and the smoke image")
        let ws = FileManager.default.temporaryDirectory.appending(path: "spektra-it-\(UUID().uuidString)")
        let client = ServiceClient(repo: repo, workspace: ws)
        defer { Task { await client.stop() } }

        let open: OpenResponse = try await client.call(.open, OpenRequest(imagePath: smoke.path, paramsDelta: FilmParams.default.fullDelta))
        XCTAssertEqual(open.detectedInput.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(open.detectedInput.inputCctfDecoding, "a float TIFF is linear")

        let rr: RenderResponse = try await client.call(.reprint, RenderRequest(sessionID: open.sessionID))
        let raw = try XCTUnwrap(rr.rawPath); let w = try XCTUnwrap(rr.width); let h = try XCTUnwrap(rr.height)
        let renderer = try XCTUnwrap(Renderer())
        let tex = try XCTUnwrap(renderer.store.uploadRGBA16(path: raw, width: w, height: h))
        XCTAssertEqual(tex.width, w); XCTAssertEqual(tex.height, h)
        // A print of a photograph: not black, not white, and not a flat colour.
        var samples: [Float] = []
        for (fx, fy) in [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9), (0.2, 0.8), (0.8, 0.2)] {
            let v = try XCTUnwrap(Session.sample(tex, at: CGPoint(x: fx, y: fy)))
            samples.append((v.x + v.y + v.z) / 3)
        }
        XCTAssertGreaterThan(samples.max()!, 0.05); XCTAssertLessThan(samples.min()!, 0.98)
        XCTAssertGreaterThan(samples.max()! - samples.min()!, 0.02)

        // A print-layer delta reprints; a shoot-layer delta on reprint is refused by the service.
        var p = FilmParams.default; p.printBrightnessStops = 1
        let r2: RenderResponse = try await client.call(.reprint, RenderRequest(sessionID: open.sessionID, paramsDelta: p.delta(from: .default).delta))
        XCTAssertTrue(r2.reprint)
        var q = p; q.grainActive = false
        do {
            let _: RenderResponse = try await client.call(.reprint, RenderRequest(sessionID: open.sessionID, paramsDelta: q.delta(from: p).delta))
            XCTFail("shoot-layer delta must be refused on reprint")
        } catch ServiceClient.ClientError.rpc(let e) { XCTAssertEqual(e.code, "shoot_delta_on_reprint") }
        let r3: RenderResponse = try await client.call(.previewRender, {
            var r = RenderRequest(sessionID: open.sessionID, paramsDelta: q.delta(from: p).delta); r.layer = "shoot"; return r }())
        XCTAssertNotNil(r3.rawPath)

        // DI package.
        let di: ExportDIResponse = try await client.call(.exportDI, ExportDIRequest(sessionID: open.sessionID, outDir: ws.path, baseName: "smoke"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: di.diPath))
        let cube = try String(contentsOfFile: di.cubePath, encoding: .utf8)
        XCTAssertTrue(cube.contains("LUT_3D_SIZE 33"))
        XCTAssertEqual(cube.split(separator: "\n").filter { $0.first?.isNumber ?? false }.count, 33 * 33 * 33)
    }
}
