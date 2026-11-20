import XCTest
final class NativeProbe: XCTestCase {
  func testNativeControls() {
    let app = XCUIApplication(bundleIdentifier: "com.briconbric.bobtv")
    app.activate()
    app.tap()
    print("NATIVE_TREE", app.debugDescription)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Native player controls"; screenshot.lifetime = .keepAlways; add(screenshot)
    XCTAssert(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'AirPlay' OR label CONTAINS '隔空播放'")).count > 0)
  }
  func testStartPictureInPicture() {
    let app = XCUIApplication(bundleIdentifier: "com.briconbric.bobtv")
    app.activate(); app.tap()
    print("PIP_TREE", app.debugDescription)
    let playback = app.buttons["Play/Pause"]
    if playback.exists && playback.label == "Play" { playback.tap() }
    let pip = app.buttons["PIP Button"]
    XCTAssert(pip.waitForExistence(timeout: 4)); pip.tap()
    sleep(2)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Started Picture in Picture"; screenshot.lifetime = .keepAlways; add(screenshot)
    XCUIDevice.shared.press(.home)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let floating = springboard.windows["PIP-SBInteractionPassThroughView"]
    XCTAssert(floating.waitForExistence(timeout: 4))
    let background = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    background.name = "Picture in Picture on Home"; background.lifetime = .keepAlways; add(background)
    floating.tap()
    let restore = springboard.buttons["恢复全屏幕"]
    XCTAssert(restore.waitForExistence(timeout: 4)); restore.tap()
    app.tap()
    let resumedPlayback = app.buttons["Play/Pause"]
    if resumedPlayback.exists && resumedPlayback.label == "Play" { resumedPlayback.tap() }
    let close = app.buttons["Close Button"]
    XCTAssert(close.waitForExistence(timeout: 4))
    let restored = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    restored.name = "Restored system player"; restored.lifetime = .keepAlways; add(restored)
    close.tap(); sleep(1)
    XCTAssertFalse(app.buttons["AirPlay"].exists)
    XCTAssert(app.staticTexts["BobTV"].waitForExistence(timeout: 4))
  }
  func testAllowSpeech() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let app = XCUIApplication(bundleIdentifier: "com.briconbric.bobtv")
    app.activate()
    let systemAlert = springboard.alerts.firstMatch
    let appAlert = app.alerts.firstMatch
    let alert = systemAlert.waitForExistence(timeout: 4) ? systemAlert : appAlert
    XCTAssert(alert.waitForExistence(timeout: 4))
    print("PERMISSION_TREE", alert.debugDescription)
    let screenshot = XCTAttachment(screenshot: springboard.screenshot())
    screenshot.name = "Speech permission"; screenshot.lifetime = .keepAlways; add(screenshot)
    let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'OK' OR label == '允许' OR label == '好' ")).firstMatch
    XCTAssert(allow.exists); allow.tap()
    sleep(2)
    XCTAssertFalse(alert.exists)
  }
}
