import XCTest
@testable import FocusCore

final class MeasurementTests: XCTestCase {
    func testActivityWindow() {
        var w = MeasureWindow()
        let chrome = AppContext(app: "Google Chrome", title: "Docs", url: "https://docs.google.com")
        let xcode = AppContext(app: "Xcode", title: "App.swift", url: "")
        w.addActivity(context: chrome, interval: 5, sinceLastEvent: 1)
        w.addActivity(context: chrome, interval: 5, sinceLastEvent: 30)
        w.addActivity(context: xcode, interval: 5, sinceLastEvent: 0.2)
        w.addActivity(context: AppContext(), interval: 5, sinceLastEvent: 0.2)
        w.addSwitch(); w.addSwitch()
        XCTAssertEqual(w.activeSeconds, 15)
        XCTAssertEqual(w.switches, 2)
        let top = w.topApps()
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].0, chrome); XCTAssertEqual(top[0].1, 10)
        XCTAssertEqual(top[1].0, xcode)
        XCTAssertEqual(w.topApps(limit: 1).count, 1)
    }

    func testScreenshotSchedule() {
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 120, jitter: 20, unitRandom: 0), 100)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 120, jitter: 20, unitRandom: 0.5), 120)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 120, jitter: 20, unitRandom: 1), 140)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 120, jitter: 20, unitRandom: 7), 140)
        XCTAssertEqual(ScreenshotSchedule.nextDelay(interval: 3, jitter: 5, unitRandom: 0), 5)
        for _ in 0..<200 {
            let d = ScreenshotSchedule.nextDelay(interval: 120, jitter: 20, unitRandom: Double.random(in: 0...1))
            XCTAssert((100...140).contains(d))
        }
        XCTAssertTrue(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: false, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: true, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: false, screenLocked: false, displayAsleep: true))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .work, paused: true, screenLocked: false, displayAsleep: false))
        XCTAssertFalse(ScreenshotSchedule.shouldCapture(phase: .onBreak, paused: false, screenLocked: false, displayAsleep: false))
    }

    func testTargetSize() {
        XCTAssertTrue(ScreenshotSchedule.targetSize(width: 3024, height: 1964) == (1920, 1247))
        XCTAssertTrue(ScreenshotSchedule.targetSize(width: 1000, height: 800) == (1000, 800))
    }

    func testText() {
        XCTAssertEqual(FocusText.clock(300), "5:00")
        XCTAssertEqual(FocusText.clock(1499.2), "25:00")
        XCTAssertEqual(FocusText.clock(59.01), "1:00")
        XCTAssertEqual(FocusText.clock(-3), "0:00")
        XCTAssertEqual(FocusText.scoreLine(742), "Last block: 742 / 1000")
        XCTAssertEqual(FocusText.scoreLine(nil), "Score pending")
    }
}

final class BrainContractTests: XCTestCase {
    func testConfigParse() {
        let env = """
        # comment
        HERMES_BRIDGE_TOKEN=abc
        BRAIN_API_TOKEN="s3cr3t"
        export BRAIN_URL=https://example.com/
        """
        let c = BrainConfig.parse(env: env)!
        XCTAssertEqual(c.token, "s3cr3t")
        XCTAssertEqual(c.url(path: "/admin/focus/tick")?.absoluteString, "https://example.com/t/s3cr3t/admin/focus/tick")
    }

    func testConfigDefaultURL() {
        let c = BrainConfig.parse(env: "BRAIN_API_TOKEN=tok\nBRAIN_URL=\n")!
        // No default server in the standalone build: a blank BRAIN_URL stays blank.
        XCTAssertEqual(c.baseURL, "")
        XCTAssertNil(BrainConfig.parse(env: "BRAIN_URL=https://x\n"))
    }

    private func object(_ v: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
    }

    func testTickPayloadKeys() throws {
        var w = MeasureWindow()
        w.addActivity(context: AppContext(app: "Xcode"), interval: 5, sinceLastEvent: 1)
        w.addSwitch()
        let p = TickPayload(blockId: "b", goal: "g", at: 100, phase: .work, window: w,
                            context: AppContext(app: "Xcode", title: "t", url: ""), idleS: 7)
        let o = try object(p)
        // No camera any more: no attention, face_present or eye. idle_s = seconds since the last input.
        XCTAssertEqual(Set(o.keys), ["block_id", "goal", "understood", "at", "phase",
                                     "active_s", "switches", "app", "title", "url", "idle_s", "distraction_s",
                                     "scroll_s", "keys_s"])
        XCTAssertEqual(o["phase"] as? String, "work")
        XCTAssertEqual(o["idle_s"] as? Int, 7)
        XCTAssertEqual(o["active_s"] as? Int, 5)
        XCTAssertEqual(TickPayload(blockId: "b", goal: "g", at: 1, phase: .onBreak, window: w, context: AppContext()).phase, "break")
    }

    func testBlockPayloadKeysAndFramesPassThrough() throws {
        var w = MeasureWindow()
        w.addActivity(context: AppContext(app: "Chrome", title: "T", url: "https://u"), interval: 5, sinceLastEvent: 0)
        let frame: JSONValue = .object(["on_goal": .number(0.8), "working": .number(1), "doing": .string("coding"),
                                        "automatable": .string("")])
        let timing = BlockTiming(blockId: "b", goal: "g", startedAt: 10.7, endedAt: 1510.2, plannedSeconds: 1500, completed: true)
        let p = BlockPayload(timing: timing, window: w, frames: [frame])
        let o = try object(p)
        XCTAssertEqual(Set(o.keys), ["block_id", "goal", "understood", "started_at", "ended_at", "planned_s", "completed",
                                     "active_s", "switches", "apps", "frames", "distraction_s", "scroll_s",
                                     "keys_s", "specific_goal"])
        XCTAssertEqual(o["started_at"] as? Int, 10)
        XCTAssertEqual(o["planned_s"] as? Int, 1500)
        let apps = o["apps"] as! [[String: Any]]
        XCTAssertEqual(apps.first?["seconds"] as? Int, 5)
        XCTAssertEqual(apps.first?["url"] as? String, "https://u")
        let frames = o["frames"] as! [[String: Any]]
        XCTAssertEqual(frames.first?["doing"] as? String, "coding")
    }

    func testFrameAndEventKeys() throws {
        let f = FramePayload(blockId: "b", goal: "g", at: 1, imageJpegB64: "AAA", context: AppContext(app: "a", title: "t", url: "u"))
        XCTAssertEqual(Set(try object(f).keys), ["block_id", "goal", "understood", "at", "image_jpeg_b64", "app", "title", "url",
                                                 "specific_goal"])
        let e = EventPayload(kind: .breakSkipped, blockId: "b", goal: "g", at: 1)
        let o = try object(e)
        XCTAssertEqual(o["kind"] as? String, "break_skipped")
        XCTAssertEqual(Set(o.keys), ["kind", "block_id", "goal", "at"])
    }

    func testBlockResultParse() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"score": 742.4, "parts": {"a": 1, "ok": true}, "advice": "Close Slack."}"#.utf8))
        let r = BlockResult.parse(json)!
        XCTAssertEqual(r.score, 742)
        XCTAssertEqual(r.advice, "Close Slack.")
        XCTAssertEqual(r.parts?["a"], .number(1))
        XCTAssertEqual(r.parts?["ok"], .bool(true))
        XCTAssertNil(BlockResult.parse(.object(["error": .string("x")])))
        XCTAssertEqual(BlockResult.parse(.object(["score": .number(5000)]))?.score, 1000)
    }

    func testJSONValueRoundTrip() throws {
        let src = #"{"n":1,"f":0.25,"s":"x","b":false,"z":null,"a":[1,"two"],"o":{"k":"v"}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(src.utf8))
        XCTAssertEqual(v["n"], .number(1))
        XCTAssertEqual(v["b"], .bool(false))
        XCTAssertEqual(v["z"], .null)
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(v, again)
    }

    func testPendingQueue() {
        var q = PendingBlocks()
        let t1 = BlockTiming(blockId: "1", goal: "g", startedAt: 0, endedAt: 1, plannedSeconds: 1, completed: true)
        let t2 = BlockTiming(blockId: "2", goal: "g", startedAt: 0, endedAt: 1, plannedSeconds: 1, completed: false)
        q.enqueue(BlockPayload(timing: t1, window: MeasureWindow(), frames: []))
        q.enqueue(BlockPayload(timing: t2, window: MeasureWindow(), frames: []))
        q.enqueue(BlockPayload(timing: t1, window: MeasureWindow(), frames: []))
        XCTAssertEqual(q.items.map(\.blockId), ["2", "1"])
        let restored = PendingBlocks.decode(q.encoded())
        XCTAssertEqual(restored, q)
        q.remove(blockId: "2")
        XCTAssertEqual(q.items.map(\.blockId), ["1"])
        XCTAssertEqual(PendingBlocks.decode(nil).items.count, 0)
        XCTAssertEqual(PendingBlocks.decode(Data("garbage".utf8)).items.count, 0)
        for i in 0..<(PendingBlocks.maxItems + 5) {
            q.enqueue(BlockPayload(timing: BlockTiming(blockId: "x\(i)", goal: "", startedAt: 0, endedAt: 0,
                                                       plannedSeconds: 0, completed: true), window: MeasureWindow(), frames: []))
        }
        XCTAssertEqual(q.items.count, PendingBlocks.maxItems)
    }
}
