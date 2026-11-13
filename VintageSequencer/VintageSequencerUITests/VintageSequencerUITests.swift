import XCTest

// MARK: - Slice 12b — XCUI Smoke Tests
//
// MacOS SwiftUI + XCUI — bekannte Einschränkungen dieser Testschicht:
//
//   ERREICHBAR   : app.state, app.menuBars, app.menuBarItems (System-Level)
//   NICHT ERREICHBAR: app.windows, app.buttons, accessibilityIdentifier in Views
//
// Ursache (diagnostisch bestätigt, 2026-04-13):
//   SwiftUI WindowGroup / .buttonStyle(.plain) exposen kein NSWindow in app.windows.
//   app.descendants(matching:.any).matching(identifier:"playStopButton").count = 0
//   → accessibilityIdentifier fließt auf macOS nicht in XCUI-Tree durch.
//
// Konsequenz: Play/Stop wird nicht über UI-Button sondern über Sequencer-Menü getestet.
// Das Sequencer-Menü (CommandMenu) ist über app.menuBarItems vollständig erreichbar.
// Der Button trägt weiterhin .accessibilityIdentifier/.accessibilityValue —
// für zukünftige Xcode-Versionen / alternative Testframeworks.
//
// Tests:
//   1. App startet, läuft im Vordergrund
//   2. Menüleiste ist erreichbar; "File"- und "Sequencer"-Menüs existieren
//   3. File-Menü hat mindestens einen Eintrag
//   4. Play/Stop via Sequencer-Menü: label wechselt nach Klick

final class SmokeTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - 1. App Start

    /// App startet und läuft im Vordergrund.
    ///
    /// Hinweis: app.windows.firstMatch.exists ist auf diesem macOS/SwiftUI-Setup
    /// nicht zuverlässig (diagnostisch bestätigt: WINDOWS COUNT = 0 selbst nach 2s).
    /// App-State ist der zuverlässige Anker.
    @MainActor
    func testAppLaunchesSuccessfully() throws {
        XCTAssertEqual(app.state, .runningForeground,
                       "App muss nach Launch im Vordergrund laufen (state == .runningForeground)")
    }

    // MARK: - 2. Menüstruktur

    /// macOS-Menüleiste ist erreichbar.
    /// "File"- und "Sequencer"-Menü-Einträge müssen existieren.
    @MainActor
    func testMenuBarItemsExist() throws {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.exists, "macOS-Menüleiste muss erreichbar sein")

        let fileMenu = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists,
                      "File-Menü muss in der Menüleiste vorhanden sein")

        let sequencerMenu = menuBar.menuBarItems["Sequencer"]
        XCTAssertTrue(sequencerMenu.exists,
                      "Sequencer-Menü muss in der Menüleiste vorhanden sein")
    }

    /// File-Menü enthält mindestens einen Eintrag.
    @MainActor
    func testFileMenuContainsExpectedItems() throws {
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists)
        fileMenu.click()

        XCTAssertGreaterThan(fileMenu.menuItems.count, 0,
                             "File-Menü muss mindestens einen Eintrag enthalten")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - 3. Play/Stop via Sequencer-Menü

    /// Sequencer-Menü enthält einen Play/Stop-Eintrag und reagiert auf Klick.
    ///
    /// Ablauf:
    ///   1. Sequencer-Menü öffnen → erster Eintrag ist "Play" (label merken)
    ///   2. Menü schließen, Eintrag via Klick auslösen (Tastenkürzel Space)
    ///   3. Sequencer-Menü erneut öffnen → erster Eintrag muss sich geändert haben ("Stop")
    ///   4. Stop auslösen → Ausgangszustand wiederherstellen
    ///
    /// Testablauf ist stabil: Menüleiste auf macOS immer erreichbar, kein window-Lookup nötig.
    @MainActor
    func testPlayStopViaSequencerMenu() throws {
        let menuBar      = app.menuBars.firstMatch
        let sequencerBar = menuBar.menuBarItems["Sequencer"]
        XCTAssertTrue(sequencerBar.exists, "Sequencer-Menüleisteneintrag muss existieren")

        // --- Schritt 1: Ausgangszustand — erster Eintrag lesen ---
        sequencerBar.click()
        let firstItemBefore = sequencerBar.menuItems.firstMatch
        XCTAssertTrue(firstItemBefore.exists,
                      "Sequencer-Menü muss mindestens einen Eintrag haben")
        let labelBefore = firstItemBefore.title
        app.typeKey(.escape, modifierFlags: [])

        // --- Schritt 2: Play auslösen (Space-Shortcut) ---
        // Space ist der definierte Shortcut für Play/Stop (.keyboardShortcut(.space, modifiers: []))
        app.typeKey(" ", modifierFlags: [])

        // Kurze Pause: Sequencer-State muss sich propagieren
        Thread.sleep(forTimeInterval: 0.3)

        // --- Schritt 3: Sequencer-Menü erneut öffnen → Label muss sich geändert haben ---
        sequencerBar.click()
        let firstItemAfter = sequencerBar.menuItems.firstMatch
        XCTAssertTrue(firstItemAfter.exists)
        let labelAfter = firstItemAfter.title
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertNotEqual(labelBefore, labelAfter,
                          "Sequencer-Menü-Label muss nach Play-Auslösung von '\(labelBefore)' auf '\(labelAfter)' wechseln")

        // --- Schritt 4: Stop auslösen — Ausgangszustand wiederherstellen ---
        app.typeKey(" ", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Verify: Label ist wieder der Ausgangswert
        sequencerBar.click()
        let labelReset = sequencerBar.menuItems.firstMatch.title
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(labelBefore, labelReset,
                       "Nach Stop muss Menü-Label wieder '\(labelBefore)' sein, ist aber '\(labelReset)'")
    }
}
