import XCTest
@testable import FocusCore

private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

final class TypeSafeKeyFieldTests: XCTestCase {
    func testAPastedKeyIsTrimmed() {
        XCTAssertEqual(TypeSafeKeyField.clean("  ts_live_abc123\n"), "ts_live_abc123")
        XCTAssertTrue(TypeSafeKeyField.isValid("ts_abc"))
    }

    func testEmptyOrSpacedKeysAreRefusedBeforeTheyLeave() {
        XCTAssertNil(TypeSafeKeyField.clean(""))
        XCTAssertNil(TypeSafeKeyField.clean("   \n\t"))
        XCTAssertNil(TypeSafeKeyField.clean("ts_abc def"), "a space inside = half a key, or two")
        XCTAssertNil(TypeSafeKeyField.clean("ts_abc\ndef"))
        XCTAssertFalse(TypeSafeKeyField.isValid("ts abc"))
    }

    func testTheKeychainSlot() {
        XCTAssertEqual(TypeSafeKeyField.keychainService, "app.hermesfocus.mac")
        XCTAssertEqual(TypeSafeKeyField.keychainAccount, "typesafe_key")
    }
}

final class TypeSafeContractTests: XCTestCase {
    func testTheSettingsBody() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TypeSafeKeyRequest(typesafeKey: "k1"))) as! [String: Any]
        XCTAssertEqual(body as? [String: String], ["typesafe_key": "k1"])
        let gone = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TypeSafeKeyRequest.remove)) as! [String: Any]
        XCTAssertEqual(gone as? [String: String], ["typesafe_key": ""], "Remove sends an empty key")
    }

    func testTheStatusField() throws {
        XCTAssertEqual(TypeSafeStatus.parse(try json(#"{"typesafe": "ok"}"#)), .ok)
        XCTAssertEqual(TypeSafeStatus.parse(try json(#"{"typesafe": "invalid"}"#)), .invalid)
        XCTAssertEqual(TypeSafeStatus.parse(try json(#"{"typesafe": "missing", "active": false}"#)), .missing)
        XCTAssertNil(TypeSafeStatus.parse(try json(#"{"active": true}"#)), "an older brain says nothing")
        XCTAssertNil(TypeSafeStatus.parse(nil))
    }

    func testTheWordsHeSees() {
        XCTAssertEqual(TypeSafeText.result(for: .ok).text, "Key works")
        XCTAssertTrue(TypeSafeText.result(for: .ok).ok)
        XCTAssertEqual(TypeSafeText.result(for: .invalid).text, "That key was refused — check it and try again")
        XCTAssertFalse(TypeSafeText.result(for: .invalid).ok)
        XCTAssertFalse(TypeSafeText.result(for: nil).ok)
        XCTAssertEqual(TypeSafeText.reminder, "Add your TypeSafe key in Settings to be judged")
        XCTAssertEqual(TypeSafeText.row(set: true), "TypeSafe key: set")
        XCTAssertEqual(TypeSafeText.row(set: false), "TypeSafe key: not set")
        XCTAssertTrue(TypeSafeText.explainer.contains("console.typesafe.ai/keys"))
    }
}

final class TypeSafeStateTests: XCTestCase {
    private let noKey402 = try! JSONDecoder().decode(JSONValue.self, from: Data(
        #"{"error": "Add your TypeSafe key in Settings to be judged", "typesafe": "missing"}"#.utf8))

    func testAFreshAppJudgesEverySecond() {
        let s = TypeSafeState()
        XCTAssertTrue(s.canJudge(now: 0))
        XCTAssertFalse(s.showsReminder)
    }

    func testA402BacksOffToOnceAMinute() {
        var s = TypeSafeState()
        XCTAssertTrue(s.judged(httpStatus: 402, body: noKey402, now: 100), "402 = no key, not 'unreachable'")
        XCTAssertTrue(s.showsReminder)
        XCTAssertFalse(s.canJudge(now: 101))
        XCTAssertFalse(s.canJudge(now: 159))
        XCTAssertTrue(s.canJudge(now: 160), "one probe a minute")
        s.sent(now: 160)
        XCTAssertFalse(s.canJudge(now: 161), "that probe used up the minute — sense and frame share it")
        s.judged(httpStatus: 402, body: nil, now: 161)
        XCTAssertFalse(s.canJudge(now: 220))
        XCTAssertTrue(s.canJudge(now: 221))
    }

    func testASecondSuccessWhileMissingResumesAtOnce() {
        var s = TypeSafeState()
        s.judged(httpStatus: 402, body: nil, now: 0)
        XCTAssertFalse(s.judged(httpStatus: 200, body: .object([:]), now: 60))
        XCTAssertFalse(s.showsReminder)
        XCTAssertTrue(s.canJudge(now: 61))
    }

    func testOtherFailuresAreNotAMissingKey() {
        var s = TypeSafeState()
        XCTAssertFalse(s.judged(httpStatus: 500, body: nil, now: 0))
        XCTAssertFalse(s.judged(httpStatus: 0, body: nil, now: 0), "no network")
        XCTAssertFalse(s.showsReminder)
        XCTAssertTrue(s.canJudge(now: 1))
    }

    func testNowSaysMissingThenOk() {
        var s = TypeSafeState()
        s.observe(.missing, now: 10)
        XCTAssertTrue(s.showsReminder)
        XCTAssertFalse(s.canJudge(now: 11))
        s.observe(.missing, now: 20)
        XCTAssertTrue(s.canJudge(now: 70), "a repeated 'missing' does not push the probe further out")
        s.observe(nil, now: 30)
        XCTAssertTrue(s.showsReminder, "an older brain's silence changes nothing")
        s.observe(.ok, now: 40)
        XCTAssertFalse(s.showsReminder)
        XCTAssertTrue(s.canJudge(now: 40))
    }

    func testSavingAKeyResumesJudgingAtOnce() {
        var s = TypeSafeState()
        s.judged(httpStatus: 402, body: nil, now: 0)
        s.saved(.ok, now: 5)
        XCTAssertTrue(s.canJudge(now: 5))
        XCTAssertFalse(s.showsReminder)
        XCTAssertTrue(s.keyIsSet(storedLocally: true))
    }

    func testARefusedKeyChangesNothingElse() {
        var s = TypeSafeState()
        s.saved(.invalid, now: 0)
        XCTAssertFalse(s.showsReminder, "an older key may still be judging; the next sense reply says")
        XCTAssertTrue(s.canJudge(now: 0))
        XCTAssertFalse(s.keyIsSet(storedLocally: true))
        s.saved(nil, now: 1)
        XCTAssertEqual(s.status, .invalid, "unreachable = nothing learned")
    }

    func testRemovingTheKey() {
        var s = TypeSafeState()
        s.saved(.ok, now: 0)
        s.removed(now: 10)
        XCTAssertTrue(s.showsReminder)
        XCTAssertFalse(s.keyIsSet(storedLocally: false))
        XCTAssertFalse(s.canJudge(now: 11))
        XCTAssertTrue(s.canJudge(now: 70))
    }

    func testTheSettingsRow() {
        XCTAssertTrue(TypeSafeState().keyIsSet(storedLocally: true), "before the brain says anything: the Keychain")
        XCTAssertFalse(TypeSafeState().keyIsSet(storedLocally: false))
        var s = TypeSafeState()
        s.observe(.missing, now: 0)
        XCTAssertFalse(s.keyIsSet(storedLocally: true), "the brain has none, whatever this Mac holds")
    }

    func testTheKeychainKeyIsResentOncePerLaunch() {
        var s = TypeSafeState()
        XCTAssertFalse(s.takeResend(storedLocally: true), "not missing: nothing to resend")
        s.observe(.missing, now: 0)
        XCTAssertFalse(s.takeResend(storedLocally: false))
        XCTAssertTrue(s.takeResend(storedLocally: true))
        XCTAssertFalse(s.takeResend(storedLocally: true), "once")
    }
}
