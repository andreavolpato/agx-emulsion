import XCTest

final class ParamsTests: XCTestCase {
    func testDeltaIsEmptyForEqualParams() {
        let (d, l) = FilmParams.default.delta(from: .default)
        XCTAssertTrue(d.isEmpty); XCTAssertTrue(l.isEmpty)
    }

    func testPrintSliderRoutesToPrintLayer() {
        var p = FilmParams.default
        p.printBrightnessStops = 1
        let (d, l) = p.delta(from: .default)
        XCTAssertEqual(l, [.print])
        XCTAssertEqual(d["print_exposure"]?.doubleValue ?? 0, 0.5, accuracy: 1e-9, "brighter by one stop = half the enlarger exposure")
    }

    func testShootFieldsRouteToShootLayer() {
        var p = FilmParams.default
        p.grainActive = false
        p.filmFormatMM = 56
        let (d, l) = p.delta(from: .default)
        XCTAssertEqual(l, [.shoot])
        XCTAssertEqual(Set(d.keys), ["grain_active", "grain_sublayers_active", "film_format_mm"])
    }

    func testFilmChangeInvalidatesBothLayers() {
        var p = FilmParams.default
        p.filmStock = "kodak_vision3_250d"
        XCTAssertEqual(p.delta(from: .default).layers, [.shoot, .print])
    }

    func testWireNamesMatchTheServiceSchema() {
        // The names the Python schema declares (service/schema.py). A rename
        // there must be mirrored here or the delta is rejected at runtime.
        let known: Set<String> = ["film_stock", "print_stock", "exposure_compensation_ev", "film_format_mm",
                                  "grain_active", "grain_sublayers_active", "halation_active", "print_exposure",
                                  "y_filter_shift", "m_filter_shift", "glare_active", "scan_film"]
        XCTAssertEqual(Set(FilmParams.default.wire.map(\.name)), known)
    }

    func testFilmFormatsAreWithinTheServiceRange() {
        for f in FilmFormat.all { XCTAssertTrue((4...200).contains(f.mm), f.id) }
    }

    func testParamValueJSON() throws {
        let enc = try JSONEncoder().encode(["a": ParamValue.double(1.5), "b": .bool(true), "c": .string("x")])
        let dec = try JSONDecoder().decode([String: ParamValue].self, from: enc)
        XCTAssertEqual(dec["a"], .double(1.5)); XCTAssertEqual(dec["b"], .bool(true)); XCTAssertEqual(dec["c"], .string("x"))
    }

    func testSidecarRoundTrip() throws {
        var s = Sidecar()
        s.params.yFilterShift = 0.3
        s.adjustments.curves.rgb.insert(CGPoint(x: 0.4, y: 0.5))
        s.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(back, s)
    }
}
