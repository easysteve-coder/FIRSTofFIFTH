# Gebürstetes Studiogerät — Gestaltungsmuster für FoF und Planarium

Stand: 20. Oktober 2026 · Musterfassung 1

## Zweck und Verbindlichkeit

Stephan möchte die in FoF entwickelte grafische Richtung so festhalten,
dass das Planarium-Team sie als Muster verwenden kann. Dieses Dokument
beschreibt die übertragbare Gestaltung und ihre Qualitätskriterien.
Es beauftragt keinen Umbau von Planarium und keine heutige Installation.

**Bestätigte Richtung:** gepflegtes, leicht gealtertes Studiogerät mit
gebürstetem Metall, satiniertem Aluminium, plastischen Kunststofftastern,
versenkten Anzeigen und geriffelten Fadergriffen/Drehknöpfen. Beleuchtung
links oben; ruhige Arbeitsflächen, gezielte Akzente.

**Stand der Umsetzung:** Materialpilot FoF v1.12.13, `f0af3bd`.
Transportkorrektur GUI-01-R1, Round `FOF-CX-2026-10-20-004`, geliefert in
`548159c` / v1.12.14; Transportausschnitt bei 920 pt vom Supervisor angesehen.
Live-/Keyboard-/VoiceOver-Prüfung weiterhin offen.
GUI-/Handling-Review `FOF-RV-2026-10-20-001` abgeschlossen (Code/Bilder);
mehrere offene Korrekturen, siehe [Roadmap](../VintageSequencer/ROADMAP.md). Sichtbare Pilotausschnitte
sind Anschauungsmaterial, kein Nachweis einer insgesamt abgenommenen GUI.
Nachfolgekorrekturen ändern nicht automatisch diese Materialrichtung.

## 1. Aufbau der Oberflächen

| Ebene | Material und Rolle | Gestaltung |
|---|---|---|
| Gehäuse / Modulrahmen | Gebürstetes Anthrazitmetall | Feine horizontale Bürstung, schmale helle Oberkante, dunkle Unterkante; sparsame Schatten. |
| Zusammengehörige Parametergruppe | Warmes, satiniertes Aluminium | Dunkle Schrift und Skalen; gleichartige benachbarte Platten mit gleicher Außenhöhe und gemeinsamen Fluchten. |
| Arbeitsbereich / Raster / Kurven | Ruhige, dunkle Einlassung | Wenig Textur, keine auffällige Bürstung hinter dichtem Inhalt; dezente obere Schattenkante. |
| Wert- oder Namensanzeige | Dunkles, versenktes Glas | Klarer Inhalt, feine Einlassungskante; keine Reflexion über Ziffern. |
| Taster | Leicht gewölbter Kunststoff | Licht oben links, Schatten unten rechts; gedrückt mit erkennbar veränderter Tiefe. Für **dichte Taster-Raster** (viele gleiche Tasten nebeneinander) gilt stattdessen die gleichmäßige, dezente Beleuchtung unten. |
| Fader / Drehknopf | Greifbarer Kunststoff-/Metallaufbau | Klare Kontur, Riffelung, dunkler Mittelindex bzw. gut sichtbarer Zeiger. |

Die Materialien haben eine Funktion. Nicht jede Fläche wird Aluminium,
nicht jedes Feld Glas. Die Arbeit mit Noten, Kurven oder räumlichen Daten
steht optisch vor der Dekoration. Beleuchtung bleibt für alle Bausteine
konsistent; keine gegensätzlichen Glanzrichtungen innerhalb eines Moduls.

## 2. Farbvorlage und semantische Tokens

Referenz sind die tatsächlichen FoF-Werte aus
[VintageMaterials.swift](../VintageSequencer/VintageSequencer/Theme/VintageMaterials.swift)
und [VintageTheme.swift](../VintageSequencer/VintageSequencer/Theme/VintageTheme.swift).
RGB-Komponenten unten sind normierte Quellwerte von 0 bis 1, keine
verbindliche Farbkalibrierung für jedes Display.

| Token / Rolle | RGB oben bzw. Grundfarbe | RGB unten |
|---|---|---|
| `darkMetal` | (0.20, 0.20, 0.215) | (0.12, 0.12, 0.13) |
| `lightAluminium` mit Patina | (0.79, 0.775, 0.74) | (0.62, 0.605, 0.575) |
| `gridWell` | (0.085, 0.085, 0.095) | (0.115, 0.115, 0.125) |
| `displayGlass` | (0.035, 0.035, 0.04) | — |
| `plasticKey` | (0.26, 0.26, 0.28) | (0.15, 0.15, 0.165) |
| `inkOnLight` | (0.07, 0.07, 0.08) | — |
| `inkOnLightSecondary` | (0.17, 0.17, 0.18) | — |
| FoF-Primärtext auf dunkel | (0.85, 0.80, 0.68) | — |
| FoF-Amber | (1.00, 0.55, 0.00) | — |
| FoF-Amber hell | (1.00, 0.80, 0.20) | — |
| FoF-Amber-Text | (1.00, 0.65, 0.10) | — |

Planarium kann seine vorhandenen Funktions-/Zonenfarben behalten. Übertragen
werden Material und Bedeutung der Tokens; FoF-Trackfarben sind keine neue
Planarium-Datenstruktur. Gleiche Funktion erhält innerhalb einer App dieselbe
Farbrolle. Farbige Schrift auf hellem Aluminium nur nach Kontrastprüfung;
bei kritischen Akzentfarben lieber dunkles Namensglas verwenden.

FoF nutzt Amber/Blau/Grün/Magenta/Gelb/Violett/Rot/Cyan als Trackpalette.
Sie ist eine optionale Referenz, kein vollständiges Statussystem.
Fehler, Auswahl und Fokus dürfen nicht allein von einer Farbe abhängen.
Schwache Sekundärtexte des Piloten sind vor Übernahme zu prüfen; die
Quellpalette ist kein pauschaler Accessibility-Nachweis.

## 3. Dezente Alterung

Das Gerät wirkt gebraucht und gepflegt. Aluminium ist leicht wärmer und
nachgedunkelt; feine horizontale Spuren liegen in der Bürstungsrichtung.
Anthrazit erhält wenige weiche Mattstellen. Exponierte Griff-/Tasterkanten
können leicht poliert erscheinen. Die Grundmaterialien bleiben erkennbar.

Keine ausgebleichten Zahlen, verschmutzten Skalen oder Kratzer quer durch
wichtige Anzeigen. Keine großen Risse, Rostflächen oder zufälligen Flecken.
Patina bleibt bei 100 Prozent Betrachtung subtil und beeinträchtigt weder
Beschriftung noch LED-/Fokus-/Auswahlkontrast.

Technische Referenz: einmal erzeugte, deterministische Textur-Tiles;
FoF nutzt 256 × 128 Pixel bei scale 2, also 128 × 64 pt. Wenige feine
Gebrauchsspuren und ortsfeste weiche Mattstellen. Diese Zahlen beschreiben
den Pilot, keine Pflicht zur identischen Textur. Keine Neuberechnung oder
Zufallserzeugung pro Render-/Playback-Update; Dekor erhält keine eigenen
Timer oder modellweiten Beobachtungen.

## 4. Bedienelemente

### Fader

Griff mit zwei Riffelzonen und klarer dunkler Mittellinie. Führungsschlitz,
Skala und Griff bilden eine Einheit; Min/Mitte/Max beziehen sich auf die
Griffmitte. Endstellungen bleiben im vorgesehenen Bewegungsraum.

Vorbild aus Planarium/Sick: `LogicFaderCap` und `LogicVerticalFader` in
[HelmutChannelSurface.swift](../../Sick/Sources/SickPLSMonitor/HelmutChannelSurface.swift).
FoF interpretiert den vertikalen 17 × 35-pt-Griff horizontal als 35 × 17 pt.
Sichtbare Griffgröße und Trefferfläche sind getrennte Größen; der Pilot
hat 30 pt Trefferhöhe. Das ist kein allgemeiner Mindestgrößennachweis.

**Nur die Optik portieren.** Parameterkennlinie, Einheiten, Grenzen,
Feinmodus, Reset, Undo und Modellübergabe gehören der Zielanwendung.
FoF-WIDTH bleibt linear 30…120, Planariums dB-Fader behält seine FaderLaw.
Keine FoF-Draglogik ungeprüft in Planarium übernehmen. Kein Wertsprung beim
Greifen, kein Wertwechsel allein durch Resize; Tastatur, Fokus und
Accessibility-Wert gehören zum Abnahmekriterium.

### Drehknöpfe

Dunkler Körper mit geriffeltem Rand, kleiner gerichteter Kappenreflex und
kontrastreicher Zeiger. Skalenbogen macht Bereich/Stellung erkennbar.
Gleiche Funktion hat gleiche Form. Unterschiedliche Knopfgrößen sind möglich,
zusammengehörige Aluminiumplatten behalten trotzdem gemeinsame Außenhöhen.

Beschriftung und Wert haben eine eindeutige Hierarchie. Steht der Wert schon
in einem benachbarten Display, wird er nicht nochmals unter dem Knopf
wiederholt. FoF-Korrektur: BPM bleibt als Label, Tempo nur im vorhandenen
Anzeigeglas; SWING bleibt als Label ohne zusätzliche Zahl darunter.
Der Parameterwert bleibt über Accessibility verfügbar.

Der bestehende FoF-Reset auf die Bereichsmitte ist keine allgemeine
Designvorgabe; fachlich richtiger Neutral-/Unity-/Defaultwert kommt aus der
Zielanwendung. Musikalische Gate-Labels sind weiterhin Wertinformation.

### Taster und Zustände

| Zustand | Sichtbares Signal |
|---|---|
| Normal / verfügbar | Kunststoffkontur, lesbare Beschriftung. |
| Gedrückt | Eingelassene Tiefenwirkung; Rückmeldung sofort. |
| Aktiv | Definierter Akzent und gedrückte Stellung bzw. klarer Zustandsindikator. |
| Ausgewählt | Eigene Kontur/Markierung, unabhängig von Aktivität. |
| MIDI-Learn-Ziel | Eindeutige zusätzliche Markierung, unterscheidbar von Auswahl. |
| Playback / aktuelles Ereignis | Lokale LED oder kleiner Indikator; keine vollflächig pulsierenden Module. |
| Tastaturfokus | Eigenständige sichtbare Fokusmarkierung. |
| Deaktiviert / Fehler | Status erkennbar, Text lesbar; Fehler nicht hinter Materialeffekten verstecken. |

#### Dichte Taster-Raster: dezente, gleichmäßige Kunststoffbeleuchtung

Wiederholte Tasten (FoF-Steps) dürfen nicht jede für sich einen dramatischen Licht-/Schattenverlauf tragen. Bei vielen Tasten
nebeneinander addiert sich der Effekt zu einem Muster, die rechte Seite jeder Taste wirkt „abgesoffen“ und das Raster unruhig
(Anlass: Stephan, 20.10.2026, „Verlauf von Highlight und Schatten bei den Steps zu heftig, nach rechts zu dunkel“). Muster:

- Körper aus weitgehend gleichmäßigem, mattem Kunststoff: sehr enger Helligkeitsbereich oben→unten (wenige Prozent), **kein**
  Verlauf über die Breite und keine Eck-zu-Eck-Diagonale.
- Plastizität nur über eine dezente obere Lichtkante und eine schmale, weiche Unterkante (1-px-Kontur, Neigung höchstens leicht
  von links oben); keine harte Glanzkante.
- Zustands-Tönung (Track-/Akzentfarbe) gleichmäßig über die Fläche (Abfall oben→unten ≈ 20 %, nicht ≈ 65 %), Beschriftung und
  Zustandsmarken (Auswahl, Learn, Playback-LED) bleiben kontrastreich und getrennt.
- Das Standard-Tasterprofil (einzelne Buttons, Play, Pattern) darf stärker plastisch bleiben; die dezente Variante ist ein
  eigenes Profil, kein pauschales Abflachen aller Controls.
- Referenz: `GUI_REFERENCES/GUI-02/` (vorher/nachher, WIDTH 30/54/120; `detail-w120-amber-before-over-after.png`).

Die Tabelle ist der Gestaltungssollzustand. Der aktuelle Pilot beweist noch
nicht alle Fokus-/Deaktiviert-/Accessibility-Zustände. Vor Übernahme prüfen.

## 5. Typografie, Layout und Handling

Monospaced-Schrift passt zu Parametern und Anzeigen; Ziffern stehen bei
Wertänderung ruhig. Referenzgrößen im FoF-Code: 9/11/14/17 pt. Diese kleinen
Bestandsgrößen sind keine verbindliche Planarium-Vorgabe: Lesbarkeit auf
dem tatsächlichen iMac/Display bei 100 Prozent bestimmt die Zielgröße.

- Produktname vollständig und lesbar; keine Ellipse oder Umbrüche im Logo.
- Gleichartige Module auf gemeinsame Kanten und Höhen ausrichten.
- Arbeitsfläche und feste Randbedienung besitzen getrennte Layout- und
  Trefferbereiche. Scrollender Inhalt darf feste Griffe/Werte nicht übermalen.
- Wesentliche Aktionen bleiben bei Mindestbreite sichtbar. Textumbruch und
  Verkleinerung nicht als stiller Ersatz für ein brauchbares Layout verwenden.
- Sichtbare Griffgestaltung erklärt Funktion und Richtung. Unsichtbare oder
  winzige Trefferflächen sind keine Folge des gewünschten Hardware-Looks.
- Drag, Abbruch, Undo und Auswahl benötigen eigene Interaktionsverträge.
  Materialänderungen ändern keine Kennlinien, Koordinaten oder Commands.

**Nicht als Muster übernehmen:** die aktuelle Überlappung von Steps/CCs
mit der rechten Ratio-/Stepzahl-Zone, kleine wenig erkennbare Corner-Handles,
offene Escape-/Session-/Rubberband-Fragen und verdeckende Debug-Overlays.
Diese Punkte sind als GR-01 bis GR-15 im Revisorbericht und in der
[Roadmap](../VintageSequencer/ROADMAP.md) erfasst, keine gewollte Gestaltung. Die Transportkorrektur ist bildlich geprüft; ihre Live-Bedienung bleibt
separat zu verifizieren.

## 6. Technische Übernahme in Planarium

1. Planarium übernimmt diesen Material-/Zustandsvertrag in seine eigene
   aktive Design-Dokumentation und ordnet die Rollen seinen Modulen zu.
2. Material- und Shape-Bausteine aus der FoF-Implementierung lesen; kleine,
   zustandsarme Darstellungsbausteine bei Bedarf anpassen. Keine gegenseitige
   Produktabhängigkeit und keine Engine-/Domain-/Command-Übernahme.
3. Bestehende Planarium-Fader, Parameterbereiche, Fokus-/Tastaturwege,
   Accessibility, Undo und kontrollierte Modellübergabe erhalten.
4. Planariums macOS-12-Ziel und Intel/Apple-Silicon-Pfad berücksichtigen;
   neuere APIs nur mit geprüfter kompatibler Alternative verwenden.
5. Erst ein repräsentatives Modul mit realem Inhalt umsetzen und am iMac
   beurteilen; danach dieselben Materialrollen konsistent weiterverwenden.

Für neue Texturen/Shapes eigene Assets erzeugen. Der Re-Rebirth-Screenshot
ist ausschließlich Anschauungsmaterial; weder ausgeschnittene Texturen,
Logos, Webcode noch andere Fremdassets als Produktbestandteil übernehmen.
Die bestehende Sick-/FoF-Referenzbeziehung ist in
[GUI_REFERENCES/README.md](GUI_REFERENCES/README.md) dokumentiert.

## 7. Bildnachweise und Abnahme für eine Übernahme

Materialbeispiele (FoF-Pilot, echte App-Views offscreen gerendert):

![Korrigierter FoF-Transport bei 920 pt: gleiche Plattenhöhe, vollständiger Name, keine Zusatzzahlen](GUI_REFERENCES/GUI-01-R1/after-main-de-min-w120-transport.png)

![Dezente Patina im Vergleich; oben ohne, unten mit Alterung](GUI_REFERENCES/GUI-01/patina-100pct-track.png)

Weitere Detailbilder und Vorher-/Nachhervergleiche:
[Referenzindex](GUI_REFERENCES/README.md). Das Transportbild zeigt v1.12.14; Patina-Details stammen aus dem Materialpilot
v1.12.13. Achtung GT-01: Im mit DE konfigurierten Transportbild sind die
Transporttexte weiterhin englisch/hart codiert. Dieses Bild belegt Material
und Geometrie, keine abgeschlossene Lokalisierung. Sie ist vor Übernahme
in die Zielanwendung zu prüfen. Die Bilder ersetzen keinen Live-Test.

Für Planarium vor/nach der Änderung dieselbe Szene aufnehmen: Gesamtfenster,
repräsentatives Modul und Details bei 100 Prozent; kleine und breite Fenster,
DE/EN, lange Texte, Minimal-/Maximalwerte, heller/dunkler Untergrund,
Normal/Aktiv/Auswahl/Learn/Fokus/Fehler. Reale Skalen und Einheiten verwenden.

Fader/Knobs per Maus und Tastatur bedienen, Accessibility-Werte prüfen,
Fenster während Interaktion skalieren, Abbruch und Undo/Redo kontrollieren.
Die reale Eingabe-/Audio-/MIDI-Last bleibt flüssig; statische Texturen und
zusätzliche Effekte dürfen keine globalen Invalidierungen erzeugen.

Offscreen-Bilder, Codeprüfung, automatisierte Checks und echter iMac-Lauf
werden im Rücklauf getrennt benannt. Erst der Zielprojekt-Review entscheidet,
welche Zustände und Workflows tatsächlich abgenommen sind. Dieses Muster
ist keine Timing-, Stabilitäts- oder Release-Freigabe für FoF oder Planarium.
