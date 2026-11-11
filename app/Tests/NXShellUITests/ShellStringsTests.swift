import XCTest

@testable import NXShellUI

final class ShellStringsTests: XCTestCase {
    func testEveryKeyHasBothLanguages() {
        for key in ShellStrings.Key.allCases {
            XCTAssertFalse(ShellStrings.text(key, language: "en").isEmpty, "\(key) has no English")
            XCTAssertFalse(ShellStrings.text(key, language: "fr").isEmpty, "\(key) has no French")
        }
    }

    func testNoTranslationIsLeftAsTheKey() {
        for key in ShellStrings.Key.allCases {
            XCTAssertNotEqual(ShellStrings.text(key, language: "fr").lowercased(), key.rawValue.lowercased(),
                              "\(key) is untranslated in French")
        }
    }

    func testFallsBackToEnglishForAnUnknownLanguage() {
        XCTAssertEqual(ShellStrings.text(.library, language: "de"), "Library")
        XCTAssertEqual(ShellStrings.text(.library, language: "fr-CA"), "Bibliothèque")
        XCTAssertEqual(ShellStrings.text(.library, language: "fr"), "Bibliothèque")
    }
}

final class SettingStringsTests: XCTestCase {
    func testTheCommonRowsHaveFrenchAndTheOthersKeepTheGamesEnglish() {
        XCTAssertEqual(ShellStrings.settingLabel("DM_OPMODE", english: "Console mode", language: "fr-FR"), "Mode de la console")
        XCTAssertEqual(ShellStrings.settingLabel("DM_OPMODE", english: "Console mode", language: "en"), "Console mode")
        XCTAssertEqual(ShellStrings.settingLabel("DM_SOMETHING_NEW", english: "Something new", language: "fr"), "Something new")
        XCTAssertEqual(ShellStrings.settingOption("DM_OPMODE", value: "0", english: "Handheld", language: "fr"), "Portable")
        XCTAssertEqual(ShellStrings.settingOption("DM_LANG", value: "xx", english: "Other", language: "fr"), "Other")
        XCTAssertEqual(ShellStrings.settingSection("Controls", language: "fr"), "Commandes")
        XCTAssertNil(ShellStrings.settingNote("DM_OPMODE", english: "", language: "fr"), "no note, no line")
    }

    func testEveryFrenchNoteAndOptionBelongsToARowWithAFrenchLabel() {
        for env in ShellStrings.frenchNotes.keys { XCTAssertNotNil(ShellStrings.frenchLabels[env], env) }
        for key in ShellStrings.frenchOptions.keys {
            XCTAssertNotNil(ShellStrings.frenchLabels[String(key.prefix { $0 != "=" })], key)
        }
    }
}
