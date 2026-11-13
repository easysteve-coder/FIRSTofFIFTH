import SwiftUI
import Combine
import AppKit

// MARK: - TrackRowView

struct TrackRowView: View {
    @ObservedObject var track: TrackViewModel
    var accentColor:  Color      = VintageTheme.amber
    var trackIndex:   Int        = 0
    var onRandomize:  (() -> Void)?
    var onClear:      (() -> Void)?
    var onDelete:     (() -> Void)?
    var onDuplicate:  (() -> Void)?

    @EnvironmentObject private var engine: SequencerEngine
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage")    private var lang:           String = "en"
    private var s: Str { Str(lang) }
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

    // Track-Farben-Slice v1.12.1: Farbwahl wandert vom Header-Farbpunkt
    // ins Track-Kontextmenü. Der Farbpunkt im Header bleibt reine Anzeige.
    // Kein neues Modell/Command — Auswahl geht weiterhin über
    // `ModelCommand.setTrackColorIndex` + `ModelWriter` (Undo aktiv).
    // Farbauflösung bleibt einziger Resolver-Ort `VintageTheme.color(forTrack:)`;
    // die Swatches hier sind reine visuelle Palettenvorschau und berühren
    // die Architekturregel „ein Resolver" nicht.
    private let colorMenuWriter = ModelWriter()

    @ViewBuilder
    private var trackColorSubmenu: some View {
        Menu {
            ForEach(Array(VintageTheme.trackColors.enumerated()), id: \.offset) { idx, swatch in
                Button {
                    let old = track.data.colorIndex
                    guard idx != old else { return }
                    colorMenuWriter.apply(
                        .setTrackColorIndex(trackID: track.id, old: old, new: idx),
                        to: track.data,
                        undoManager: undoManager
                    )
                } label: {
                    Label {
                        Text(s.colorName(idx + 1))
                    } icon: {
                        if idx == track.data.colorIndex {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "circle.fill").foregroundColor(swatch)
                        }
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
                onDuplicate:      onDuplicate,
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

            // Step-Lane-Purify P1 (v1.10.0): Expand/Collapse-Chevron entfernt.
            // Step-Lanes haben kein CC-Panel mehr, daher nichts zum Expanden.
            // Einheitlicher Platzhalter für beide Lane-Typen, damit die rechte
            // Spurbreite konsistent bleibt.
            Spacer().frame(width: 40)
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
