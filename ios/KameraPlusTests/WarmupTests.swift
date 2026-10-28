import XCTest
#if canImport(KameraLogic)
@testable import KameraLogic
#endif

final class WarmupTests: XCTestCase {
    func testUnblursWhenCardIsCoveredButNotBeforeMinimum() {
        var g = WarmupGate()
        g.begin()
        XCTAssertTrue(g.blurred)
        XCTAssertTrue(g.markerShown)
        XCTAssertEqual(g.update(covered: true, at: 10.0), [])
        // 2 billeder i træk = fundet; sløringen bliver dog til mindst 0,25 sek.
        XCTAssertEqual(g.update(covered: true, at: 10.03), [.locked])
        XCTAssertFalse(g.markerShown)
        XCTAssertTrue(g.blurred)
        XCTAssertEqual(g.update(covered: true, at: 10.26), [.unblur])
        XCTAssertFalse(g.blurred)
        XCTAssertEqual(g.update(covered: false, at: 11), [])
    }

    func testMaxTimeThenMarkerStaysUntilFound() {
        var g = WarmupGate()
        g.begin()
        _ = g.update(covered: false, at: 0)
        XCTAssertEqual(g.update(covered: true, at: 1.0), [])          // ét billede er ikke nok
        XCTAssertEqual(g.update(covered: false, at: 1.2), [])
        XCTAssertEqual(g.update(covered: false, at: 1.5), [.unblur])  // maks 1,5 sek.
        XCTAssertTrue(g.markerShown, "markøren skal vise, at kortet ikke er dækket endnu")
        _ = g.update(covered: true, at: 2.0)
        XCTAssertEqual(g.update(covered: true, at: 2.03), [.locked])
        XCTAssertFalse(g.markerShown)
    }

    func testTimeCountsFromFirstFrameAndCancel() {
        var g = WarmupGate()
        g.begin()
        // kameraet starter først efter et stykke tid: tiden tælles fra første billede
        XCTAssertEqual(g.update(covered: false, at: 100), [])
        XCTAssertEqual(g.update(covered: false, at: 101.4), [])
        XCTAssertEqual(g.cancel(), [.locked, .unblur])
        XCTAssertFalse(g.blurred)
        XCTAssertFalse(g.markerShown)
        XCTAssertEqual(g.cancel(), [])
    }

    func testNotRunningByDefault() {
        var g = WarmupGate()
        XCTAssertFalse(g.blurred)
        XCTAssertFalse(g.markerShown)
        XCTAssertEqual(g.update(covered: false, at: 0), [])
    }

    func testSearchAreaFollowsViewfinderGrid() {
        // portrætbillede 1080×1920 i 3:4-søgeren: hele bredden ses, højden beskæres
        let r = SearchArea.middle.frameRegion(frameWidth: 1080, frameHeight: 1920, zoom: 1)!
        XCTAssertEqual(r.minX, 360, accuracy: 1e-6)
        XCTAssertEqual(r.maxX, 720, accuracy: 1e-6)
        XCTAssertEqual(r.center.y, 960, accuracy: 1e-6)
        XCTAssertEqual(r.height, 1440.0 / 3, accuracy: 1e-6)
        // med zoom 1,25 bliver feltet mindre i billedet
        let z = SearchArea.middle.frameRegion(frameWidth: 1080, frameHeight: 1920, zoom: 1.25)!
        XCTAssertEqual(z.width, 360 / 1.25, accuracy: 1e-6)
        let around = SearchArea.aroundMiddle.frameRegion(frameWidth: 1080, frameHeight: 1920, zoom: 1)!
        XCTAssertLessThan(around.minX, r.minX)
        XCTAssertGreaterThan(around.maxX, r.maxX)
        XCTAssertNil(SearchArea.whole.frameRegion(frameWidth: 1080, frameHeight: 1920, zoom: 1))
    }
}

final class SearchRegionTests: XCTestCase {
    private func image(_ t: CardTemplate, center: Point2) -> (Quad, RGBAImage) {
        var s = SynthScene(width: 540, height: 720)
        s.backdrop = .gray; s.backdropColor = RGB8(95, 95, 95)
        s.noise = 2
        let c = SynthCard.placed(t, center: center, width: 200, angle: 0.15)
        s.card = c
        return (c.quad, Synth.render(s).image)
    }

    func testOnlyFindsCardAroundTheMiddle() throws {
        let t = try Fixtures.templates()
        let region = SearchArea.aroundMiddle.frameRegion(frameWidth: 540, frameHeight: 720, zoom: 1.25)!
        let (_, edge) = image(t.blue, center: Point2(110, 200))
        let (_, middle) = image(t.blue, center: Point2(285, 370))
        let tracker = CardTracker(template: t.blue)
        XCTAssertNotNil(tracker.update(edge).track, "uden søgeområde findes kortet overalt")
        tracker.reset()
        tracker.config.searchRegion = region
        XCTAssertNil(tracker.update(edge).track, "kort i kanten skal ikke findes")
        tracker.reset()
        let d = Date()
        XCTAssertNotNil(tracker.update(middle).track)
        print(String(format: "Første fund (midten, 540×720): %.0f ms", Date().timeIntervalSince(d) * 1000))
    }

    func testFollowsCardOutOfTheRegionOnceFound() throws {
        let t = try Fixtures.templates()
        let tracker = CardTracker(template: t.blue)
        tracker.config.searchRegion = SearchArea.middle.frameRegion(frameWidth: 540, frameHeight: 720, zoom: 1.25)
        for f in 0..<14 {
            let (q, img) = image(t.blue, center: Point2(270 - Double(f) * 10, 360 - Double(f) * 8))
            let r = tracker.update(img)
            let tr = try XCTUnwrap(r.track, "tabt i billede \(f)")
            XCTAssertLessThan(tr.quad.centroid.distance(q.centroid), 2, "billede \(f)")
        }
    }
}
