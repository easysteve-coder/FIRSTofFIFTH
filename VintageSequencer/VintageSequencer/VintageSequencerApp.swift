import SwiftUI
import AppKit

// Handles "Unsaved changes?" when the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: SequencerEngine?
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resign text-field focus whenever the user clicks anywhere outside a text field.
        // The click event is NOT consumed — the target view still receives it normally.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = NSApp.keyWindow,
               let hit = window.contentView?.hitTest(
                   window.contentView!.convert(event.locationInWindow, from: nil)),
               !(hit is NSTextField), !(hit is NSTextView) {
                // Ein aktives Textfeld wird über seinen Feld-Editor (NSTextView) getroffen;
                // ein Klick hinein darf die Bearbeitung nicht beenden.
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine, engine.hasUnsavedChanges else { return .terminateNow }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let alert = NSAlert()
        alert.messageText     = s.unsavedTitle
        alert.informativeText = s.unsavedMessage
        alert.addButton(withTitle: s.save)
        alert.addButton(withTitle: s.discard)
        alert.addButton(withTitle: s.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Speichern läuft asynchron (v1.16.1): beenden erst nach dem Schreiben.
            engine.savePreset { ok in
                sender.reply(toApplicationShouldTerminate: ok && !engine.hasUnsavedChanges)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

// AppStorage doesn't bind directly inside .commands — use small View wrappers.
private struct TooltipToggleItem: View {
    @AppStorage("showTooltips") private var showTooltips: Bool   = true
    @AppStorage("appLanguage")  private var lang:         String = "en"
    private var s: Str { Str(lang) }
    var body: some View {
        Toggle(s.showTooltips, isOn: $showTooltips)
            .keyboardShortcut("T", modifiers: [.command, .option])
    }
}

private struct MuteMenuItem: View {
    @ObservedObject var track: TrackViewModel
    let number: Int
    @AppStorage("appLanguage") private var lang: String = "en"
    var body: some View {
        Button(Str(lang).muteMenuItem(number, isMuted: track.data.isMuted)) {
            ModelWriter().apply(.setMuted(trackID: track.data.id,
                                          old: track.data.isMuted,
                                          new: !track.data.isMuted),
                                to: track.data, undoManager: nil)
        }
        // Kürzel ⌥1…⌥9 nur für die ersten neun Spuren: `Character("10")` ist kein
        // einzelnes Zeichen und bricht beim Menüaufbau ab.
        .modifier(OptionDigitShortcut(number: number))
    }
}

/// ⌥1…⌥9 (ab macOS 12: ohne die optionale `keyboardShortcut(_:)`-Variante aus 12.3).
private struct OptionDigitShortcut: ViewModifier {
    let number: Int
    func body(content: Content) -> some View {
        if number <= 9 {
            content.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .option)
        } else {
            content
        }
    }
}

/// Hilfe-Menü: Audio-Diagnose (v1.13.14). Beobachtet nur das Diagnose-Objekt.
private struct DiagnosticsMenuItems: View {
    @ObservedObject var diagnostics: AudioDiagnostics
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    var body: some View {
        Toggle(s.diagnosticsRecord, isOn: Binding(get: { diagnostics.isRecording },
                                                  set: { _ in diagnostics.toggle() }))
        Button(s.diagnosticsMark) { diagnostics.mark() }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(!diagnostics.isRecording)
        Button(s.diagnosticsReveal) { diagnostics.revealInFinder() }
    }
}

private struct LanguageToggleItem: View {
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    var body: some View {
        Button(s.languageToggle) { lang = lang == "en" ? "de" : "en" }
            .keyboardShortcut("L", modifiers: [.command, .option])
    }
}

@main
struct VintageSequencerApp: App {
    @StateObject private var engine     = SequencerEngine()
    @StateObject private var notesStore = NotesStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    var body: some Scene {
        WindowGroup("FIRSTofFIFTH") {
            MainView()
                // Anfangsgröße des Fensters (statt `defaultSize`, das es erst ab macOS 13 gibt).
                .frame(idealWidth: 1200, idealHeight: 700)
                .environmentObject(notesStore)
                .environmentObject(engine)
                .environmentObject(engine.transportState)
                .environmentObject(engine.presetEditorState)
                .environmentObject(engine.midiLearnState)
                .environmentObject(engine.playbackDisplay)
                .environmentObject(engine.scrollState)
                .environmentObject(engine.stepWidthState)
                .environmentObject(engine.viewportController)
                .environmentObject(engine.interactionController)
                .environmentObject(engine.clockDiagnostics)
                .environmentObject(engine.midi)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.engine = engine
                    engine.rack.diagnostics.resumeIfEnabled()
                    // Trigger lazy init of CursorController — installs
                    // Combine subscription + NSEvent flagsChanged monitor.
                    _ = engine.cursorController
                    #if DEBUG
                    // Diagnose-Tracker einmalig initialisieren.
                    // Aktivierung im Debugger: EngineChangeTracker.shared.isEnabled = true
                    //                         BodyRunCounter.shared.isEnabled = true
                    EngineChangeTracker.shared.start(engine: engine)
                    #endif
                }
        }
        .commands {
            // Remove "New Window" from File menu — single-window app
            CommandGroup(replacing: .newItem) {
                Button(s.newProjectMenuItem) { engine.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }

            // Einträge im vorhandenen Menü „Darstellung" statt eines zweiten „View"-Menüs.
            CommandGroup(before: .toolbar) {
                TooltipToggleItem()
                LanguageToggleItem()
                Divider()
            }

            CommandGroup(after: .help) {
                Divider()
                DiagnosticsMenuItems(diagnostics: engine.rack.diagnostics)
            }

            // App-Menü → Einstellungen … (⌘,)
            CommandGroup(replacing: .appSettings) {
                Button(s.settingsMenuItem) {
                    NotificationCenter.default.post(name: .fofOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // File → Open / Open Recent  (after Neu, before Save — standard macOS order)
            // Note: CommandGroupPlacement has no .openItem member; .after(.newItem) is correct.
            CommandGroup(after: .newItem) {
                Button(s.openPreset) { engine.loadPreset() }
                    .keyboardShortcut("o", modifiers: .command)
                if !engine.recentFiles.isEmpty {
                    Menu(s.openRecent) {
                        ForEach(engine.recentFiles, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                engine.loadPreset(from: url)
                            }
                        }
                        Divider()
                        Button(s.clearRecent) { engine.clearRecentFiles() }
                    }
                }
            }

            // File → Save / Save As  (macOS-standard position: saveItem group)
            CommandGroup(replacing: .saveItem) {
                Button(s.savePresetInPlace) { engine.savePresetInPlace() }
                    .keyboardShortcut("s", modifiers: .command)
                Button(s.saveAsPreset) { engine.savePreset() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Sequencer") {
                Button(engine.isPlaying ? s.stopMenuItem : s.playMenuItem) {
                    engine.isPlaying ? engine.stop() : engine.play()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(s.loopRecordMenuItem) { engine.toggleAudioLoopRecording() }
                    .keyboardShortcut("r", modifiers: [])

                Divider()

                ForEach(0..<9, id: \.self) { i in
                    Button(s.patternMenuItem(Pattern.slotNames[i])) {
                        engine.switchPattern(i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))),
                                      modifiers: .command)
                }
                Menu(s.patternMenuMore) {
                    ForEach(9..<Pattern.slotNames.count, id: \.self) { i in
                        Button(s.patternMenuItem(Pattern.slotNames[i])) { engine.switchPattern(i) }
                    }
                }

                Divider()

                // Eigene Blatt-View je Spur: beobachtet das TrackViewModel, damit die
                // Beschriftung dem Mute-Zustand folgt (engine.objectWillChange feuert bei
                // Mute bewusst nicht).
                ForEach(Array(engine.currentPattern.tracks.enumerated()), id: \.element.id) { i, td in
                    MuteMenuItem(track: engine.viewModel(for: td), number: i + 1)
                }

                Divider()

                Button(s.copyPattern) { engine.copyCurrentPattern() }
                    .keyboardShortcut("c", modifiers: [.command, .option])

                Button(s.pastePattern) { engine.pasteToCurrentPattern() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(engine.clipboard == nil)
            }
        }
    }
}
