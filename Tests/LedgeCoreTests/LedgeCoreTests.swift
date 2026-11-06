import XCTest
@testable import LedgeCore

final class IslandLayoutTests: XCTestCase {
    let notch = NotchMetrics(width: 185, height: 32)

    func testIdleMatchesTheNotch() {
        XCTAssertEqual(IslandLayout.size(for: .idle, notch: notch), CGSize(width: 185, height: 32))
    }

    func testShapesGrowInTheRightOrder() {
        let w = { IslandLayout.size(for: $0, notch: self.notch).width }
        XCTAssertLessThan(w(.idle), w(.hover))
        XCTAssertLessThan(w(.hover), w(.compact))
        XCTAssertLessThan(w(.hud), w(.expanded))
    }

    func testCompactKeepsNotchHeight() {
        XCTAssertEqual(IslandLayout.size(for: .compact, notch: notch).height, notch.height)
    }

    func testSettingsIsTheWidestShape() {
        let settings = IslandLayout.size(for: .settings, notch: notch)
        XCTAssertGreaterThan(settings.width, IslandLayout.size(for: .expanded, notch: notch).width)
        XCTAssertGreaterThan(settings.height, IslandLayout.size(for: .expanded, notch: notch).height)
    }

    func testHUDDropsBelowTheNotch() {
        let hud = IslandLayout.size(for: .hud, notch: notch)
        XCTAssertGreaterThan(hud.height, notch.height + 20)
        XCTAssertGreaterThan(hud.width, notch.width)
        XCTAssertLessThan(hud.height, IslandLayout.size(for: .expanded, notch: notch).height)
    }

    func testPanelFitsEveryShape() {
        let panel = IslandLayout.panelSize(notch: notch)
        for shape: IslandShape in [.idle, .hover, .compact, .hud, .expanded, .settings] {
            let s = IslandLayout.size(for: shape, notch: notch)
            XCTAssertLessThanOrEqual(s.width + 2 * IslandLayout.shoulderRadius(for: shape), panel.width)
            XCTAssertLessThanOrEqual(s.height, panel.height)
        }
    }
}

final class FloatingLayoutTests: XCTestCase {
    let pill = NotchMetrics.floatingPill(menuBarHeight: 25)

    func testPillFitsInsideTheMenuBar() {
        XCTAssertLessThanOrEqual(pill.height + IslandLayout.floatingTopGap, 25)
        XCTAssertGreaterThan(NotchMetrics.floatingPill(menuBarHeight: 0).height, pill.height) // no menu bar: roomier
    }

    func testCollapsedShapesStayInTheMenuBar() {
        for shape: IslandShape in [.idle, .compact, .hud] {
            XCTAssertEqual(IslandLayout.size(for: shape, notch: pill, style: .floating).height, pill.height)
        }
    }

    func testPillIsRoundAllOverAndHasNoShoulders() {
        for shape: IslandShape in [.idle, .compact, .hud, .expanded] {
            XCTAssertEqual(IslandLayout.topRadius(for: shape, notch: pill, style: .floating),
                           IslandLayout.bottomRadius(for: shape, notch: pill, style: .floating))
            XCTAssertEqual(IslandLayout.shoulderRadius(for: shape, style: .floating), 0)
        }
        XCTAssertEqual(IslandLayout.topRadius(for: .expanded, notch: .fallback, style: .notch), 0)
    }

    func testMusicPillFitsItsContent() {
        let short = IslandLayout.floatingCompactWidth(textWidth: 60, height: 28)
        let long = IslandLayout.floatingCompactWidth(textWidth: 400, height: 28)
        XCTAssertLessThan(short, long)
        XCTAssertLessThanOrEqual(long, 350)                  // capped
        XCTAssertGreaterThanOrEqual(short, 28 * 6)           // never tiny
        let m = IslandLayout.floatingCompactMetrics(height: 28)
        XCTAssertGreaterThan(m.leading, (28 - m.art) / 2)    // art sits further in than its top/bottom gap
        XCTAssertGreaterThan(m.trailing, m.leading)          // bars a touch further in
    }

    func testPanelFitsEveryFloatingShape() {
        let panel = IslandLayout.panelSize(notch: pill, style: .floating)
        for shape: IslandShape in [.idle, .hover, .compact, .hud, .expanded, .settings] {
            let s = IslandLayout.size(for: shape, notch: pill, style: .floating)
            XCTAssertLessThanOrEqual(s.width, panel.width)
            XCTAssertLessThanOrEqual(s.height + IslandLayout.floatingTopGap, panel.height)
        }
    }
}

final class NowPlayingTests: XCTestCase {
    func testParsesBridgeInfoLine() throws {
        let art = Data([1, 2, 3]).base64EncodedString()
        let line = """
        {"type":"info","title":"Song","artist":"Band","duration":200,"elapsed":10,"rate":1,"playing":true,"timestamp":1000,"bundle":"com.spotify.client","artworkId":"3-1","artwork":"\(art)"}
        """
        guard case let .info(state, artwork)? = BridgeParser.parse(Data(line.utf8)) else {
            return XCTFail("expected info")
        }
        XCTAssertEqual(state.title, "Song")
        XCTAssertEqual(state.artist, "Band")
        XCTAssertEqual(state.duration, 200)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.bundleID, "com.spotify.client")
        XCTAssertEqual(artwork, Data([1, 2, 3]))
        XCTAssertTrue(state.hasContent)
    }

    func testParsesReadyAndRejectsGarbage() {
        XCTAssertEqual(BridgeParser.parse(Data(#"{"type":"ready"}"#.utf8)), .ready)
        XCTAssertNil(BridgeParser.parse(Data("not json".utf8)))
        XCTAssertNil(BridgeParser.parse(Data(#"{"type":"mystery"}"#.utf8)))
    }

    func testElapsedMovesOnlyWhilePlaying() {
        var s = NowPlayingState()
        s.title = "x"
        s.duration = 100
        s.elapsed = 10
        s.rate = 1
        s.timestamp = Date(timeIntervalSince1970: 0)
        let later = Date(timeIntervalSince1970: 5)
        s.isPlaying = true
        XCTAssertEqual(s.elapsed(at: later), 15, accuracy: 0.001)
        s.isPlaying = false
        XCTAssertEqual(s.elapsed(at: later), 10, accuracy: 0.001)
    }

    func testElapsedIsClampedToDuration() {
        var s = NowPlayingState()
        s.duration = 30
        s.elapsed = 25
        s.isPlaying = true
        s.timestamp = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(s.elapsed(at: Date(timeIntervalSince1970: 100)), 30)
        XCTAssertEqual(s.progress(at: Date(timeIntervalSince1970: 100)), 1)
    }

    func testEmptyTitleMeansNothingPlaying() {
        var s = NowPlayingState()
        s.title = "  "
        XCTAssertFalse(s.hasContent)
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(65.9), "1:05")
        XCTAssertEqual(formatTime(3725), "1:02:05")
        XCTAssertEqual(formatTime(.nan), "0:00")
    }
}

final class SwipeDetectorTests: XCTestCase {
    func testFiresOncePerGesture() {
        var d = SwipeDetector(threshold: 50)
        XCTAssertNil(d.handle(dx: -10, dy: 0, phase: .began))
        XCTAssertNil(d.handle(dx: -30, dy: 2, phase: .changed))
        XCTAssertEqual(d.handle(dx: -20, dy: 0, phase: .changed), .left)
        XCTAssertNil(d.handle(dx: -80, dy: 0, phase: .changed)) // already fired
        XCTAssertNil(d.handle(dx: 0, dy: 0, phase: .ended))
        XCTAssertNil(d.handle(dx: 30, dy: 0, phase: .began))
        XCTAssertEqual(d.handle(dx: 30, dy: 0, phase: .changed), .right)
    }

    func testIgnoresMostlyVerticalScrolls() {
        var d = SwipeDetector(threshold: 50)
        _ = d.handle(dx: 0, dy: 0, phase: .began)
        XCTAssertNil(d.handle(dx: 60, dy: 50, phase: .changed))
    }
}

final class PageTests: XCTestCase {
    func testMusicPageOnlyWithMedia() {
        XCTAssertEqual(IslandPage.available(hasMedia: true), [.music, .calendar, .timer, .notes])
        XCTAssertEqual(IslandPage.available(hasMedia: false), [.calendar, .timer, .notes])
    }

    func testPagesSwitchedOffInSettingsAreLeftOut() {
        XCTAssertEqual(IslandPage.available(enabled: [.music, .calendar, .timer], hasMedia: true),
                       [.music, .calendar, .timer])
        XCTAssertEqual(IslandPage.available(enabled: [.music], hasMedia: false), [])
    }

    func testSteppingStopsAtTheEnds() {
        let pages = IslandPage.available(hasMedia: true)
        XCTAssertEqual(IslandPage.step(from: .music, forward: true, in: pages), .calendar)
        XCTAssertEqual(IslandPage.step(from: .calendar, forward: true, in: pages), .timer)
        XCTAssertEqual(IslandPage.step(from: .timer, forward: true, in: pages), .notes)
        XCTAssertNil(IslandPage.step(from: .notes, forward: true, in: pages))
        XCTAssertNil(IslandPage.step(from: .music, forward: false, in: pages))
    }

    func testSteppingFromAMissingPageGoesToTheFirst() {
        XCTAssertEqual(IslandPage.step(from: .music, forward: true, in: [.calendar, .timer, .notes]), .calendar)
    }
}

final class CountdownTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)

    func testRunsDownAndFinishesOnce() {
        var c = Countdown(duration: 60)
        c.start(at: t0)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(15)), 45, accuracy: 0.001)
        XCTAssertFalse(c.tick(at: t0.addingTimeInterval(59)))
        XCTAssertTrue(c.tick(at: t0.addingTimeInterval(60)))
        XCTAssertFalse(c.tick(at: t0.addingTimeInterval(61))) // only once
        XCTAssertEqual(c.phase, .finished)
        XCTAssertFalse(c.isActive)
    }

    func testPauseKeepsTheRemainingTime() {
        var c = Countdown(duration: 120)
        c.start(at: t0)
        c.pause(at: t0.addingTimeInterval(20))
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(500)), 100, accuracy: 0.001)
        c.start(at: t0.addingTimeInterval(500))
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(510)), 90, accuracy: 0.001)
    }

    func testAddingTimeAndReset() {
        var c = Countdown(duration: 60)
        c.start(at: t0)
        c.add(60, at: t0)
        XCTAssertEqual(c.remaining(at: t0), 120, accuracy: 0.001)
        c.reset()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.remaining(at: t0), 60) // back to the chosen length
    }

    func testFormat() {
        XCTAssertEqual(formatCountdown(299.2), "5:00")
        XCTAssertEqual(formatCountdown(65), "1:05")
        XCTAssertEqual(formatCountdown(3723), "1:02:03")
        XCTAssertEqual(formatCountdown(0), "0:00")
    }
}

final class PomodoroTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)
    let plan = PomodoroPlan(focusMinutes: 25, shortMinutes: 5, longMinutes: 15, sessions: 4)

    func testCycleOfFourWithALongBreak() {
        var p = Pomodoro(plan: plan)
        var phases: [PomodoroPhase] = []
        for _ in 0..<8 { phases.append(p.advance(at: t0, autoStart: false)) }
        XCTAssertEqual(phases, [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
        XCTAssertEqual(p.completedFocus, 0) // a new cycle after the long break
    }

    func testFinishingAFocusSessionStartsTheBreak() {
        var p = Pomodoro(plan: plan)
        p.start(at: t0)
        XCTAssertNil(p.tick(at: t0.addingTimeInterval(24 * 60), autoStart: true))
        let ended = p.tick(at: t0.addingTimeInterval(25 * 60), autoStart: true)
        XCTAssertEqual(ended?.ended, .focus)
        XCTAssertEqual(ended?.next, .shortBreak)
        XCTAssertTrue(p.countdown.isRunning)
        XCTAssertEqual(p.countdown.remaining(at: t0.addingTimeInterval(25 * 60)), 5 * 60, accuracy: 0.001)
        XCTAssertEqual(p.completedFocus, 1)
    }

    func testWithoutAutoStartTheNextPhaseWaits() {
        var p = Pomodoro(plan: plan)
        p.start(at: t0)
        _ = p.tick(at: t0.addingTimeInterval(25 * 60), autoStart: false)
        XCTAssertFalse(p.countdown.isRunning)
        XCTAssertEqual(p.phase, .shortBreak)
    }

    func testSessionNumberAndReset() {
        var p = Pomodoro(plan: plan)
        XCTAssertEqual(p.sessionNumber, 1)
        p.advance(at: t0, autoStart: false) // break
        p.advance(at: t0, autoStart: false) // focus 2
        XCTAssertEqual(p.sessionNumber, 2)
        XCTAssertEqual(p.nextPhase, .shortBreak)
        p.reset()
        XCTAssertEqual(p.phase, .focus)
        XCTAssertEqual(p.sessionNumber, 1)
    }
}

final class AwakeFormatTests: XCTestCase {
    func testRemaining() {
        XCTAssertEqual(formatAwakeRemaining(57 * 60 + 10), "58m")
        XCTAssertEqual(formatAwakeRemaining(80 * 60), "1h20m")
        XCTAssertEqual(formatAwakeRemaining(120 * 60), "2h")
        XCTAssertEqual(formatAwakeRemaining(5), "1m") // never "0m" while still on
    }

    func testLength() {
        XCTAssertEqual(describeAwakeLength(minutes: 0), "until off")
        XCTAssertEqual(describeAwakeLength(minutes: 30), "30 min")
        XCTAssertEqual(describeAwakeLength(minutes: 60), "1 h")
        XCTAssertEqual(describeAwakeLength(minutes: 90), "1 h 30 min")
    }
}

final class MeetingLinkTests: XCTestCase {
    func testFindsZoomInNotes() {
        let url = MeetingLink.find(in: [nil, "Agenda\nJoin: https://acme.zoom.us/j/123456789?pwd=abc (passcode 1)"])
        XCTAssertEqual(url?.absoluteString, "https://acme.zoom.us/j/123456789?pwd=abc")
    }

    func testFindsMeetAndTeams() {
        XCTAssertEqual(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
        XCTAssertEqual(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y>"])?.host,
                       "teams.microsoft.com")
    }

    func testIgnoresOrdinaryLinks() {
        XCTAssertNil(MeetingLink.find(in: ["Room 4B", "https://example.com/agenda"]))
    }
}

final class BatteryRulesTests: XCTestCase {
    func snap(_ p: Int, power: Bool) -> BatterySnapshot {
        BatterySnapshot(percent: p, onPower: power, charging: power)
    }

    func testNoPopOnLaunch() {
        XCTAssertNil(BatteryRules.event(from: nil, to: snap(50, power: true)))
    }

    func testPluggingInPops() {
        XCTAssertEqual(BatteryRules.event(from: snap(64, power: false), to: snap(64, power: true)),
                       .pluggedIn(percent: 64))
    }

    func testLowBatteryPopsOncePerLevel() {
        XCTAssertEqual(BatteryRules.event(from: snap(21, power: false), to: snap(20, power: false)), .low(percent: 20))
        XCTAssertNil(BatteryRules.event(from: snap(20, power: false), to: snap(19, power: false)))
        XCTAssertEqual(BatteryRules.event(from: snap(11, power: false), to: snap(10, power: false)), .low(percent: 10))
    }

    func testNoLowWarningWhileCharging() {
        XCTAssertNil(BatteryRules.event(from: snap(21, power: true), to: snap(20, power: true)))
    }
}
