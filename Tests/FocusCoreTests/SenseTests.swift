import XCTest
@testable import FocusCore

/// Jev, the second-by-second judge: the sense post, its reply, and the fallback to screenshots.
final class SenseTests: XCTestCase {
    func testPayloadUsesTheBrainsFieldNamesAndSendsTextOnlyWhenChanged() throws {
        let ctx = AppContext(app: "Xcode", title: "View.swift", url: "")
        let p = SensePayload(blockId: "b1", goal: "Acme onboarding", understood: "", specificGoal: "fix the crash",
                             at: 100, context: ctx, text: "struct View {}", textDigest: "abc", textChangedShare: 0.5,
                             typed: true, scrolled: false, idleS: 0, appSwitched: false)
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["block_id"] as? String, "b1")
        XCTAssertEqual(obj["specific_goal"] as? String, "fix the crash")
        XCTAssertEqual(obj["text_changed_share"] as? Double, 0.5)
        XCTAssertEqual(obj["idle_s"] as? Int, 0)
        XCTAssertEqual(obj["app_switched"] as? Bool, false)
        XCTAssertEqual(obj["text"] as? String, "struct View {}")
        let quiet = SensePayload(blockId: "b1", goal: "g", understood: "", specificGoal: "", at: 101, context: ctx,
                                 text: nil, textDigest: "abc", textChangedShare: 0, typed: false, scrolled: false,
                                 idleS: 4, appSwitched: false)
        let q = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(quiet)) as? [String: Any])
        XCTAssertNil(q["text"] ?? nil, "unchanged text is not resent")
        XCTAssertFalse(q.keys.contains("image_jpeg_b64"), "no screenshot this second: the key is left out")
        var withImage = quiet
        withImage.imageJpegB64 = "/9j/AA=="
        let i = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(withImage)) as? [String: Any])
        XCTAssertEqual(i["image_jpeg_b64"] as? String, "/9j/AA==")
    }

    func testReplyParsesVerdictNudgeFrameAndProgress() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"verdict": {"on_goal": 0.12, "mode": "consuming", "confidence": 0.9, "serves_goal": false},
         "nudge": "Close reddit.com — back to Acme onboarding.", "nudge_id": "n-42",
         "frame": {"on_goal": 0.1, "working": 0.1, "mode": "consuming", "judge": "jev"},
         "goal_progress": 0.4}
        """.utf8))
        let r = SenseResult.parse(json)
        XCTAssertEqual(r.onGoal, 0.12)
        XCTAssertEqual(r.mode, "consuming")
        XCTAssertEqual(r.confidence, 0.9)
        XCTAssertEqual(r.servesGoal, false)
        XCTAssertTrue(r.nudge.hasPrefix("Close reddit.com"))
        XCTAssertEqual(r.nudgeId, "n-42")
        XCTAssertEqual(r.frame?["judge"]?.stringValue, "jev")
        XCTAssertEqual(r.goalProgress, 0.4)
        XCTAssertNil(r.goalChanged)
        XCTAssertFalse(r.cached)
        let cached = SenseResult.parse(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"cached": true, "verdict": {}}"#.utf8)))
        XCTAssertTrue(cached.cached)
        XCTAssertNil(cached.frame)
        XCTAssertNil(cached.servesGoal, "not said is not false")
        XCTAssertEqual(cached.nudgeId, "")
        let serving = SenseResult.parse(try JSONDecoder().decode(JSONValue.self,
                                                                 from: Data(#"{"verdict": {"serves_goal": true}}"#.utf8)))
        XCTAssertEqual(serving.servesGoal, true)
    }

    func testTextChangeShareAndDigest() {
        XCTAssertEqual(TextChange.share(old: "", new: ""), 0)
        XCTAssertEqual(TextChange.share(old: "a\nb", new: "a\nb"), 0)
        XCTAssertEqual(TextChange.share(old: "a\nb", new: "a\nc"), 0.5)
        XCTAssertEqual(TextChange.share(old: "", new: "x"), 1)
        XCTAssertEqual(TextChange.digest("a  b\n c"), TextChange.digest("a b c"), "whitespace never changes the digest")
        XCTAssertNotEqual(TextChange.digest("a"), TextChange.digest("b"))
        XCTAssertEqual(TextChange.trimmed(String(repeating: "x", count: 10_000)).count, TextChange.maxChars)
    }

    func testScreenshotsRunOnScheduleUntilJevAnswersAndComeBackAfterThreeFailures() {
        var h = SenseHealth()
        XCTAssertTrue(h.screenshotsOnSchedule, "before the first answer the old schedule runs")
        h.succeeded()
        XCTAssertTrue(h.isJudging)
        XCTAssertFalse(h.screenshotsOnSchedule)
        h.failed(); h.failed()
        XCTAssertTrue(h.isJudging, "two misses are a blip")
        h.failed()
        XCTAssertFalse(h.isJudging)
        XCTAssertTrue(h.screenshotsOnSchedule)
        h.succeeded()
        XCTAssertTrue(h.isJudging, "one answer and Jev is back in charge")
        h.reset()
        XCTAssertFalse(h.isJudging)
    }

    func testSenseIsAFriendRouteToo() throws {
        XCTAssertTrue(FocusRoute.sense.friendCanCall)
        XCTAssertEqual(FocusRoute.sense.ownerPath, "/admin/focus/sense")
        XCTAssertEqual(FocusRoute.sense.friendPath, "/lb/focus/sense")
    }

    func testExceptionIsAFriendRouteTooAndCarriesTheNudgesScreen() throws {
        XCTAssertTrue(FocusRoute.exception.friendCanCall)
        XCTAssertEqual(FocusRoute.exception.ownerPath, "/admin/focus/exception")
        XCTAssertEqual(FocusRoute.exception.friendPath, "/lb/focus/exception")
        let p = ExceptionPayload(blockId: "b1", nudgeId: "",
                                 context: AppContext(app: "Google Chrome", title: "Discord", url: "https://discord.com/x"),
                                 at: 100)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["block_id", "nudge_id", "app", "title", "url", "at"])
        XCTAssertEqual(o["nudge_id"] as? String, "")
        XCTAssertEqual(o["url"] as? String, "https://discord.com/x")
        let ok = ExceptionReply.parse(try JSONDecoder().decode(JSONValue.self,
                                                               from: Data(#"{"ok": true, "rule": "discord.com"}"#.utf8)))
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.rule, "discord.com")
        XCTAssertFalse(ExceptionReply.parse(.object([:])).ok)
        XCTAssertEqual(ExceptionReply.buttonTitle, "I'm on task")
    }
}

/// Which seconds' sense posts carry a screenshot.
final class ImageGateTests: XCTestCase {
    private let words = String(repeating: "Some real paragraph text about the essay. ", count: 10)
    private let xcode = AppContext(app: "Xcode", title: "View.swift", url: "")

    func testANewScreenAlwaysGetsOneThenTheTextIsEnough() {
        var g = ImageGate()
        XCTAssertTrue(g.wants(context: xcode, text: words, now: 0), "the block's first screen")
        g.sent(context: xcode, now: 0)
        XCTAssertFalse(g.wants(context: xcode, text: words, now: 1))
        XCTAssertFalse(g.wants(context: xcode, text: words, now: 60), "plenty of text: no repeats")
        let other = AppContext(app: "Xcode", title: "Model.swift", url: "")
        XCTAssertTrue(g.wants(context: other, text: words, now: 61), "a new title is a new screen")
        let tab = AppContext(app: "Google Chrome", title: "Docs", url: "https://docs.google.com/a")
        g.sent(context: tab, now: 70)
        XCTAssertTrue(g.wants(context: AppContext(app: "Google Chrome", title: "Docs", url: "https://docs.google.com/b"),
                              text: words, now: 71), "a new URL is a new screen")
        g.reset()
        XCTAssertTrue(g.wants(context: tab, text: words, now: 72), "a new block starts fresh")
    }

    func testOnlyMarkedSentWhenAnImageWentOut() {
        let g = ImageGate()
        // Asked, but the capture was still running: nothing marked, so the next second still wants one.
        XCTAssertTrue(g.wants(context: xcode, text: words, now: 0))
        XCTAssertTrue(g.wants(context: xcode, text: words, now: 1))
        XCTAssertNil(g.lastKey)
    }

    func testThinTextRepeatsEveryFiveSeconds() {
        var g = ImageGate()
        let ctx = AppContext(app: "Finder", title: "Downloads", url: "")
        g.sent(context: ctx, now: 100)
        XCTAssertFalse(g.wants(context: ctx, text: "   Downloads   ", now: 101))
        XCTAssertFalse(g.wants(context: ctx, text: "Downloads", now: 104.9))
        XCTAssertTrue(g.wants(context: ctx, text: "Downloads", now: 105))
        XCTAssertTrue(ImageGate.needsPictures(context: ctx, text: String(repeating: "x", count: 199)))
        XCTAssertFalse(ImageGate.needsPictures(context: ctx, text: String(repeating: "x", count: 200)))
        XCTAssertTrue(ImageGate.needsPictures(context: ctx, text: "  " + String(repeating: "x", count: 199) + "\n\n"),
                      "trimmed before counting")
    }

    func testPictureAppsSitesAndClaudeKeepNeedingPictures() {
        for app in ["Figma", "Sketch", "Adobe Photoshop 2026", "Adobe Illustrator", "Final Cut Pro", "iMovie", "Preview",
                    "Photos", "QuickTime Player", "Keynote", "Blender", "Autodesk Fusion", "KiCad", "Eagle", "Altium Designer"] {
            XCTAssertTrue(ImageGate.needsPictures(context: AppContext(app: app), text: words), app)
        }
        for url in ["https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://vimeo.com/1", "https://www.figma.com/file/x",
                    "https://www.canva.com/design", "https://www.netflix.com/browse", "https://www.twitch.tv/x",
                    "https://www.instagram.com/", "https://www.tiktok.com/@x", "https://cosmos.so/x", "m.youtube.com/watch"] {
            XCTAssertTrue(ImageGate.needsPictures(context: AppContext(app: "Google Chrome", url: url), text: words), url)
        }
        XCTAssertTrue(ImageGate.needsPictures(context: AppContext(app: "Claude"), text: words))
        XCTAssertTrue(ImageGate.needsPictures(context: AppContext(app: " claude "), text: words))
        XCTAssertFalse(ImageGate.needsPictures(context: AppContext(app: "Claude Code Helper"), text: words),
                       "Claude means exactly the desktop app")
        XCTAssertFalse(ImageGate.needsPictures(context: AppContext(app: "Google Chrome", url: "https://notyoutube.com/x"),
                                               text: words), "a host only matches itself or its subdomains")
        XCTAssertFalse(ImageGate.needsPictures(context: AppContext(app: "Google Chrome", url: "https://docs.google.com/d"),
                                               text: words))
        XCTAssertFalse(ImageGate.needsPictures(context: xcode, text: words))

        var g = ImageGate()
        let yt = AppContext(app: "Google Chrome", title: "A video", url: "https://www.youtube.com/watch?v=x")
        g.sent(context: yt, now: 0)
        XCTAssertFalse(g.wants(context: yt, text: words, now: 4))
        XCTAssertTrue(g.wants(context: yt, text: words, now: 5), "a picture site repeats every 5 s even with text")
        XCTAssertEqual(ImageGate.repeatEvery, 5)
    }

    func testSenseImageSize() {
        XCTAssertTrue(SenseImage.targetSize(width: 3024, height: 1964) == (1280, 831))
        XCTAssertTrue(SenseImage.targetSize(width: 1964, height: 3024) == (831, 1280))
        XCTAssertTrue(SenseImage.targetSize(width: 1280, height: 800) == (1280, 800), "never upscaled")
        XCTAssertTrue(SenseImage.targetSize(width: 1000, height: 600) == (1000, 600))
        XCTAssertTrue(SenseImage.targetSize(width: 5120, height: 800) == (1280, 280), "each side at least 280")
        XCTAssertTrue(SenseImage.targetSize(width: 200, height: 100) == (280, 280))
        XCTAssertEqual(SenseImage.quality, 0.6)
    }
}
