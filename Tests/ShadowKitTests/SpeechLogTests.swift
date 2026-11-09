import XCTest
@testable import ShadowKit

final class SpeechLogTests: XCTestCase {
    func testLineHasLocaleDomainAndCode() {
        let error = NSError(domain: "SFSpeechErrorDomain", code: 17)
        let line = SpeechLog.line(context: "transcribe you", locale: Locale(identifier: "en_US"), error: error)
        XCTAssertEqual(line, "transcribe you [en-US]: SFSpeechErrorDomain Code=17")
    }

    func testLineNeverIncludesTranscriptText() {
        let secret = "my card number is four two four two"
        let error = NSError(domain: "SFSpeechErrorDomain", code: 17, userInfo: [
            NSLocalizedDescriptionKey: secret, NSLocalizedFailureReasonErrorKey: secret, "text": secret,
        ])
        let line = SpeechLog.line(context: "transcribe them", locale: Locale(identifier: "en-US"), error: error)
        XCTAssertFalse(line.contains(secret))
        XCTAssertFalse(line.contains("card"))
    }
}
