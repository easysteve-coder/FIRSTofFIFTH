import AppKit
import UniformTypeIdentifiers

/// Dialoge für den Apple Sampler (v1.18.16): Instrumentdatei wählen, Sample-Ordner freigeben.
@MainActor
enum SamplerPanels {
    private static let lastFolderKey = "samplerLastFolder"

    /// Instrument wählen und laden. Liegt es in keinem freigegebenen Ordner, wird erst ein
    /// Ordner freigegeben; fehlen danach Samples, kann ein weiterer freigegeben werden.
    static func chooseAndLoad(channel id: UUID, rack: InstrumentRack, s: Str) {
        let panel = NSOpenPanel()
        panel.title = s.samplerChoose
        panel.message = s.samplerChoose
        panel.allowedContentTypes = AppleSampler.fileTypes.keys.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if let last = UserDefaults.standard.string(forKey: lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastFolderKey)
        // SoundFont/DLS tragen ihre Samples in sich: die Dateiwahl genügt. EXS/aupreset verweisen
        // auf Samples daneben — dafür einen Ordner freigeben.
        let selfContained = ["sf2", "dls"].contains(url.pathExtension.lowercased())
        if !selfContained, !SampleFolders.shared.covers(url), !grantFolder(suggesting: url, s: s) { return }
        load(url, channel: id, rack: rack, s: s, retry: true)
    }

    private static func load(_ url: URL, channel id: UUID, rack: InstrumentRack, s: Str, retry: Bool) {
        rack.loadSamplerInstrument(url, for: id) { failure in
            guard let failure else {
                rack.openInstrumentEditorWhenLoaded(id)
                return
            }
            switch failure {
            case .missingSamples(let found, let missing):
                if retry, ask(s.samplerMissing(found: found, missing: missing), s: s, action: s.samplerGrantFolders),
                   grantFolder(suggesting: url, s: s) {
                    load(url, channel: id, rack: rack, s: s, retry: false)
                } else if !retry {
                    _ = ask(s.samplerMissing(found: found, missing: missing), s: s, action: nil)
                }
            case .unsupported: _ = ask(s.samplerUnsupported, s: s, action: nil)
            case .unavailable: _ = ask(s.samplerFailed(-1), s: s, action: nil)
            case .loadFailed(let st): _ = ask(s.samplerFailed(st), s: s, action: nil)
            }
        }
    }

    /// Ordnerwahl; Vorschlag: der Musik-Ordner über der Datei, sonst zwei Ebenen darüber.
    @discardableResult
    static func grantFolder(suggesting url: URL?, s: Str) -> Bool {
        let panel = NSOpenPanel()
        panel.title = s.samplerGrantFolders
        panel.message = s.samplerGrantMessage
        panel.prompt = s.samplerGrant
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let url { panel.directoryURL = suggestion(for: url) }
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        return SampleFolders.shared.add(folder)
    }

    static func suggestion(for url: URL) -> URL {
        var u = url.deletingLastPathComponent()
        while u.pathComponents.count > 2 {
            if u.lastPathComponent == "Music" { return u }
            u = u.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Hinweis mit optionaler Aktion; true, wenn die Aktion gewählt wurde.
    private static func ask(_ text: String, s: Str, action: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = s.samplerErrorTitle
        alert.informativeText = text
        if let action { alert.addButton(withTitle: action); alert.addButton(withTitle: s.samplerCancel) }
        else { alert.addButton(withTitle: s.ok) }
        return alert.runModal() == .alertFirstButtonReturn && action != nil
    }
}
