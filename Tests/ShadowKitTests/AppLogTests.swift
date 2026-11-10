// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import ShadowKit

final class AppLogTests: XCTestCase {
    /// Tests must never write into the user's real ~/Library/Application Support/Shadow/app.log.
    func testLogFileIsRedirectedUnderXCTest() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        XCTAssertFalse(AppLog.fileURL.path.hasPrefix(real), AppLog.fileURL.path)
        XCTAssertTrue(AppLog.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
