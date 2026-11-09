import XCTest
import AVFoundation
@testable import ShadowKit

final class CoreLogicTests: XCTestCase {
    // MARK: scrubber (A4)
    func testScrubberRemovesHomeUserAndTokens() {
        let line = "open /Users/jdoe/Library/x failed for jdoe token=abc123SECRET https://u:p4ss@host/x Bearer abc.def-ghi sk-abcdefghijklmnop mail me@example.com"
        let out = LogScrubber.scrub(line, home: "/Users/jdoe", user: "jdoe")
        for leaked in ["/Users/jdoe", "jdoe", "abc123SECRET", "p4ss", "abc.def-ghi", "sk-abcdefghijklmnop", "me@example.com"] {
            XCTAssertFalse(out.contains(leaked), leaked + " in " + out)
        }
        XCTAssertTrue(out.contains("~/Library/x"))
    }

    // MARK: language (A11)
    func testLanguageMapping() {
        XCTAssertEqual(Language.allCases.map(\.label), ["Auto", "English", "Español", "Deutsch", "Français", "Japanese"])
        XCTAssertEqual(Language.english.fixedLocale?.identifier, "en-US")
        XCTAssertEqual(Language.spanish.fixedLocale?.identifier, "es-ES")
        XCTAssertEqual(Language.german.fixedLocale?.identifier, "de-DE")
        XCTAssertEqual(Language.french.fixedLocale?.identifier, "fr-FR")
        XCTAssertEqual(Language.japanese.fixedLocale?.identifier, "ja-JP")
        XCTAssertNil(Language.auto.fixedLocale)
    }

    func testAutoPicksFirstSupportedPreferredLanguage() {
        let supported = ["en-US", "ja-JP", "de-DE"].map(Locale.init(identifier:))
        XCTAssertEqual(Language.auto.resolve(preferred: ["ja-JP", "en-US"], supported: supported).identifier, "ja-JP")
        XCTAssertEqual(Language.auto.resolve(preferred: ["ko-KR", "de-AT"], supported: supported).identifier, "de-DE")
        XCTAssertEqual(Language.auto.resolve(preferred: ["ko-KR", "zh-CN"], supported: supported).identifier, "en-US")
        XCTAssertEqual(Language.auto.resolve(preferred: [], supported: []).identifier, "en-US")
    }

    // MARK: transcript (A12, A14)
    private func seg(_ s: Speaker, _ t: String, _ start: Double, final: Bool) -> Segment {
        Segment(speaker: s, text: t, start: start, end: start + 1, isFinal: final)
    }

    func testFinalReplacesPartialAndTwoSpeakersAreIndependent() async {
        let t = Transcript()
        await t.add(seg(.them, "hel", 1, final: false))
        await t.add(seg(.you, "yo", 1.5, final: false))
        await t.add(seg(.them, "hello", 1, final: true))
        let s = await t.snapshot
        XCTAssertEqual(s.finals.map(\.text), ["hello"])
        XCTAssertNil(s.partials[.them])
        XCTAssertEqual(s.partials[.you]?.text, "yo")
    }

    func testOutOfOrderFinalsSortByStart() async {
        let t = Transcript()
        await t.add(seg(.them, "b", 5, final: true))
        await t.add(seg(.you, "a", 2, final: true))
        await t.add(seg(.them, "c", 9, final: true))
        let texts = await t.snapshot.finals.map(\.text)
        XCTAssertEqual(texts, ["a", "b", "c"])
    }

    func testCapDropsOldestFinals() async {
        let t = Transcript(cap: 3)
        for i in 0..<5 { await t.add(seg(.them, "\(i)", Double(i), final: true)) }
        let texts = await t.snapshot.finals.map(\.text)
        XCTAssertEqual(texts, ["2", "3", "4"])
    }

    func testFlushTurnsPartialsIntoFinals() async {
        let t = Transcript()
        await t.add(seg(.you, "half", 3, final: false))
        await t.flushPartials()
        let s = await t.snapshot
        XCTAssertTrue(s.partials.isEmpty)
        XCTAssertEqual(s.finals.map(\.text), ["half"])
        XCTAssertTrue(s.finals[0].isFinal)
    }

    func testStreamEmitsOnEachChange() async {
        let t = Transcript()
        var it = await t.updates().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.lines.count, 0)
        await t.add(seg(.them, "x", 1, final: false))
        let second = await it.next()
        XCTAssertEqual(second?.partials[.them]?.text, "x")
        await t.add(seg(.them, "xy", 1, final: true))
        let third = await it.next()
        XCTAssertEqual(third?.finals.map(\.text), ["xy"])
    }

    func testFormatterLabelsSpeakersInTimeOrder() {
        let lines = [seg(.them, "How are you?", 1, final: true), seg(.you, "Fine.", 2, final: false), seg(.them, "", 3, final: false)]
        XCTAssertEqual(TranscriptFormatter.text(lines), "Them: How are you?\nYou: Fine.")
    }

    // MARK: level meter (A6)
    private func buffer(_ value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        b.frameLength = 160
        for i in 0..<160 { b.floatChannelData![0][i] = value }
        return b
    }

    func testLevelOfSilentHalfAndFullScale() {
        XCTAssertEqual(LevelMeter.level(of: buffer(0)), 0)
        XCTAssertEqual(LevelMeter.level(of: buffer(0.5)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(LevelMeter.level(of: buffer(1)), 1, accuracy: 1e-5)
        XCTAssertEqual(LevelMeter.level(of: [Float]()), 0)
    }

    // MARK: hotkeys (A18)
    func testDefaultsMatchSpec() {
        let d = HotkeyMap.defaults
        XCTAssertEqual(d[.toggleSession]?.string, "cmd+shift+space")
        XCTAssertEqual(d[.toggleOverlay]?.string, "cmd+shift+h")
        XCTAssertEqual(d[.toggleClickThrough]?.string, "cmd+shift+t")
        XCTAssertEqual(d[.toggleCompact]?.string, "cmd+shift+e")
    }

    func testHotkeyStringsRoundTrip() {
        for s in ["cmd+shift+space", "opt+ctrl+j", "cmd+1", "cmd+shift+left"] {
            XCTAssertEqual(Hotkey(s)?.string, s)
        }
        XCTAssertEqual(Hotkey("Shift + Cmd + H")?.string, "cmd+shift+h")
        XCTAssertEqual(Hotkey("cmd+shift+space")?.keyCode, 49)
    }

    func testInvalidHotkeysAreRejected() {
        for s in ["", "space", "cmd", "cmd+cmd+a", "cmd+a+b", "hyper+a", "cmd+"] { XCTAssertNil(Hotkey(s), s) }
    }

    func testDuplicateBindingIsRejectedWithFriendlyMessage() {
        let d = HotkeyMap.defaults
        if case .success = d.binding(.toggleOverlay, to: "cmd+shift+t") { XCTFail("duplicate accepted") }
        if case .failure(let e) = d.binding(.toggleOverlay, to: "nonsense") { XCTAssertTrue(e.message.contains("isn't valid")) } else { XCTFail() }
        // rebinding to its own value, or to a free key, works
        if case .success(let m) = d.binding(.toggleOverlay, to: "cmd+shift+k") { XCTAssertEqual(m[.toggleOverlay]?.string, "cmd+shift+k") } else { XCTFail() }
        if case .failure = d.binding(.toggleOverlay, to: "cmd+shift+h") { XCTFail("own binding rejected") }
    }
}
