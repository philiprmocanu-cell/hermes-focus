import XCTest
@testable import FocusCore

/// Clean focus mode: what gets written, what gets saved, and — the part that
/// matters — that his own Dock and menu bar always come back, including after
/// the app is killed mid-block.
final class CleanFocusTests: XCTestCase {
    /// A plain machine: Dock always shown, menu bar always shown, desktop icons on.
    let plain = SystemChrome()
    let allOn = CleanFocusPrefs(hideDockAndMenuBar: true, hideDesktopIcons: true)
    let dockOnly = CleanFocusPrefs(hideDockAndMenuBar: true)

    // MARK: - Nothing happens until he asks for it

    func testBothTogglesAreOffByDefault() {
        let p = CleanFocusPrefs()
        XCTAssertFalse(p.hideDockAndMenuBar)
        XCTAssertFalse(p.hideDesktopIcons)
        XCTAssertFalse(p.anyOn)
    }

    func testWithTheSettingOffABlockChangesNothingAndSavesNothing() {
        let plan = CleanFocus.engage(prefs: CleanFocusPrefs(), current: plain, saved: nil)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertNil(plan.save)
        XCTAssertFalse(plan.killDock)
    }

    // MARK: - Starting a block

    func testTheFirstBlockHidesTheDockAndTheMenuBarAndRestartsTheDock() {
        let plan = CleanFocus.engage(prefs: dockOnly, current: plain, saved: nil)
        XCTAssertEqual(plan.writes, [.dockAutohide(true), .menuBarHidden(true)])
        XCTAssertTrue(plan.killDock)
        XCTAssertFalse(plan.killFinder)      // the desktop was not touched
        XCTAssertEqual(plan.save, plain)     // his values, saved before anything changed
        XCTAssertFalse(plan.clearSaved)
    }

    func testTheDesktopIconsToggleRestartsFinderAsWell() {
        let plan = CleanFocus.engage(prefs: allOn, current: plain, saved: nil)
        XCTAssertEqual(plan.writes,
                       [.dockAutohide(true), .menuBarHidden(true), .desktopIcons(false)])
        XCTAssertTrue(plan.killDock)
        XCTAssertTrue(plan.killFinder)
    }

    func testAManWhoAlreadyHidesHisDockIsLeftAlone() {
        // He auto-hides the Dock himself: there is nothing to change, so there
        // is nothing to save and nothing to put back later.
        let his = SystemChrome(dockAutohide: true, menuBarHidden: true, desktopIcons: true)
        let plan = CleanFocus.engage(prefs: dockOnly, current: his, saved: nil)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertNil(plan.save)
    }

    func testOnlyWhatDiffersIsWritten() {
        // Dock already auto-hides, menu bar does not: one write, one killall.
        let half = SystemChrome(dockAutohide: true, menuBarHidden: false, desktopIcons: true)
        let plan = CleanFocus.engage(prefs: dockOnly, current: half, saved: nil)
        XCTAssertEqual(plan.writes, [.menuBarHidden(true)])
        XCTAssertTrue(plan.killDock)
    }

    func testTheSecondBlockOfASessionNeverOverwritesWhatWasSaved() {
        // Block one hid everything; block two starts with the screen already
        // hidden and the file already holding his real values.
        let hidden = SystemChrome(dockAutohide: true, menuBarHidden: true, desktopIcons: false)
        let second = CleanFocus.engage(prefs: allOn, current: hidden, saved: plain)
        XCTAssertTrue(second.isEmpty)
        // And if he un-hid the Dock himself during the break, block three hides
        // it again without touching the saved values.
        let third = CleanFocus.engage(prefs: allOn, current: plain, saved: plain)
        XCTAssertEqual(third.writes,
                       [.dockAutohide(true), .menuBarHidden(true), .desktopIcons(false)])
        XCTAssertNil(third.save)
    }

    // MARK: - Giving it back

    func testTheBreakPutsHisOwnSettingsBackAndThrowsTheFileAway() {
        let hidden = SystemChrome(dockAutohide: true, menuBarHidden: true, desktopIcons: false)
        let plan = CleanFocus.restore(saved: plain, current: hidden)
        XCTAssertEqual(plan.writes,
                       [.dockAutohide(false), .menuBarHidden(false), .desktopIcons(true)])
        XCTAssertTrue(plan.killDock)
        XCTAssertTrue(plan.killFinder)
        XCTAssertTrue(plan.clearSaved)
        XCTAssertNil(plan.save)
    }

    func testRestoringGivesBackWhatHeHadNotWhatIsNormal() {
        // He auto-hid the Dock himself but kept the menu bar; the desktop icons
        // were already off. Restore must return exactly that, not a clean slate.
        let his = SystemChrome(dockAutohide: true, menuBarHidden: false, desktopIcons: false)
        let hidden = SystemChrome(dockAutohide: true, menuBarHidden: true, desktopIcons: false)
        let plan = CleanFocus.restore(saved: his, current: hidden)
        XCTAssertEqual(plan.writes, [.menuBarHidden(false)])
        XCTAssertTrue(plan.clearSaved)
    }

    func testRestoringWithNothingSavedDoesNothingAtAll() {
        XCTAssertTrue(CleanFocus.restore(saved: nil, current: plain).isEmpty)
    }

    func testRestoringTwiceIsHarmless() {
        // The break restored; the session then ends and restores again with the
        // file already gone. Nothing is written a second time.
        let first = CleanFocus.restore(saved: plain, current: SystemChrome(dockAutohide: true,
                                                                          menuBarHidden: true))
        XCTAssertFalse(first.writes.isEmpty)
        XCTAssertTrue(CleanFocus.restore(saved: nil, current: plain).isEmpty)
    }

    // MARK: - After a crash

    func testALaunchThatFindsARestoreFilePutsEverythingBack() {
        // The app was killed mid-block: the Dock and menu bar are still hidden
        // and the file from before the first block is still on disk.
        let hidden = SystemChrome(dockAutohide: true, menuBarHidden: true, desktopIcons: false)
        let plan = CleanFocus.recover(saved: plain, current: hidden)
        XCTAssertEqual(plan.writes,
                       [.dockAutohide(false), .menuBarHidden(false), .desktopIcons(true)])
        XCTAssertTrue(plan.clearSaved)
    }

    func testANormalLaunchWithNoFileDoesNothing() {
        XCTAssertTrue(CleanFocus.recover(saved: nil, current: plain).isEmpty)
    }

    func testCrashRecoveryIsExactlyTheSameThingAsRestoring() {
        let hidden = SystemChrome(dockAutohide: true, menuBarHidden: true)
        XCTAssertEqual(CleanFocus.recover(saved: plain, current: hidden),
                       CleanFocus.restore(saved: plain, current: hidden))
    }

    func testTheSavedStateSurvivesARoundTripThroughTheFile() throws {
        let his = SystemChrome(dockAutohide: true, menuBarHidden: false, desktopIcons: false)
        let data = try JSONEncoder().encode(his)
        XCTAssertEqual(try JSONDecoder().decode(SystemChrome.self, from: data), his)
    }

    // MARK: - The commands themselves

    func testEachWriteNamesTheRealDefaultsKey() {
        XCTAssertEqual(ChromeWrite.dockAutohide(true).command.domain, "com.apple.dock")
        XCTAssertEqual(ChromeWrite.dockAutohide(true).command.key, "autohide")
        XCTAssertEqual(ChromeWrite.menuBarHidden(true).command.domain, "NSGlobalDomain")
        XCTAssertEqual(ChromeWrite.menuBarHidden(true).command.key, "_HIHideMenuBar")
        XCTAssertEqual(ChromeWrite.desktopIcons(false).command.domain, "com.apple.finder")
        XCTAssertEqual(ChromeWrite.desktopIcons(false).command.key, "CreateDesktop")
        XCTAssertFalse(ChromeWrite.desktopIcons(false).command.value)
    }

    func testWhatABlockWantsIsOnlyEverAboutTheTogglesHeTurnedOn() {
        // Desktop icons alone: the Dock and the menu bar are left exactly as they are.
        let iconsOnly = CleanFocusPrefs(hideDesktopIcons: true)
        let his = SystemChrome(dockAutohide: true, menuBarHidden: false, desktopIcons: true)
        let want = CleanFocus.wanted(prefs: iconsOnly, from: his)
        XCTAssertEqual(want, SystemChrome(dockAutohide: true, menuBarHidden: false,
                                          desktopIcons: false))
        XCTAssertEqual(CleanFocus.engage(prefs: iconsOnly, current: his, saved: nil).writes,
                       [.desktopIcons(false)])
    }
}
