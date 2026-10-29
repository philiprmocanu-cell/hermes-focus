import XCTest
@testable import FocusCore

final class ModeTests: XCTestCase {
    private let owner = BrainConfig(baseURL: "https://brain.example", token: "SECRET")
    private let friend = FriendConfig(baseURL: "https://brain.example", token: "LBTOKEN", name: "Kai")

    // MARK: - Which mode

    func testResolveOwnerEnvAlwaysWins() {
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: true, friendJoined: true, stored: "local"), .owner)
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: true, friendJoined: false, stored: nil), .owner)
    }

    func testResolveStoredLocalBeatsAnOldFriendFile() {
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: false, friendJoined: true, stored: "local"), .local)
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: false, friendJoined: false, stored: "local"), .local)
    }

    func testResolveFriendNeedsTheJoinFile() {
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: false, friendJoined: true, stored: nil), .friend)
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: false, friendJoined: true, stored: "friend"), .friend)
        // "friend" remembered but friend.json gone: choose again.
        XCTAssertNil(BrainMode.resolve(ownerEnvExists: false, friendJoined: false, stored: "friend"))
    }

    func testResolveNothingChosen() {
        XCTAssertNil(BrainMode.resolve(ownerEnvExists: false, friendJoined: false, stored: nil))
        XCTAssertNil(BrainMode.resolve(ownerEnvExists: false, friendJoined: false, stored: "garbage"))
    }

    func testStoredValueAndKeys() {
        XCTAssertEqual(BrainMode.defaultsKey, "brainMode")
        XCTAssertEqual(BrainMode.anthropicModelKey, "anthropicModel")
        XCTAssertNil(BrainMode.owner.storedValue)
        XCTAssertEqual(BrainMode.friend.storedValue, "friend")
        XCTAssertEqual(BrainMode.local.storedValue, "local")
        // Round trip: what is stored resolves back.
        XCTAssertEqual(BrainMode.resolve(ownerEnvExists: false, friendJoined: false, stored: BrainMode.local.storedValue), .local)
    }

    func testWhatEachModeShows() {
        XCTAssertTrue(BrainMode.owner.showsFriends && BrainMode.owner.showsSharing && BrainMode.owner.showsVoice)
        XCTAssertTrue(BrainMode.friend.showsFriends)
        XCTAssertFalse(BrainMode.friend.showsSharing || BrainMode.friend.showsVoice)
        let l = BrainMode.local
        XCTAssertFalse(l.showsFriends || l.showsSharing || l.showsVoice || l.showsSuggestions || l.hasServer)
        XCTAssertTrue(l.judgesOnOwnKey && BrainMode.friend.judgesOnOwnKey)
        XCTAssertFalse(BrainMode.owner.judgesOnOwnKey)
    }

    func testLocalCallsEverythingASessionNeedsAndNothingThatNeedsAServer() {
        let yes: [FocusRoute] = [.goal, .frame, .tick, .block, .event, .now, .settings, .history, .sense, .exception]
        for r in yes { XCTAssertTrue(BrainMode.local.canCall(r), r.rawValue) }
        for r in FocusRoute.allCases where !yes.contains(r) { XCTAssertFalse(BrainMode.local.canCall(r), r.rawValue) }
        for r in FocusRoute.allCases {
            XCTAssertTrue(BrainMode.owner.canCall(r))
            XCTAssertEqual(BrainMode.friend.canCall(r), r.friendCanCall)
        }
    }

    func testGoalScreenRow() {
        let local = BrainMode.goalScreenLinks(.local, hasSuggestions: true)
        XCTAssertEqual(local, [.settings, .history, .endSession])
        let own = BrainMode.goalScreenLinks(.owner, hasSuggestions: true)
        XCTAssertEqual(own, GoalScreenLink.row(hasSuggestions: true, isOwner: true))
        XCTAssertTrue(own.contains(.friends))
        let fr = BrainMode.goalScreenLinks(.friend, hasSuggestions: false)
        XCTAssertTrue(fr.contains(.friends))
        XCTAssertFalse(fr.contains(where: \.isVoice) || fr.contains(.suggestions))
        // Not chosen yet: as a friend who hasn't joined (the Friends panel says how to join).
        XCTAssertEqual(BrainMode.goalScreenLinks(nil, hasSuggestions: false), GoalScreenLink.row(hasSuggestions: false, isOwner: false))
    }

    // MARK: - Dispatch

    func testDispatchOwnerAndFriendAreUnchanged() {
        for r in FocusRoute.allCases {
            let o = BrainDispatch.select(r, mode: .owner, owner: owner, friend: nil)
            XCTAssertEqual(o.target, FocusRoute.target(r, owner: owner, friend: nil))
            let f = BrainDispatch.select(r, mode: .friend, owner: nil, friend: friend)
            XCTAssertEqual(f.target, FocusRoute.target(r, owner: nil, friend: friend))
        }
        guard case .http(let t) = BrainDispatch.select(.goal, mode: .friend, owner: nil, friend: friend) else {
            return XCTFail("friend goal goes over http")
        }
        XCTAssertEqual(t.headers["X-LB-Token"], "LBTOKEN")
        XCTAssertTrue(t.url.path.hasSuffix("/lb/focus/goal"))
        // Owner without a config, friend without a join: nowhere.
        XCTAssertEqual(BrainDispatch.select(.goal, mode: .owner, owner: nil, friend: friend), .none)
        XCTAssertEqual(BrainDispatch.select(.goal, mode: .friend, owner: owner, friend: nil), .none)
    }

    func testDispatchLocalNeverTouchesTheNetwork() {
        for r in FocusRoute.allCases {
            let d = BrainDispatch.select(r, mode: .local, owner: owner, friend: friend, query: "days=7")
            if BrainMode.local.canCall(r) {
                XCTAssertEqual(d, .local(r, query: "days=7"))
                let t = d.target!
                XCTAssertEqual(t.url.scheme, "hermes-local")
                XCTAssertEqual(t.headers, [:])
                XCTAssertEqual(LocalRoute.route(from: t.url), r)
            } else {
                XCTAssertEqual(d, .none, r.rawValue)
                XCTAssertNil(d.target)
            }
        }
    }

    func testLocalHistoryAsksForThirtyDays() {
        let d = BrainDispatch.select(.history, mode: .local, owner: nil, friend: nil)
        XCTAssertEqual(d, .local(.history, query: "days=30"))
        XCTAssertEqual(LocalRoute.query(from: d.target!.url), "days=30")
        XCTAssertEqual(LocalRoute.route(from: d.target!.url), .history)
        XCTAssertEqual(LocalRoute.query(from: LocalRoute.url(.goal)), "")
        XCTAssertEqual(LocalRoute.query(.goal, ""), "")
    }

    func testDispatchBeforeAChoiceGoesNowhere() {
        for r in FocusRoute.allCases {
            XCTAssertEqual(BrainDispatch.select(r, mode: nil, owner: owner, friend: friend), .none)
        }
    }

    func testLocalRouteOnlyRecognisesItsOwnAddresses() {
        for r in FocusRoute.allCases { XCTAssertEqual(LocalRoute.route(from: LocalRoute.url(r)), r) }
        XCTAssertNil(LocalRoute.route(from: URL(string: "https://brain.example/lb/focus/goal")!))
        XCTAssertNil(LocalRoute.route(from: URL(string: "hermes-local://elsewhere/goal")!))
        XCTAssertNil(LocalRoute.route(from: URL(string: "hermes-local://focus/nonsense")!))
        XCTAssertEqual(LocalRoute.url(.leaderboard).absoluteString, "hermes-local://focus/leaderboard")
    }

    // MARK: - First launch

    func testSetupOpensOnlyWhenNothingIsChosen() {
        XCTAssertEqual(SetupFlow(mode: nil, skipped: false).screen, .choose)
        XCTAssertNil(SetupFlow(mode: nil, skipped: true).screen)
        XCTAssertNil(SetupFlow(mode: .local, skipped: false).screen)
        XCTAssertNil(SetupFlow(mode: .friend, skipped: false).screen)
        XCTAssertNil(SetupFlow(mode: .owner, skipped: false).screen)
    }

    func testOwnKeysPath() {
        var f = SetupFlow(mode: nil, skipped: false)
        XCTAssertEqual(f.pickOwnKeys(), .local)
        XCTAssertEqual(f.screen, .typesafeKey)
        f.next(typesafeWorks: true)
        XCTAssertEqual(f.screen, .anthropicKey)
        f.back()
        XCTAssertEqual(f.screen, .typesafeKey)
        f.back()
        XCTAssertEqual(f.screen, .choose)
        _ = f.pickOwnKeys()
        f.next(typesafeWorks: true)
        f.close() // Skip / Done
        XCTAssertNil(f.screen)
    }

    func testNoAnthropicStepWithoutAWorkingTypeSafeKey() {
        var f = SetupFlow(mode: nil, skipped: false)
        _ = f.pickOwnKeys()
        f.next(typesafeWorks: false)
        XCTAssertNil(f.screen)
        // next() only means something on the TypeSafe step.
        var g = SetupFlow(mode: nil, skipped: false)
        g.next(typesafeWorks: true)
        XCTAssertEqual(g.screen, .choose)
    }

    func testJoinPathAndBack() {
        var f = SetupFlow(mode: nil, skipped: false)
        f.pickJoin()
        XCTAssertEqual(f.screen, .join)
        f.back()
        XCTAssertEqual(f.screen, .choose)
        f.back()
        XCTAssertEqual(f.screen, .choose)
        f.pickJoin()
        f.close() // joined
        XCTAssertNil(f.screen)
        f.open()
        XCTAssertEqual(f.screen, .choose)
    }

    func testAddKeyLinkOpensTheTypeSafeStep() {
        var f = SetupFlow(mode: .local, skipped: false)
        f.openKey()
        XCTAssertEqual(f.screen, .typesafeKey)
    }

    // MARK: - Keys

    func testLocalKeyCommit() {
        XCTAssertEqual(LocalKeyCommit.decide(.ok), .keep)
        XCTAssertEqual(LocalKeyCommit.decide(.invalid), .restore)
        XCTAssertEqual(LocalKeyCommit.decide(.missing), .restore)
        XCTAssertEqual(LocalKeyCommit.decide(nil), .restore)
    }

    func testAnthropicKeyFieldAndModel() {
        XCTAssertEqual(AnthropicKeyField.keychainAccount, "anthropic_key")
        XCTAssertEqual(AnthropicKeyField.clean("  sk-ant-abc \n"), "sk-ant-abc")
        XCTAssertNil(AnthropicKeyField.clean("sk ant"))
        XCTAssertFalse(AnthropicKeyField.isValid(""))
        XCTAssertEqual(AnthropicKeyField.model(stored: nil), "claude-sonnet-5-5")
        XCTAssertEqual(AnthropicKeyField.model(stored: "  "), "claude-sonnet-5-5")
        XCTAssertEqual(AnthropicKeyField.model(stored: "claude-opus-5-5"), "claude-opus-5-5")
    }

    // MARK: - 402: no TypeSafe key in local mode

    func testLocal402TurnsTheReminderOnAndProbesOnceAMinute() {
        var s = TypeSafeState()
        let body: JSONValue = .object(["error": .string("Add your TypeSafe key in Settings to be judged"),
                                       "typesafe": .string("missing")])
        XCTAssertTrue(s.judged(httpStatus: 402, body: body, now: 1000))
        XCTAssertTrue(s.showsReminder)
        XCTAssertFalse(s.keyIsSet(storedLocally: false))
        XCTAssertFalse(s.canJudge(now: 1030))
        XCTAssertTrue(s.canJudge(now: 1060))
        s.sent(now: 1060)
        XCTAssertFalse(s.canJudge(now: 1061))
        // A key saved and accepted by the local brain: judging resumes at once.
        s.saved(.ok, now: 1070)
        XCTAssertFalse(s.showsReminder)
        XCTAssertTrue(s.canJudge(now: 1071))
        XCTAssertTrue(s.keyIsSet(storedLocally: true))
        // The reminder and its link are the 5.55 words.
        XCTAssertEqual(TypeSafeText.reminder, "Add your TypeSafe key in Settings to be judged")
        XCTAssertEqual(TypeSafeText.reminderLink, "Add key")
    }

    func testLocalReadyFalseShowsTheReminderBeforeAnyReply() {
        var s = TypeSafeState()
        s.observe(.missing, now: 10)
        XCTAssertTrue(s.showsReminder)
        s.judged(httpStatus: 200, body: .object([:]), now: 20)
        XCTAssertFalse(s.showsReminder)
    }

    func testSaveResultTextPerMode() {
        XCTAssertEqual(ModeText.typesafeResult(.ok, mode: .local).text, "Key works")
        XCTAssertTrue(ModeText.typesafeResult(.ok, mode: .local).ok)
        XCTAssertEqual(ModeText.typesafeResult(.invalid, mode: .local).text, "That key was refused — check it and try again")
        XCTAssertEqual(ModeText.typesafeResult(nil, mode: .local).text, ModeText.typesafeUnreachable)
        XCTAssertEqual(ModeText.typesafeResult(nil, mode: .friend).text, TypeSafeText.unreachable)
    }

    // MARK: - Local files, history, health

    func testDataPathsAndReports() {
        let support = URL(fileURLWithPath: "/Users/kai/Library/Application Support/HermesFocus")
        let store = LocalData.directory(support: support)
        XCTAssertEqual(store.path, "/Users/kai/Library/Application Support/HermesFocus/local")
        XCTAssertEqual(LocalData.displayPath(store, home: "/Users/kai"), "~/Library/Application Support/HermesFocus/local")
        XCTAssertEqual(LocalData.displayPath(store, home: "/Users/other"), store.path)
        XCTAssertEqual(LocalData.reportURL("reports/2026-10-28.md", store: store, home: "/Users/kai")?.path,
                       "/Users/kai/Library/Application Support/HermesFocus/local/reports/2026-10-28.md")
        XCTAssertEqual(LocalData.reportURL("/tmp/r.md", store: store)?.path, "/tmp/r.md")
        XCTAssertEqual(LocalData.reportURL("~/r.md", store: store, home: "/Users/kai")?.path, "/Users/kai/r.md")
        XCTAssertNil(LocalData.reportURL("  ", store: store))
    }

    func testLocalHistoryDocIconOnlyWithAReportPath() {
        let store = URL(fileURLWithPath: "/s/local")
        let json: JSONValue = .object(["days": .array([
            .object(["day": .string("2026-10-27"), "focus_s": .number(3600), "report_path": .string("reports/2026-10-27.md")]),
            .object(["day": .string("2026-10-28"), "focus_s": .number(1500), "doc_url": .string("https://docs.google.com/x")]),
        ])])
        let days = LocalHistory.parse(json, store: store, home: "/s")
        XCTAssertEqual(days.map(\.day), ["2026-10-28", "2026-10-27"])
        XCTAssertNil(days[0].docURL) // no report_path → no icon (a stray Google link is not used locally)
        XCTAssertEqual(days[1].docURL, "file:///s/local/reports/2026-10-27.md")
        XCTAssertEqual(URL(string: days[1].docURL!)?.isFileURL, true)
        XCTAssertEqual(days[1].focusS, 3600)
    }

    func testHealthLine() {
        let h: JSONValue = .object(["calls": .number(412), "errors": .number(0), "cost_usd": .number(0.3812),
                                    "jev": .object(["calls": .number(400)])])
        XCTAssertEqual(LocalHealth.line(h), "412 calls since the app opened · about $0.38")
        XCTAssertEqual(LocalHealth.line(.object(["calls": .number(1), "cost_usd": .number(0.0004), "errors": .number(2)])),
                       "1 call since the app opened · about under $0.01 · 2 errors")
        XCTAssertEqual(LocalHealth.line(.object(["calls": .number(0), "cost_usd": .number(0)])), ModeText.healthUnknown)
        XCTAssertEqual(LocalHealth.line(nil), "No calls yet since the app opened")
    }

    // MARK: - Words

    func testFirstLaunchTexts() {
        XCTAssertEqual(ModeText.ownKeysTitle, "Run on my own keys")
        XCTAssertEqual(ModeText.ownKeysBadge, "Recommended")
        XCTAssertEqual(ModeText.ownKeysBody, "Everything stays on this Mac. Your screen is judged by TypeSafe with your own key. Nothing is sent to anyone else.")
        XCTAssertEqual(ModeText.joinTitle, "Join a friend's leaderboard")
        XCTAssertEqual(ModeText.anthropicExplainer, "Adds a written plan for each goal, a second look before a nudge, and advice after each block. Skip and the app still judges and scores with TypeSafe alone.")
        XCTAssertEqual(ModeText.anthropicRow(set: true), "Anthropic key: set")
        XCTAssertEqual(ModeText.anthropicRow(set: false), "Anthropic key: not set")
        XCTAssertEqual(ModeText.dataLine("~/Library/Application Support/HermesFocus/local"),
                       "Your data: ~/Library/Application Support/HermesFocus/local")
        XCTAssertEqual(ModeText.showInFinder, "Show in Finder")
        XCTAssertEqual(ModeText.healthTitle, "Health")
    }

    func testEveryTextIsPlainAndFilled() {
        var all = [ModeText.chooseTitle, ModeText.chooseSubtitle, ModeText.ownKeysTitle, ModeText.ownKeysBadge,
                   ModeText.ownKeysBody, ModeText.joinTitle, ModeText.joinBody, ModeText.notNow, ModeText.back,
                   ModeText.typesafeExplainer, ModeText.typesafeUnreachable, ModeText.next, ModeText.anthropicTitle,
                   ModeText.anthropicExplainer, ModeText.anthropicWhere, ModeText.anthropicField,
                   ModeText.anthropicPrompt, ModeText.anthropicSaved, ModeText.anthropicSaveFailed, ModeText.skip,
                   ModeText.showInFinder, ModeText.healthTitle, ModeText.healthUnknown, ModeText.historyNeedsChoice,
                   ModeText.historyNoDays, ModeText.historyLocalFailed]
        for t in all {
            XCTAssertFalse(t.trimmingCharacters(in: .whitespaces).isEmpty)
            for jargon in ["API", "endpoint", "server-side", "JSON", "HTTP", "402"] {
                XCTAssertFalse(t.contains(jargon), "\(jargon) in: \(t)")
            }
        }
    }

}
