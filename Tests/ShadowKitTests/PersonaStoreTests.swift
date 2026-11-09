import XCTest
@testable import ShadowKit

/// R14, R15 / A14, A15.
@MainActor
final class PersonaStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "persona-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testFourBuiltInsWithRealPrompts() {
        let store = PersonaStore(defaults: defaults())
        XCTAssertEqual(store.personas.map(\.name), ["Interview", "Sales", "Coding", "Meeting notes"])
        for p in store.personas {
            XCTAssertTrue(p.isBuiltIn)
            XCTAssertGreaterThan(p.systemPrompt.count, 100, p.name)
        }
        XCTAssertEqual(store.active.id, "interview")
        XCTAssertEqual(store.personas.filter { !$0.suggestsAnswers }.map(\.id), ["meetingNotes"])
    }

    func testSelectionPersistsAndLegacyValueCarriesOver() {
        let d = defaults()
        d.set("coding", forKey: "persona")   // what the old enum stored
        XCTAssertEqual(PersonaStore(defaults: d).active.id, "coding")
        let a = PersonaStore(defaults: d)
        a.select("meetingNotes")
        XCTAssertEqual(PersonaStore(defaults: d).active.id, "meetingNotes")
        a.select("nope")
        XCTAssertEqual(a.active.id, "meetingNotes")
    }

    func testPickerChangesTheNextRequestsPrompt() {
        let store = PersonaStore(defaults: defaults())
        store.selection = "sales"
        let c = ContextBuilder.build(persona: store.active, language: .english, turns: [], question: "Price?")
        XCTAssertTrue(c.system.hasPrefix(Persona.builtIn("sales")!.systemPrompt))
    }

    func testEditPersistsAndMapsLengthIntoThePrompt() {
        let d = defaults()
        let store = PersonaStore(defaults: d)
        store.update("interview", systemPrompt: "Be brief.", length: .long)
        let reloaded = PersonaStore(defaults: d).persona("interview")!
        XCTAssertEqual(reloaded.systemPrompt, "Be brief.")
        XCTAssertEqual(reloaded.effectivePrompt, "Be brief.\n\n" + AnswerLength.long.clause)
        XCTAssertEqual(Set(AnswerLength.allCases.map(\.clause)).count, 3)
        store.update("interview", name: "Renamed")
        XCTAssertEqual(store.persona("interview")?.name, "Interview")   // built-in names are fixed
    }

    func testResetRestoresBuiltInOnly() {
        let store = PersonaStore(defaults: defaults())
        store.update("coding", systemPrompt: "x", length: .short)
        store.reset("coding")
        XCTAssertEqual(store.persona("coding"), Persona.builtIn("coding"))
        let c = store.create(name: "Mine", systemPrompt: "mine")
        store.reset(c.id)
        XCTAssertEqual(store.persona(c.id)?.systemPrompt, "mine")
    }

    func testCreateDuplicateAndUniqueNames() {
        let d = defaults()
        let store = PersonaStore(defaults: d)
        let a = store.create(name: "Support", systemPrompt: "Help.")
        XCTAssertFalse(a.isBuiltIn)
        let b = store.duplicate("interview")!
        XCTAssertFalse(b.isBuiltIn)
        XCTAssertEqual(b.systemPrompt, Persona.builtIn("interview")!.systemPrompt)
        XCTAssertEqual(b.name, "Interview copy")
        XCTAssertEqual(store.duplicate("interview")?.name, "Interview copy 2")
        XCTAssertEqual(store.create(name: "  ", systemPrompt: "").name, "New persona")
        XCTAssertEqual(PersonaStore(defaults: d).personas.count, store.personas.count)   // round trip
        XCTAssertEqual(Set(store.personas.map(\.id)).count, store.personas.count)
    }

    func testBuiltInsCannotBeDeletedAndActiveDeleteFallsBack() {
        let store = PersonaStore(defaults: defaults())
        for id in ["interview", "sales", "coding", "meetingNotes"] { XCTAssertFalse(store.delete(id)) }
        XCTAssertEqual(store.personas.count, 4)
        let c = store.create(name: "Mine", systemPrompt: "m")
        store.select(c.id)
        XCTAssertTrue(store.delete(c.id))
        XCTAssertEqual(store.active.id, "interview")
        XCTAssertNil(store.persona(c.id))
    }

    func testMissingBuiltInIsRestoredFromCorruptStorage() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: PersonaStore.listKey)
        XCTAssertEqual(PersonaStore(defaults: d).personas.count, 4)
    }
}
