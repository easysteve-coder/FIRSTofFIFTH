import SwiftUI

// MARK: - TrackMuteSoloButtons (v1.15.2, Codex N2)
//
// Mute/Solo einer Spur — derselbe Baustein für Step-, CC- und Audio-Loop-Köpfe: dieselbe
// Aktion über den ModelWriter, dieselbe Optik, dieselben Hilfetexte.

struct TrackMuteSoloButtons: View {
    @ObservedObject var track: TrackViewModel
    let s: Str
    let tip: (String) -> String
    private let writer = ModelWriter()

    var body: some View {
        Button(track.isMuted ? "M" : "m") {
            writer.apply(.setMuted(trackID: track.id, old: track.isMuted, new: !track.isMuted),
                         to: track.data, undoManager: nil)
        }
        .buttonStyle(VintageSmallButtonStyle(isActive: track.isMuted, accent: .orange))
        .help(tip(track.isMuted ? s.mutedTooltip : s.muteTooltip))
        .accessibilityLabel(s.muteTooltip)

        Button(track.isSolo ? "S" : "s") {
            writer.apply(.setSolo(trackID: track.id, old: track.isSolo, new: !track.isSolo),
                         to: track.data, undoManager: nil)
        }
        .buttonStyle(VintageSmallButtonStyle(isActive: track.isSolo,
                                             accent: Color(red: 0.9, green: 0.9, blue: 0.1)))
        .help(tip(track.isSolo ? s.soloActiveTooltip : s.soloTooltip))
        .accessibilityLabel(s.soloTooltip)
    }
}
