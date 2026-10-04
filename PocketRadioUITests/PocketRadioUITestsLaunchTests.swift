//
//  KCRW_MenuBar_PlayerUITestsLaunchTests.swift
//  KCRW MenuBar PlayerUITests
//
//  Created by Jonathan Johnson on 10/4/22.
//

import XCTest

final class KCRW_MenuBar_PlayerUITestsLaunchTests: XCTestCase {

    // Running both appearances changes the user's system setting and can leave
    // macOS in Dark mode. A launch smoke test only needs the current appearance.
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
