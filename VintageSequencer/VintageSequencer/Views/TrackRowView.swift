import SwiftUI
import Combine
import AppKit

// MARK: - TrackRowView

struct TrackRowView: View {
    @ObservedObject var track: TrackViewModel
    /// Spurfarbe, aufgelöst hier — diese View beobachtet das TrackViewModel, also folgt sie
    /// jeder Farbänderung sofort (v1.18.25).
    private var accentColor: Color { VintageTheme.color(for: track.data) }
    var trackIndex:   Int        = 0
    var onRandomize:  (() -> Void)?
    var onClear:      (() -> Void)?
    var onDelete:     (() -> Void)?

    @EnvironmentObject private var engine: SequencerEngine
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage")    private var lang:           String = "en"
    @AppStorage("showTooltips")   private var showTooltips:   Bool   = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }
    @State private var showMultiEdit = false
    // CC-Lane draw mode (nur für kind == .cc).
    // Step-Lane-Purify P1 (v1.10.0): cc1DrawMode/cc2DrawMode entfernt —
    // Step-Lanes haben keine CC-Knob-Reihen mehr.
    @State private var ccLaneDrawMode: Bool = false
    // Grid-Interaktionszustände: Rubber-Band, Step-Drag, Pitch-Drag, Handles, Auto-Scroll.
    // Gebündelt in StepGridCoordinator (E2.3a) als Vorstufe für StepGridView-Extraktion (E2.3b).
    @StateObject private var grid = StepGridCoordinator()

    // MARK: - Layout helpers

    /// Height of the step row — used by TrackHeaderView.
    private var stepRowHeight: CGFloat {
        max(90, CGFloat(engine.stepDisplaySize) + 12)
    }

    // MARK: - Context menu

    // Spurfarbe (Track-Farben-Slice v1.12.1, Palette 16 + Farbrad seit v1.18.25). Schreibweg
    // `ModelCommand.setTrackColor` + `ModelWriter` (Undo). Die Swatches sind farbige
    // Nicht-Vorlagen-Bilder — macOS färbt Menüsymbole sonst einheitlich ein, dann sah man die
    // Farbe nicht (Stephan: „Farbe auswählen geht nicht").
    private let colorMenuWriter = ModelWriter()

    @ViewBuilder
    private var trackColorSubmenu: some View {
        Menu {
            ForEach(Array(VintageTheme.trackColors.enumerated()), id: \.offset) { idx, swatch in
                Button {
                    let td = track.data
                    guard idx != td.colorIndex || td.customColor != nil else { return }
                    colorMenuWriter.apply(
                        .setTrackColor(trackID: td.id, oldIndex: td.colorIndex, oldCustom: td.customColor,
                                       newIndex: idx, newCustom: nil),
                        to: td, undoManager: undoManager)
                } label: {
                    Label {
                        Text(s.colorName(idx + 1))
                    } icon: {
                        Image(nsImage: TrackColorPanel.swatch(NSColor(swatch),
                                                              selected: idx == track.data.colorIndex
                                                                        && track.data.customColor == nil))
                    }
                }
            }
            Divider()
            Button {
                TrackColorPanel.shared.open(for: track.data, undoManager: undoManager, title: s.trackColorWheel)
            } label: {
                Label {
                    Text(s.trackColorWheel)
                } icon: {
                    if track.data.customColor != nil {
                        Image(nsImage: TrackColorPanel.swatch(NSColor(accentColor), selected: true))
                    } else {
                        Image(systemName: "paintpalette")
                    }
                }
            }
        } label: {
            Label(s.trackColorMenu, systemImage: "paintpalette")
        }
    }

    @ViewBuilder
    private var trackContextMenu: some View {
        Menu {
            Button {
                insertTrackBelow(kind: .step)
            } label: {
                Label(s.addStepTrack, systemImage: "square.grid.3x2")
            }
            Button {
                insertTrackBelow(kind: .cc)
            } label: {
                Label(s.addCCTrack, systemImage: "dial.min")
            }
            Button {
                engine.addAudioLoopTrackUndoable(actionName: s.undoAddTrack)
            } label: {
                Label(s.addAudioLoopTrack, systemImage: "waveform.circle")
            }
            .disabled(!engine.rack.canAddChannel)
        } label: {
            Label(s.insertTrackBelow, systemImage: "plus")
        }

        Menu {
            TrackOutputItems(track: track, directory: engine.rack.directory, s: s)
        } label: {
            Label(s.trackOutputMenu, systemImage: "pianokeys")
        }

        if track.lane.kind == .step {
            Toggle(isOn: Binding(
                get: { track.isDrum },
                set: { on in
                    ModelWriter().apply(.setDrumMode(trackID: track.id, old: track.isDrum, new: on),
                                        to: track.data, undoManager: engine.undoManager)
                })) {
                Label(s.drumTrackMenu, systemImage: "circle.grid.2x2")
            }
        }

        Button {
            engine.duplicateTrackUndoable(at: trackIndex, actionName: s.undoDuplicateTrack)
        } label: {
            Label(s.duplicateTrack, systemImage: "plus.square.on.square")
        }

        // Zeile verschieben und einklappen (v1.17.3) — gilt in allen Patterns.
        Button {
            engine.moveTrackUndoable(from: trackIndex, to: trackIndex - 1, actionName: s.undoMoveTrack)
        } label: {
            Label(s.moveTrackUp, systemImage: "arrow.up")
        }
        .disabled(trackIndex == 0)
        Button {
            engine.moveTrackUndoable(from: trackIndex, to: trackIndex + 1, actionName: s.undoMoveTrack)
        } label: {
            Label(s.moveTrackDown, systemImage: "arrow.down")
        }
        .disabled(trackIndex >= engine.currentPattern.tracks.count - 1)
        Button {
            let c = track.data.isCollapsed
            engine.setTrackCollapsedUndoable(at: trackIndex, !c, actionName: c ? s.expandTrack : s.collapseTrack)
        } label: {
            Label(track.data.isCollapsed ? s.expandTrack : s.collapseTrack,
                  systemImage: track.data.isCollapsed ? "chevron.down" : "chevron.right")
        }

        Divider()

        trackColorSubmenu

        Divider()

        Button(role: .destructive) {
            engine.removeTrackUndoable(at: trackIndex, actionName: s.undoDeleteTrack)
        } label: {
            Label(s.deleteTrack, systemImage: "trash")
        }
        .disabled(engine.currentPattern.tracks.count <= 1)
    }

    private func insertTrackBelow(kind: LaneKind) {
        engine.insertTrackUndoable(after: trackIndex, kind: kind, actionName: s.undoInsertTrack)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if track.data.isCollapsed {
                // Eingeklappt (v1.17.3): schmale Leiste, die Spur spielt weiter.
                CollapsedTrackRow(track: track, accentColor: accentColor,
                                  trackIndex: trackIndex) { trackContextMenu }
            } else if track.data.isAudioLoop {
                // Audio-Loop-Spur (v1.15.0): eigener Kopf und Wellenform statt Steps.
                AudioLoopRowView(track: track, rack: engine.rack, accentColor: accentColor,
                                 height: stepRowHeight,
                                 edge: { rowEdge }) { trackContextMenu }
            } else {
                stepRow
            }
        }

    }

    private var rowEdge: TrackRowEdge {
        TrackRowEdge(trackID: track.id, trackIndex: trackIndex, collapsed: false,
                     accentColor: accentColor, s: s, tip: tip)
    }

    @ViewBuilder
    private var stepRow: some View {
        #if DEBUG
        let _ = BodyRunCounter.shared.count("TrackRow")
        #endif
        HStack(spacing: 0) {

            // ── LEFT: fixed column — kind-dispatched via TrackSideHeaderView.
            TrackSideHeaderView(
                track:            track,
                accentColor:      accentColor,
                stepRowHeight:    stepRowHeight,
                ccLaneDrawMode:   $ccLaneDrawMode,
                onRandomize:      onRandomize,
                onClear:          onClear,
                onDelete:         onDelete,
                headerContextMenu: { AnyView(trackContextMenu) }
            )
            .frame(width: VintageTheme.trackHeaderWidth)
            // Klick in den Spurkopf hebt im Mixer den Kanal hervor, den die Spur spielt.
            .simultaneousGesture(TapGesture().onEnded {
                engine.rack.highlightedChannel = track.instrumentID.flatMap { engine.rack.channel($0)?.id }
            })

            // Thin separator — Amber-Farbe übernommen aus ehem. BPMGridView-Null-Linie.
            // BPMGridView wurde als globales Overlay entfernt (Pinch-Zoom-Fix);
            // dieser Layout-Separator ist jetzt die einzige Grenzlinie Header ↔ Step-Bereich.
            Rectangle()
                .fill(Color(red: 0.55, green: 0.42, blue: 0.20).opacity(0.55))
                .frame(width: 1)

            // ── RIGHT: step grid VStack — ruhige, versenkte Rasterfläche (GUI-01) ──
            VStack(spacing: 0) {

                // Selection action bar + Escape handler — extracted to StepSelectionToolbar (E2).
                StepSelectionToolbar(
                    selectedSteps: $grid.selectedSteps,
                    isSelecting:   grid.rubberAnchorContentX != nil,
                    showMultiEdit: $showMultiEdit,
                    track: track,
                    accentColor: accentColor
                )

                // ── Lane body — lane-kind-dispatched via LaneBodyView (Lane Slice 4) ──
                // Track-Rahmen bleibt kind-neutral; der konkrete Body-View wird in
                // LaneBodyView per `switch track.lane.kind` ausgewählt. Für den heute
                // einzigen Case (`.step`) ist das StepGridView.
                LaneBodyView(
                    track:          track,
                    grid:           grid,
                    accentColor:    accentColor,
                    trackIndex:     trackIndex,
                    ccLaneDrawMode: $ccLaneDrawMode
                )
            }
            .background(GridWellSurface())
            .sheet(isPresented: $showMultiEdit) {
                MultiStepEditView(track: track,
                                  indices: Array(grid.selectedSteps).sorted(),
                                  accentColor: accentColor)
                    .environmentObject(engine)
                    .onDisappear { grid.selectedSteps = [] }
            }

            // Rechter Rand (v1.17.3): Einklappen und Ziehgriff, gleiche Breite für alle Arten.
            rowEdge
        }
        // GUI-01: gleicher Modulrahmen für Step- und CC-Spuren — gebürstetes dunkles Metall.
        .background(MetalSurface(tone: .darkMetal))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
        )
        // Arch-Slice-3: .onChange(of: engine.activeSelectionTrack) entfernt.
        // Das Löschen der Selektion auf nicht-aktiven Tracks übernimmt jetzt
        // StepGridCoordinator.connectInteractionController via Combine:
        // Wenn IC einen RubberBandUpdate für eine andere Track-ID publiziert,
        // löscht der Koordinator selbstständig seine selectedSteps.
        // engine.activeSelectionTrack ist ebenfalls entfernt (SequencerEngine).
    }
}

// EdgeAutoScroller   — extracted to EdgeAutoScroller.swift   (E2.4)
// CornerDotHandle    — extracted to CornerDotHandle.swift    (E2.4)
// HandleNSView       — extracted to CornerDotHandle.swift    (E2.4)
