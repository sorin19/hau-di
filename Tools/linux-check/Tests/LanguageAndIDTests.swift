import XCTest
@testable import HauDiCore

final class UUIDv7Tests: XCTestCase {
    func testFormat() {
        let date = Date(timeIntervalSince1970: 1_795_000_000.123)
        let uuid = UUIDv7.make(date: date)
        let text = uuid.uuidString.lowercased()
        XCTAssertTrue(UUIDv7.isValid(text))
        XCTAssertTrue(UUIDv7.isValid(text.uppercased()))
        XCTAssertEqual(Array(text)[14], "7")
        XCTAssertTrue("89ab".contains(Array(text)[19]))
        XCTAssertEqual(UUIDv7.date(of: uuid).timeIntervalSince1970, 1_795_000_000.123, accuracy: 0.001)
        // A v4 UUID (the old ID) is not v7 and gets replaced.
        XCTAssertFalse(UUIDv7.isValid("3f2c1e9a-8b7d-4c6e-9f10-a1b2c3d4e5f6"))
        XCTAssertFalse(UUIDv7.isValid("nu-e-uuid"))
    }

    func testOrderedInTimeAndRandom() {
        let earlier = UUIDv7.make(date: Date(timeIntervalSince1970: 1_795_000_000)).uuidString
        let later = UUIDv7.make(date: Date(timeIntervalSince1970: 1_795_000_001)).uuidString
        XCTAssertLessThan(earlier, later)
        let sameMoment = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertNotEqual(UUIDv7.make(date: sameMoment), UUIDv7.make(date: sameMoment))
    }
}

final class DictationLanguageTests: XCTestCase {
    func testMigrationFromOldSettings() {
        XCTAssertEqual(DictationLanguage.fromStored("ro+en").language, .romanian)
        XCTAssertTrue(DictationLanguage.fromStored("ro+en").mixesEnglish)
        XCTAssertEqual(DictationLanguage.fromStored("auto").language, .romanian)
        XCTAssertTrue(DictationLanguage.fromStored(nil).mixesEnglish)
        XCTAssertEqual(DictationLanguage.fromStored("hu").language, .hungarian)
        XCTAssertFalse(DictationLanguage.fromStored("hu").mixesEnglish)
        XCTAssertEqual(DictationLanguage.allCases.map(\.code), ["ro", "en", "de", "fr", "es", "it", "hu"])
    }

    func testPromptForMixedEnglish() {
        let romglish = CorrectionPrompt.systemPrompt(config: CorrectionConfig(language: .romanian, mixesEnglish: true))
        XCTAssertTrue(romglish.contains("The user dictates in Romanian, and the speech recognizer was set to Romanian."))
        XCTAssertTrue(romglish.contains("(Romglish), for example \"diploi\" for \"deploy\""))
        XCTAssertTrue(romglish.contains("\"meeting-ul\", \"deploy-ul\""))
        XCTAssertTrue(romglish.contains("never translate between Romanian and English"))
        XCTAssertTrue(romglish.contains("must use correct diacritics"))

        let hunglish = CorrectionPrompt.systemPrompt(config: CorrectionConfig(language: .hungarian, mixesEnglish: true))
        XCTAssertTrue(hunglish.contains("Write the final text in Hungarian"))
        XCTAssertTrue(hunglish.contains("(Hunglish), for example \"diplój\" for \"deploy\""))
        XCTAssertFalse(hunglish.contains("Romglish"))

        let german = CorrectionPrompt.systemPrompt(config: CorrectionConfig(language: .german, mixesEnglish: true))
        XCTAssertTrue(german.contains("mixes English words and phrases into German speech. The recognizer may have written them the way they sound in German. Write every word"))

        let pure = CorrectionPrompt.systemPrompt(config: CorrectionConfig(language: .romanian, mixesEnglish: false))
        XCTAssertFalse(pure.contains("Romglish"))
        XCTAssertTrue(pure.contains("An English technical term the user says stays in English"))

        let english = CorrectionPrompt.systemPrompt(config: CorrectionConfig(language: .english, mixesEnglish: true))
        XCTAssertTrue(english.contains("Write the final text in English"))
        XCTAssertFalse(english.contains("mixes English words"))
        XCTAssertFalse(english.contains("An English technical term"))
    }
}

final class DiacriticsPerLanguageTests: XCTestCase {
    func testStripFollowsTheLanguage() {
        XCTAssertEqual(Diacritics.strip("Äpfel für Straße, Öl, Übung", language: .german), "Aepfel fuer Strasse, Oel, Uebung")
        XCTAssertEqual(Diacritics.strip("año, mañana, canción, pingüino", language: .spanish), "año, mañana, cancion, pinguino")
        XCTAssertEqual(Diacritics.strip("Œuvre, cœur, élève, français", language: .french), "Oeuvre, coeur, eleve, francais")
        XCTAssertEqual(Diacritics.strip("köszönöm, szép, tűz", language: .hungarian), "koszonom, szep, tuz")
        XCTAssertEqual(Diacritics.strip("perché città", language: .italian), "perche citta")
        XCTAssertEqual(Diacritics.strip("Știința și țara"), "Stiinta si tara", "default: Romanian")
    }

    func testLettersAndPromptRules() {
        XCTAssertNil(DictationLanguage.english.diacriticLetters)
        XCTAssertNil(DictationLanguage.english.diacriticsLabel)
        XCTAssertEqual(DictationLanguage.german.diacriticsLabel, "With umlauts and ß (ä ö ü ß)")
        XCTAssertFalse(DictationLanguage.spanish.diacriticsLabel?.contains("ñ") ?? true, "ñ stays even without accents")
        XCTAssertEqual(Set(DictationLanguage.allCases.filter { $0.diacriticsLabel == nil }), [.english])
        XCTAssertEqual(DictationLanguage.romanian.diacriticLetters, "ă â î ș ț")
        let german = CorrectionPrompt.languageSection(language: .german, mixesEnglish: false, useDiacritics: false)
        XCTAssertTrue(german.contains("ä → ae"))
        XCTAssertFalse(german.contains("Romanian"))
        XCTAssertTrue(CorrectionPrompt.languageSection(language: .german, mixesEnglish: false, useDiacritics: true)
            .contains("umlauts and ß"))
        XCTAssertTrue(CorrectionPrompt.languageSection(language: .spanish, mixesEnglish: false, useDiacritics: false)
            .contains("keeps ñ"))
        XCTAssertFalse(CorrectionPrompt.languageSection(language: .english, mixesEnglish: false, useDiacritics: false)
            .contains("WITHOUT"))
        let romanian = CorrectionPrompt.languageSection(language: .romanian, mixesEnglish: true, useDiacritics: true)
        XCTAssertTrue(romanian.hasPrefix("## Language\n- The user dictates in Romanian"))
        XCTAssertTrue(romanian.contains("must use correct diacritics (ă, â, î, ș, ț)"))
    }
}
