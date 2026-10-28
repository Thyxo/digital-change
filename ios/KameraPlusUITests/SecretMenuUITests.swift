import XCTest

/// Hemmelig menu og panik på simulatoren (uden kamera kører appen på den syntetiske testvideo).
final class SecretMenuUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-effectActive", "YES", "-testVideo", "YES"]
        app.launch()
        _ = app.buttons["shutter"].waitForExistence(timeout: 10)
        sleep(2)   // lad appen falde til ro efter start (farvetabeller bygges i baggrunden)
    }

    private var topLeft: XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.03)) }
    private var topRight: XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.03)) }
    private var done: XCUIElement { app.buttons["doneButton"] }

    private func tap(_ c: XCUICoordinate, times: Int, pause: TimeInterval = 0) {
        for i in 0..<times {
            c.tap()
            if pause > 0 && i < times - 1 { Thread.sleep(forTimeInterval: pause) }
        }
    }

    /// 5 hurtige tryk – med op til 3 forsøg, hvis simulatoren er langsom.
    private func openMenu() {
        var opened = false
        for _ in 0..<4 where !opened {
            tap(topLeft, times: 5)
            opened = done.waitForExistence(timeout: 4)
            if !opened { sleep(3) }
        }
        XCTAssertTrue(opened, "Menuen åbnede ikke")
    }

    func testFiveTapsTopLeftOpensMenu() {
        openMenu()
    }

    func testFourTapsDoNotOpenMenu() {
        tap(topLeft, times: 4)
        XCTAssertFalse(done.waitForExistence(timeout: 2), "4 tryk åbnede menuen")
    }

    func testFiveSlowTapsDoNotOpenMenu() {
        tap(topLeft, times: 5, pause: 0.8)   // over 3 sek. i alt
        XCTAssertFalse(done.waitForExistence(timeout: 2), "5 langsomme tryk åbnede menuen")
    }

    func testFiveTapsTopRightDoNothing() {
        tap(topRight, times: 5)
        XCTAssertFalse(done.waitForExistence(timeout: 2), "Tryk øverst til højre åbnede menuen")
    }

    /// Simulatoren er for langsom til at ramme det første sekund pålideligt, så testen forlænger
    /// spærretiden til 4 sek. med -doneDelay (samme kode som de 1 sek. i appen).
    func testDoneIgnoredFirstSecond() {
        app.terminate()
        app.launchArguments += ["-doneDelay", "4"]
        app.launch()
        _ = app.buttons["shutter"].waitForExistence(timeout: 10)
        sleep(2)
        openMenu()
        done.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 1), "Færdig lukkede menuen i spærretiden")
        sleep(4)
        done.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: done)
        waitForExpectations(timeout: 4)
    }

    func testPanicTurnsEffectOff() {
        openMenu()
        XCTAssertEqual(app.switches["effectToggle"].value as? String, "1", "Effekten skulle være tændt fra start")
        sleep(1)
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 2))
        sleep(3)   // lad tap-vinduet løbe ud
        topLeft.press(forDuration: 1.4)
        sleep(1)
        openMenu()
        XCTAssertEqual(app.switches["effectToggle"].value as? String, "0", "Panik slog ikke effekten fra")
    }
}
