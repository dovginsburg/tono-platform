// Build97BackspaceStateTests.swift
// State-machine, rapid-input, and latency coverage for the Apple-fidelity
// backspace repeat engine (`BackspaceRepeatEngine`).
//
// The engine is a pure value type driven by wall-clock ticks, so every case
// here is deterministic — no sleeps, no timers. A fixed base `Date` is
// advanced with `addingTimeInterval` to model exactly what the host timer
// would deliver.

import XCTest

final class Build97BackspaceStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var cfg: BackspaceRepeatConfig { BackspaceRepeatConfig() }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - State transitions

    func testIdleEngineNeverFires() {
        var engine = BackspaceRepeatEngine()
        XCTAssertFalse(engine.isPressed)
        XCTAssertEqual(engine.tick(at: at(0)), 0)
        XCTAssertEqual(engine.tick(at: at(10)), 0)
        XCTAssertFalse(engine.isPressed)
    }

    func testPressSchedulesRepeatWithoutFiringImmediately() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        XCTAssertTrue(engine.isPressed)
        // press() must NOT fire — the host already fired the touchDown delete.
        XCTAssertEqual(engine.phase, .waitingForFirstRepeat(pressedAt: at(0)))
        // Before the 500ms first-repeat delay, nothing repeats.
        XCTAssertEqual(engine.tick(at: at(0.25)), 0)
        XCTAssertEqual(engine.tick(at: at(0.499)), 0)
    }

    func testFirstRepeatFiresExactlyOnceAt500ms() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        XCTAssertEqual(engine.tick(at: at(0.5)), 1, "first repeat must fire at the 500ms threshold")
        if case .repeating = engine.phase {} else {
            XCTFail("engine must enter the repeating phase after the first repeat")
        }
    }

    func testReleaseReturnsToIdleAndCancelsRepeats() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        _ = engine.tick(at: at(0.5))
        engine.release()
        XCTAssertFalse(engine.isPressed)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.tick(at: at(5)), 0, "a released hold must never fire again")
    }

    // MARK: - Steady repeat cadence

    func testSteadyRepeatAveragesOnePerBaseInterval() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        var now = 0.5
        XCTAssertEqual(engine.tick(at: at(now)), 1)          // first repeat
        // Ticking at exactly the base interval, floating-point drift can push a
        // single tick to 0 or 2, but the total across ten intervals must be
        // exactly ten deletes — one per interval, no drift, no runaway.
        var total = 0
        for _ in 0..<10 {
            now += cfg.baseRepeatInterval
            let fired = engine.tick(at: at(now))
            XCTAssertLessThanOrEqual(fired, 2, "steady ticking must not burst")
            total += fired
        }
        XCTAssertEqual(total, 10, "ten base intervals must yield exactly ten deletes")
    }

    // MARK: - Rapid input / latency catch-up

    func testDelayedTickCatchesUpProportionallyAndBounded() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        XCTAssertEqual(engine.tick(at: at(0.5)), 1)
        // The host timer stalls for a full second (a latency spike). The next
        // tick must catch up: floor(1.0 / 0.105) = 9 deletes, never more than
        // the elapsed window could physically contain.
        let fired = engine.tick(at: at(1.5))
        XCTAssertEqual(fired, 9, "a 1.0s stall at the base interval must catch up to 9 deletes")
        let maxPossible = Int(1.0 / cfg.minimumRepeatInterval) + 1
        XCTAssertLessThanOrEqual(fired, maxPossible, "catch-up must stay physically bounded")
    }

    func testCatchUpAdvancesClockSoNextTickDoesNotDoubleCount() {
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        _ = engine.tick(at: at(0.5))
        let burst = engine.tick(at: at(1.5))
        XCTAssertEqual(burst, 9)
        // Immediately ticking again with no elapsed time must fire nothing —
        // the engine consumed the burst and advanced its internal clock.
        XCTAssertEqual(engine.tick(at: at(1.5)), 0, "no time elapsed → no phantom deletes")
    }

    func testRapidPressReleasePressResetsCleanly() {
        var engine = BackspaceRepeatEngine()
        for cycle in 0..<5 {
            let base = Double(cycle)
            engine.press(at: at(base))
            XCTAssertEqual(engine.tick(at: at(base + 0.2)), 0, "cycle \(cycle): too soon to repeat")
            engine.release()
            XCTAssertEqual(engine.tick(at: at(base + 0.9)), 0, "cycle \(cycle): released hold must stay silent")
        }
    }

    // MARK: - Long-hold acceleration ramp

    func testIntervalRampsDownAfterThreeAndAHalfSeconds() {
        let engine = BackspaceRepeatEngine()
        let pressed = at(0)
        // Before the ramp, the interval is the base value.
        XCTAssertEqual(engine.currentInterval(pressedAt: pressed, now: at(1.0)), cfg.baseRepeatInterval, accuracy: 1e-9)
        XCTAssertEqual(engine.currentInterval(pressedAt: pressed, now: at(3.5)), cfg.baseRepeatInterval, accuracy: 1e-9)
        // 1.5s into the ramp: base - 1.5 * 0.015 = 0.0825.
        XCTAssertEqual(engine.currentInterval(pressedAt: pressed, now: at(5.0)), 0.0825, accuracy: 1e-9)
    }

    func testIntervalNeverGoesBelowMinimumOnVeryLongHold() {
        let engine = BackspaceRepeatEngine()
        let pressed = at(0)
        // A 60-second hold must clamp to the minimum interval, never negative.
        let interval = engine.currentInterval(pressedAt: pressed, now: at(60))
        XCTAssertEqual(interval, cfg.minimumRepeatInterval, accuracy: 1e-9)
        XCTAssertGreaterThan(interval, 0)
    }

    func testTenSecondHoldClearsRoughlyAppleCharacterCount() {
        // Model a full 10s hold as the host would: fire the first repeat, then
        // tick every 50ms and sum the deletes. Apple clears ~70-95 chars over
        // a 10s hold; assert we land in that human-observed band.
        var engine = BackspaceRepeatEngine()
        engine.press(at: at(0))
        var deletes = 0
        var now = 0.5
        while now <= 10.0 {
            deletes += engine.tick(at: at(now))
            now += 0.05
        }
        XCTAssertGreaterThan(deletes, 70, "a 10s hold should clear a substantial run of characters")
        XCTAssertLessThan(deletes, 160, "acceleration must stay bounded, not runaway")
    }
}
