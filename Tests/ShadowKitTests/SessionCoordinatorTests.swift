import XCTest
@testable import ShadowKit

@MainActor private final class Flag { var value: Bool; init(_ v: Bool) { value = v } }

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-\(UUID().uuidString)")
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func seg(_ s: Speaker, _ t: String, final: Bool = true) -> Segment {
        Segment(speaker: s, text: t, start: 0.1, end: 1, locale: "en-US", confidence: 0.9, isFinal: final)
    }

    private func controller(stt: FakeSTTProvider? = nil) -> SessionController {
        SessionController(them: FakeAudioSource(script: [(0.1, 0.5)]), you: FakeAudioSource(script: [(0.2, 0.25)]),
                          stt: stt ?? FakeSTTProvider(scripts: [.them: [seg(.them, "hello")], .you: [seg(.you, "hi there")]]),
                          store: SessionStore(directory: dir))
    }

    private func coordinator(mic: PermissionState = .granted, screen: PermissionState = .granted, registrar: FakeRegistrar = FakeRegistrar(), remind: Bool = false, confirm: @escaping @MainActor () -> Bool = { true },
                             make: @escaping @MainActor () -> SessionController?) -> SessionCoordinator {
        SessionCoordinator(permissions: PermissionCenter(checker: MutableChecker(mic: mic, screen: screen), registrar: registrar,
                                                         history: PermissionHistory(defaults: UserDefaults(suiteName: "coord-\(UUID().uuidString)")!)),
                           makeController: make, remindBeforeSession: { remind }, confirmReminder: confirm,
                           locale: { Locale(identifier: "en-US") })
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    private func sessionFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
    }

    func testStartLiveTranscriptStopWritesSessionJSON() async throws {
        let c = coordinator { self.controller() }
        var running: [Bool] = []
        c.onRunningChange = { running.append($0) }

        await c.toggle()
        XCTAssertTrue(c.isRunning)
        XCTAssertNotNil(c.startedAt)
        await waitUntil("live transcript reaches the model") { c.transcript.finals.count == 2 }
        await waitUntil("meters move") { c.levels.them > 0 && c.levels.you > 0 }

        await c.toggle()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(running, [true, false])
        XCTAssertEqual(c.levels, Levels())
        XCTAssertNil(c.startedAt)
        XCTAssertEqual(c.transcript.finals.map(\.text).sorted(), ["hello", "hi there"])
        let files = sessionFiles()
        XCTAssertEqual(files.count, 1)
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: files[0]))
        XCTAssertEqual(record.segments.count, 2)
        XCTAssertNotNil(record.endedAt)
        XCTAssertNil(c.message)
    }

    // A4
    func testMissingPermissionRegistersOncePerMissingShowsChecklistAndStartsNothing() async {
        let cases: [(PermissionState, PermissionState, [PermissionKind])] = [
            (.notGranted, .granted, [.microphone]), (.granted, .notYetAsked, [.screen]), (.notYetAsked, .notGranted, [.screen, .microphone]),
        ]
        for (mic, screen, expected) in cases {
            var made = 0
            let reg = FakeRegistrar()
            let c = coordinator(mic: mic, screen: screen, registrar: reg) { made += 1; return self.controller() }
            var popovers = 0
            c.onNeedPopover = { popovers += 1 }
            await c.toggle()
            XCTAssertEqual(reg.registered, expected)
            XCTAssertEqual(made, 0)
            XCTAssertTrue(c.showChecklist)
            XCTAssertEqual(c.phase, .idle)
            XCTAssertEqual(popovers, 1)
        }
    }

    func testAllGrantedStartsWithoutRegistering() async {
        let reg = FakeRegistrar()
        let c = coordinator(registrar: reg) { self.controller() }
        await c.toggle()
        XCTAssertTrue(c.isRunning)
        XCTAssertEqual(reg.registered, [])
        await c.toggle()
    }

    func testDeclinedReminderStartsNothing() async {
        var made = 0
        let c = coordinator(remind: true, confirm: { false }) { made += 1; return self.controller() }
        await c.toggle()
        XCTAssertEqual(made, 0)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.message)
    }

    func testReminderOffSkipsTheDialog() async {
        var asked = 0
        let c = coordinator(remind: false, confirm: { asked += 1; return true }) { self.controller() }
        await c.toggle()
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(c.isRunning)
        await c.toggle()
    }

    func testToggleDuringReminderCannotStartASecondSession() async {
        var made = 0
        var c: SessionCoordinator!
        c = coordinator(remind: true, confirm: {
            XCTAssertEqual(c.phase, .starting)   // a hotkey during the modal sees "starting" and is ignored
            return true
        }) { made += 1; return self.controller() }
        await c.toggle()
        XCTAssertEqual(made, 1)
        await c.toggle()
    }

    func testMidSessionSpeechFailureReachesTheUser() async {
        let stt = FakeSTTProvider(scripts: [.you: [seg(.you, "still here")]],
                                  failures: [.them: (afterSegments: 0, error: UserFacingError("The language model is missing."))])
        let c = coordinator { self.controller(stt: stt) }
        var popovers = 0
        c.onNeedPopover = { popovers += 1 }
        await c.toggle()
        await waitUntil("notice shown") { c.message?.contains("Speech recognition stopped for Them") == true }
        XCTAssertGreaterThanOrEqual(popovers, 1)
        XCTAssertTrue(c.isRunning, "the other stream keeps going")
        await c.toggle()
        XCTAssertEqual(c.phase, .idle)
    }

    func testCaptureDyingMidSessionReachesTheUserButNormalStopDoesNot() async {
        let them = FakeAudioSource(script: [(0.1, 0.5)])
        let c = coordinator {
            SessionController(them: them, you: FakeAudioSource(script: []), stt: FakeSTTProvider(scripts: [:]), store: SessionStore(directory: self.dir))
        }
        await c.toggle()
        await them.stop()   // the system audio stream dies by itself
        await waitUntil("lost-source notice") { c.message?.contains("lost system audio") == true }
        await c.toggle()
        XCTAssertEqual(c.message?.components(separatedBy: "\n").count, 1, "Stop adds no extra notice")

        let quiet = coordinator { self.controller() }
        await quiet.toggle(); await quiet.toggle()
        XCTAssertNil(quiet.message)
    }

    func testStartFailureIsFriendlyAndLeavesRoomToRetry() async {
        let stt = FakeSTTProvider(scripts: [:], prepareError: UserFacingError("Couldn't download the speech model."))
        let useBad = Flag(true)
        let c = coordinator { useBad.value ? self.controller(stt: stt) : self.controller() }
        await c.toggle()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.message, "Couldn't download the speech model.")
        XCTAssertTrue(sessionFiles().isEmpty)
        useBad.value = false
        await c.toggle()
        XCTAssertTrue(c.isRunning)
        XCTAssertNil(c.message)
        await c.toggle()
    }

    func testNoControllerGivesAMessage() async {
        let c = coordinator { nil }
        await c.toggle()
        XCTAssertNotNil(c.message)
        XCTAssertEqual(c.phase, .idle)
    }

    func testShutdownStopsARunningSessionAndWritesIt() async {
        let c = coordinator { self.controller() }
        await c.toggle()
        await c.shutdown()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(sessionFiles().count, 1)
    }

    func testDuplicateNoticesAreNotRepeated() {
        let c = coordinator { nil }
        c.showNotice("A"); c.showNotice("A"); c.showNotice("B")
        XCTAssertEqual(c.message, "A.\nB.")
        XCTAssertEqual(c.notices.count, 2)
    }

    func testDismissingOneNoticeKeepsTheOthers() {
        let c = coordinator { nil }
        c.showNotice("A"); c.showNotice("B.")
        c.dismissNotice(c.notices[0].id)
        XCTAssertEqual(c.notices.map(\.text), ["B."])
        c.clearNotices()
        XCTAssertNil(c.message)
    }

    func testElapsedFormat() {
        XCTAssertEqual(ElapsedFormat.string(7), "0:07")
        XCTAssertEqual(ElapsedFormat.string(754), "12:34")
        XCTAssertEqual(ElapsedFormat.string(3723), "1:02:03")
        XCTAssertEqual(ElapsedFormat.string(-5), "0:00")
        XCTAssertEqual(ElapsedFormat.string(.nan), "0:00")
    }
}
