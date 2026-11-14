# Changelog

Alle nennenswerten Änderungen am Projekt, gegliedert nach Versionen.
Format: [Semantische Versionierung](https://semver.org/lang/de/)

---

## [1.14.0] — 2026-11-14

### Song-Lane und 16 Patterns

**Neu**
- **Song-Lane** über den Spuren: Szenen aneinanderreihen, je Szene ein Pattern und eine Länge
  in Takten (1–64). Klick auf eine Szene wählt Pattern und Länge, Rechtsklick dupliziert,
  verschiebt oder löscht; alles mit Undo. Die laufende Szene leuchtet.
- **Song-Modus** (ON/OFF): Play beginnt mit der ersten Szene; die Patterns wechseln exakt auf
  dem Taktstrich, unabhängig von der Länge von Track 1. Folgen zwei Szenen mit demselben
  Pattern, läuft es ohne Neustart durch. **LOOP/ENDE** je Song: am Ende von vorn oder anhalten.
- **16 Patterns (A–P)** statt 4; in der Transportleiste in zwei Reihen. ⌘1 … ⌘9 wählen A … I,
  J … P stehen im Menü *Sequencer*.

**Geändert**
- Pattern-Wechsel per CC in Achterschritten: 0–7 = A, 8–15 = B … 120–127 = P (bisher 0–31 = A
  … 96–127 = D). Wer A–D über einen Controller umschaltet, muss die Werte anpassen.
- Während der Song läuft, sind die Pattern-Tasten ohne Wirkung — die Szenen bestimmen das
  Pattern.

**Presetformat:** neuer optionaler Schlüssel `song`; Dateien enthalten jetzt 16 Patterns.
Ältere Versionen laden sie, ignorieren den Song und zeigen nur A–D.

---

## [1.13.19] — 2026-11-14

### Pad-Spuren: eigene Breite, eigene Optik

**Neu**
- Pad-Spuren haben eine eigene Rasterbreite: ↔-Taste im Spurkopf, 1 bis 8 Step-Breiten je
  Pad-Step, mit Undo. Die Breite ist nur Anzeige — die Steplänge bleibt, wie sie ist. Neue
  Pad-Spuren starten mit doppelter Breite.
- Pad-Spuren sehen anders aus als Step-Spuren: PAD-Schild im Spurkopf, Pad-Steps mit Verlauf
  in Spurfarbe nach rechts (der Klang hält an) und farbiger Kontur.

**Presetformat:** neuer optionaler Schlüssel `padWidth` (nur bei Pad-Spuren mit Breite ≠ 1).
Ältere Versionen ignorieren ihn.

---

## [1.13.18] — 2026-11-14

### Pad-Länge ziehen mit Anzeige

**Behoben**
- Pad-Tracks: Die Steplänge ließ sich am oberen Anfasser (Punkt) nicht ziehen — der Ziehweg
  war in echter Dauer gerechnet und für 1 → 2 Takte unerreichbar lang. Jetzt wechselt je
  Step-Breite Ziehweg eine Längenstufe (1/4 … 8 Takte).

**Neu**
- Jeder Pad-Step zeigt seine Länge („2 T“) oben rechts; sie folgt dem Ziehen live. Beim Ziehen
  am Anfasser erscheint die Länge zusätzlich groß am Anfasser.

---

## [1.13.17] — 2026-11-14

### Spurkopf: ganze Tasten klickbar, Rechtsklick überall

**Behoben**
- Tasten im Spurkopf reagierten nur auf ihre Beschriftung. Jetzt nimmt die ganze Taste Klicks an.
- Rechtsklick öffnete das Spurmenü nur auf Tasten. Jetzt öffnet es sich auf jeder Stelle des
  Spurkopfs, auch auf freien Flächen; ebenso bei CC-Spuren.
- Beim Laden mancher Instrumente (z. B. UADx Opal, Odin 2) fragte macOS, ob die
  Sicherheitseinstellungen für FIRSTofFIFTH gesenkt werden sollen. Ursache: FoF läuft in der
  App-Sandbox, und diese Plug-ins erklären sich nicht als sandbox-tauglich. FoF trägt jetzt das
  dafür vorgesehene Recht für Plug-in-Hosts (`temporary-exception.audio-unit-host`).

**Geändert**
- Pad-Tracks: RND würfelt sofort; die Akkordquelle wählt die kleine Taste ▾ daneben (vorher
  RND gedrückt halten).

---

## [1.13.16] — 2026-11-14

### Pad-Tracks für Flächen und Drones, Akkorde würfeln, Halten, ein Ton pro Spur

**Neu**
- **Pad-Track** („Pad-Track hinzufügen“ im Plus-Menü und im Spur-Kontextmenü): Steps von einer
  Viertel bis zu 8 Takten (1/4, 1/2, 3/4, 1, 2, 3, 4, 8 Takte), legato, für Pads, Drones und
  sphärische Klänge. Polyrhythmus bleibt möglich, z. B. 3 Steps à 3 Takte gegen 4 Takte. Die
  Steps stehen kompakt im Raster; ein Balken zeigt, wie weit der laufende Step ist. Neuer
  Pad-Track: 4 Steps à 1 Takt.
- **Akkorde würfeln:** RND auf einem Pad-Track würfelt Akkorde in der Tonart des Tracks (SCL-Grundton),
  mit Bass und weicher Stimmführung. Gedrückt halten öffnet die Auswahl: zufällige Folge aus
  den Büchern von Lizzio („Chord Progression Codex“) und Callipari („Illustrierte Harmonie“),
  eine bestimmte Folge (u. a. Pop-Netz, Andalusisch, Episch, Götterakkorde, Spuk, Line-Klischee,
  Quintfall, Neapolitaner, Hexatonik, Zwölftakt-Blues; Quelle mit Seitenangabe im Tooltip)
  oder leitereigene Akkorde aus der Skala des Tracks.
- **Halten** (Edit-Card eines Steps): Der Step schlägt nichts an, sondern verlängert den Ton
  des vorherigen Steps um seine Länge. So klingt ein Akkord z. B. zwei Steps lang und der
  nächste nur einen. Gilt auf allen Step-Tracks.
- **Ein Ton** (Edit-Card): Alle Steps der Spur spielen denselben Ton, z. B. eine Kick. Die
  Tonwahl in der Karte gilt dann für die ganze Spur; die eigenen Noten der Steps bleiben
  erhalten und kommen beim Ausschalten zurück.

**Presetformat:** drei neue optionale Schlüssel (`pad`, `hold`, `fixedNote`). Ältere Versionen
laden solche Dateien, spielen Pad-Tracks aber als normale Spur mit langen Steps, Halte-Steps
mit ihren eigenen Noten und ohne festen Ton.

---

## [1.13.15] — 2026-11-13

### Neues App-Icon

**Geändert**
- **App-Icon:** zeigt jetzt den Sequencer selbst – drei Spuren aus Step-Tasten in Bernstein, Blau und Magenta mit
  4, 5 und 3 Steps auf derselben Breite; die erste Taste jeder Spur leuchtet. Erzeugt von
  `VintageSequencer/Tools/make_app_icon.swift`.

---

## [1.13.14] — 2026-11-12

### Audio-Diagnose zum Aufzeichnen im Betrieb, Wächter überarbeitet, Step-Anzeige schmaler

**Neu**
- **Audio-Diagnose** (Menü „Hilfe"): „Audio-Diagnose aufzeichnen" schreibt viermal je Sekunde Messwerte und jedes
  Ereignis des Audiowegs in eine Datei – Pegel jedes Kanals und der Summe als Rohwerte (auch weit über Vollaussteuerung),
  Gleichanteil, ungültige Werte, Lebenszeichen der Engine und jedes Instruments, Zustand des Ausgabegeräts (läuft,
  stumm, Lautstärke, Abtastrate), Laden, Neuaufbau, Gerätewechsel, Presetwechsel im Plug-in, Absturz eines
  Plug-in-Prozesses, Start/Stop. „Diagnose-Markierung setzen" (⌥⌘M) setzt eine Marke („jetzt Sound gewechselt").
  „Diagnose-Ordner zeigen" öffnet den Ablageort. Die Aufzeichnung bleibt über einen Neustart eingeschaltet.
  Anlass: der Tonausfall nach einem Soundwechsel in Odin 2 ist noch nicht erklärt; die Aufzeichnung soll ihn belegen.

**Geändert**
- **Wächter der Audioausgabe:** prüft viermal je Sekunde statt einmal; ungültige Werte, die während der Sperrfrist
  auftreten, gehen nicht mehr verloren; das Log unterscheidet „versucht", „erholt" und „ohne Erfolg". Der Wächter
  erkennt nach wie vor nur eine stehende Engine, ausbleibende Audioblöcke und NaN/∞ – nicht einen zu hohen, aber
  gültigen Pegel.
- **Step-Länge und Step-Anzahl** rechts neben jeder Spur: kleiner und untereinander (Anzahl oben, Länge als „3/2"
  unten) in einer halb so breiten Spalte. Bedienung unverändert: Klicken öffnet die Eingabe, Ziehen ändert den Wert.

**Behoben**
- Mixer: Die Beschriftung „0.0" bei 0 dB wurde mit einer falschen Formatangabe erzeugt (Laufzeitwarnung).

## [1.13.13] — 2026-11-12

### Ereignisübergabe an Instrumente abgesichert (Codex-Prüfung H1–H5, H7)

**Behoben**
- **Überlast:** Ist die Warteschlange eines Instruments voll, wird nichts mehr vorgezogen (vorher konnten Ereignisse zu
  früh erklingen). Ein dabei abgewiesenes Note-Off geht nicht mehr verloren, sondern im nächsten Tick hinaus.
- **Panik/Stop während eines Audioblocks:** Ein „Alle Noten aus", das genau in diesem Moment eingereiht wurde, konnte
  verworfen werden. Es kommt jetzt immer an.
- **Instrument getauscht oder Kanal neu belegt:** Noten, Offs und Vorhör-Offs, die für das vorige Instrument geplant
  waren, erreichen das neue nicht mehr.
- **Projekt laden während ein Plug-in lädt:** Ein verspätet fertig gewordenes Plug-in des alten Projekts kann nicht mehr
  in den gleichnamigen Kanal des neuen Projekts geraten.

**Geändert**
- **CC-Spur mit Parameterziel:** Das Ziel merkt sich, zu welchem Plug-in es gehört. Ist ein anderes Instrument geladen,
  das Instrument noch nicht bereit oder der Parameter verschwunden, zeigt die Taste den Namen mit „?" und die Spur
  sendet nichts – vorher sendete sie dann stillschweigend MIDI-CC. Ziele aus v1.13.9 … v1.13.12 (ohne Plug-in-Angabe)
  gelten weiter für das geladene Instrument.

**Preset-Format**
- `ccParameter` hat das optionale Feld `component` (Plug-in-Kennung). Fehlt es, gilt das Ziel ungebunden.

---

## [1.13.12] — 2026-11-12

### Drone-Steps

**Neu**
- **Drone:** In der Edit-Card eines Steps (Rechtsklick) gibt es den Schalter **DRONE**. Ein Drone-Step hält seinen
  Ton (oder Akkord) über die ganze Länge der Spur und wird im nächsten Durchlauf nicht neu angeschlagen – der Ton
  steht, bis der Step ausgeschaltet oder der Sequencer gestoppt wird. Gate und Ratchet gelten für ihn nicht. Die
  Step-Taste zeigt „DRONE".
- Ändert sich der Step (Tonhöhe, aus, kein Drone mehr) oder fällt er per Wahrscheinlichkeit aus, endet der alte Ton
  einen halben Step nach dem Ende des Durchlaufs.

**Preset-Format**
- Neuer optionaler Schlüssel `drone` im Step, nur geschrieben, wenn gesetzt. Ältere Versionen ignorieren ihn und
  spielen den Step mit seinem Gate.

---

## [1.13.11] — 2026-11-12

### Wächter für die Audioausgabe

**Neu**
- **Audioausgabe erholt sich selbst:** Bleibt der Ton aller Instrumente weg (gemeldet: nach einem Soundwechsel in
  Odin 2; bisher half nur, das Ausgabegerät in den Systemeinstellungen umzuschalten), baut die App den Renderweg
  innerhalb von ein bis drei Sekunden selbst neu auf. Erkannt werden: Engine angehalten, Engine liefert keine
  Blöcke mehr, ungültige Samples (NaN/∞) im Signal. Der Anlass steht im Systemprotokoll (Kategorie „audio").

---

## [1.13.10] — 2026-11-12

### Fensterkopf, Transportleiste aufgeräumt, App-Menü

**Behoben**
- **Titelleiste verdeckte den oberen Rand der App:** Der Inhalt rückt um das gemessene Maß unter die Titelleiste.
- **Programmname im Menü:** Die Menüleiste zeigt „FIRSTofFIFTH" statt „VintageSequencer".
- **Zwei „View"-Menüs:** Tooltips und Sprache stehen jetzt im vorhandenen Darstellungsmenü.

**Geändert**
- **WIDTH** ist ein kleiner Schieber rechts neben den Symboltasten statt einer hellen Platte in der Mitte.
  Standardwert für neue Installationen: 57 (30 % des Bereichs); ein gespeicherter Wert bleibt.
- **Clock INT/EXT** sitzt in den Einstellungen (Abschnitt „Clock"). Die Statuszeile zeigt die Quelle weiterhin.
- **Einstellungen** haben ein Zahnrad als Symbol und einen Eintrag im App-Menü („Einstellungen …", ⌘,).

---

## [1.13.9] — 2026-11-12

### CC-Spur steuert Instrument-Parameter, Tasten mit voller Klickfläche

**Neu**
- **CC-Spur mit Ziel im Instrument:** Geht eine CC-Spur auf einen Instrumentenkanal, sitzt im Kopf (dritte Zeile)
  die Taste **„CC ▾"**. Ihr Menü listet die Parameter des Instruments (nach den Gruppen des Plug-ins, sonst in
  Blöcken zu 40) und „MIDI-CC n". Mit gewähltem Parameter zeigt die Taste dessen Namen in Spurfarbe; die Werte
  0 … 127 der Spur werden auf den Wertebereich des Parameters abgebildet und samplegenau gesetzt. Ohne Wahl sendet
  die Spur wie bisher MIDI-CC an das Instrument (was das Plug-in daraus macht, bestimmt es selbst – CC 74 ist
  z. B. per Konvention die Filterfrequenz).
- Rückgängig-Schritt für die Zielwahl.

**Behoben**
- **Tasten reagierten nur auf der Beschriftung:** Alle Tasten nehmen Klicks jetzt auf ihrer ganzen Fläche an
  (kleine Tasten wie FEEL/SCL/RND/CLR/m/s, Pattern-Tasten, Play/Stop, Richtungstasten, Symboltasten).

**Preset-Format**
- Neuer optionaler Schlüssel `ccParameter` (`address`, `name`) in CC-Lanes. Dateien ohne ihn laden unverändert;
  ältere Versionen ignorieren ihn und senden MIDI-CC.

---

## [1.13.8] — 2026-11-12

### Step: Tonhöhe ziehen ohne Sprung, ⌥+Ziehen für Velocity

**Behoben**
- **Tonhöhe sprang beim Anziehen um zwei Halbtöne:** Das Ziehen zählt jetzt ab dem Punkt, an dem es erkannt
  wird. Der erste Schritt ist ein Halbton.

**Neu**
- **⌥ + senkrecht ziehen ändert die Velocity** des Steps (hoch = lauter, 1 Punkt je Stufe, 1 … 127). Ein
  Undo-Schritt. ⌥ muss beim Beginn des Ziehens gehalten sein. ⌥ + Klick öffnet weiterhin die Edit-Card,
  ⌥ + waagerecht ziehen kopiert weiterhin.

---

## [1.13.7] — 2026-11-12

### Zweiter Instrumentenkanal stumm, unscharfe UADx-Editoren, Ausgangstaste

**Behoben**
- **Kanal blieb stumm, wenn schon ein anderer lief:** Ein Instrument (oder Effekt), das bei laufender Audio-Engine
  geladen wurde, kam nicht in den Renderweg. Betroffen war jeder Kanal ab dem zweiten. Die Engine wird nach dem
  Einsetzen eines Plug-ins jetzt neu gestartet; der Ton der übrigen Kanäle setzt dabei kurz aus (nur beim Laden).
- **Editoren von UADx-Plug-ins blieben unscharf:** Folge desselben Fehlers. UADx schaltet sich erst frei, wenn der
  Host Render-Ressourcen anlegt; ohne das blieb der Lade-/Lizenzbildschirm stehen.
- **Systemdialog „Sicherheitseinstellungen senken":** Plug-ins werden nur noch im eigenen Hilfsprozess geladen. Der
  Rückfall auf das Laden im App-Prozess, der diesen Dialog auslöst, ist entfernt. Ein Plug-in, das sich so nicht
  laden lässt, zeigt „Name !".
- **Doppelte Einträge in der Plug-in-Auswahl:** Mehrfach installierte Plug-ins (System- und Benutzerordner)
  erscheinen einmal.

**Geändert**
- **Ausgangswahl im Spurkopf** ist jetzt als Taste gezeichnet (Tastenfläche, Rand in Spurfarbe, Pfeil):
  „MIDI ▾" bzw. „AU ▾" in Spurfarbe. Der Kanalwähler daneben ist dafür 6 pt schmaler.

---

## [1.13.6] — 2026-11-12

### Ausgangswahl im Spurkopf erkennbar

**Behoben**
- **Ausgang einer Spur war nicht zu finden:** Die Ausgangswahl stand als unscheinbares „CH" neben dem
  MIDI-Kanalwähler und sah wie dessen Beschriftung aus. Sie ist jetzt eine Taste: **„MIDI"** (externes MIDI) bzw.
  **„AU"** in Spurfarbe (Instrumentenkanal).
- **CC-Lanes** hatten im Kopf keine Ausgangswahl (nur im Kontextmenü). Sie haben jetzt dieselbe Taste.

**Neu**
- **„Neuer Instrumentenkanal"** im Ausgangsmenü (Spurkopf und Kontextmenü „Ausgang"): legt einen Kanal an, weist
  ihn der Spur zu und blendet den Mixer ein. Das Instrument wird dort im obersten Platz des Kanalzugs gewählt.
  Undo nimmt die Zuweisung zurück, der Kanal bleibt.

---

## [1.13.5] — 2026-11-12

### Kanalzug: Bedienung wie in Planarium, Editoren von Apple-Effekten

Alle Elemente, die es in beiden Programmen gibt, bedienen sich jetzt gleich.

**Behoben**
- **Editor von Apple-Effekten öffnete nicht:** Effekte ohne eigene Oberfläche (z. B. AUMatrixReverb) lieferten ein
  1 × 1 Punkt großes Fenster. Sie bekommen jetzt die Parameteransicht des Systems (scrollbar); alle Editor-Fenster
  öffnen in der Größe ihres Editors.

**Geändert — Kanalzug**
- **Reihenfolge** von oben nach unten: Instrument, vier Inserts, Panorama, dB-Feld, Skala · Fader · Pegelanzeige,
  Mute · Solo, Kanalnummer, Name (unten). Züge 72 pt breit, bündig nebeneinander.
- **Plätze (Instrument/Insert):** In Ruhe steht der Name. Unter dem Mauszeiger teilt sich der Platz in drei Felder:
  links Ein/Aus, Mitte Editor öffnen, rechts Auswahl. Die Auswahl ist eine Liste „Hersteller · Name" mit „Leer" als
  erstem Eintrag; die Wahl ersetzt, was an dieser Stelle sitzt, und öffnet den Editor, sobald das Plug-in geladen ist.
  Anzeige: „—" leer, „Name …" lädt, „Name !" nicht ladbar; ausgeschaltet = grau.
- **Instrument Ein/Aus (neu):** Aus beendet klingende Noten und verwirft neue; das Plug-in bleibt geladen.
- **Fader:** gleiche Skala wie Planarium (−∞ … +6 dB, 0 dB bei drei Vierteln des Wegs), aufgedruckt links vom
  Fader. Ziehen relativ zum Greifpunkt (kein Sprung beim Anfassen), ⌥ = fein, Esc bricht ab, Doppelklick = 0 dB,
  Scrollrad, Pfeiltasten. **Pegel über 0 dB sind jetzt möglich** (Kanäle und Summe).
- **Panorama:** senkrecht ziehen (⌥ = fein), Doppelklick = Mitte, Scrollrad; Anzeige „C", „L37", „R100" im Knopf.
- **Pegelanzeige:** dB-Ziffern, Farbverlauf nach Höhe (grün bis −12, orange ab −6, rot ab −3 dBFS), Abfall 20 dB/s,
  Übersteuerungsfeld oben (hält 2 s, Klick löscht sofort).
- **Mute/Solo:** Symboltasten (Lautsprecher/Kopfhörer), Mute orange, Solo gelb.
- **Name:** Doppelklick benennt um (Eingabetaste oder Verlassen übernimmt, Esc verwirft); auch über das Kontextmenü des
  Zugs (Umbenennen …, Kanal duplizieren, Kanal löschen). Unter dem Namen die Farben der Spuren, die den Kanal spielen.
- **Summe:** dB-Feld, Fader, Pegelanzeige, PANIC an der Stelle von Mute/Solo, „Master".
- Der Mixer gibt bei kleinem Fenster in der Höhe nach (nur der Faderweg), die Spuren behalten mindestens 150 pt.

**Entfallen**
- Insert umsortieren per Menü (in Planarium nicht vorhanden; Platz neu belegen ersetzt an Ort und Stelle).

**Nicht übernommen** (gibt es in FIRSTofFIFTH nicht): MIDI-Effekt-Plätze, Sends, Ausgabegerät-Taste, Kanal-Presets,
Kanalfarbe, Perform-Sperre. Die Kopfzeile des Mixers bleibt die schmale Leiste links mit „+".

**Preset-Format** (dokumentationspflichtig)
- `volume` (Kanal) und `masterVolume` reichen jetzt bis ≈ 1,995 (+6 dB) statt 1,0. Ältere Versionen begrenzen beim
  Laden auf 1,0.
- `bypassed` am Instrument bedeutet jetzt „Instrument aus" (bisher ohne Wirkung).

Geprüft: Logik und Audioweg durch Tests, das Layout an einem gerenderten Bild. Zeigerverhalten (Hover-Felder,
Ziehen, Scrollrad) ist nicht in der laufenden App abgenommen.

---

## [1.13.4] — 2026-11-12

### Step: ganze Taste klickbar, Rechtsklick öffnet die Edit-Card

- **Behoben:** Nur LED, Beschriftung und Farbstreifen eines Steps reagierten auf Klicks; die Tastenfläche dazwischen
  nicht (seit dem Materialumbau GUI-01: der Tastenkörper ist Dekor und nicht treffbar). Jetzt ist die ganze Taste
  Klickfläche — für An/Aus, Markieren, Tonhöhe ziehen und Verschieben.
- **Geändert:** Rechtsklick (auch ctrl+Klick) auf einen Step öffnet direkt die Edit-Card. Das Kontextmenü entfällt.
  ⌥+Klick öffnet die Card weiterhin.
- Aus dem früheren Menü: „Step löschen" sitzt jetzt als Taste im Kopf der Edit-Card. „Max. Velocity", „Gate: voll" und
  „Gate: kurz" entfallen — Velocity und Gate stehen in der Card als Regler.
- Folge der vollen Klickfläche: Ziehen, das auf einer Taste beginnt, ändert immer Tonhöhe (senkrecht) oder verschiebt
  den Step (waagerecht). Das Auswahlrechteck startet in den Lücken, über/unter den Tasten und rechts der Steps;
  ⇧+Klick markiert einzelne Steps.

Nicht in der laufenden App geprüft: Die Zuordnung Punkt → Step ist getestet, das Abfangen des Rechtsklicks selbst nicht.

---

## [1.13.3] — 2026-11-12

### Lesbarkeit: Textkontrast auf dunklen Flächen

Anlass: Die Schnellwahl im Popover „Step-Länge / Ratio" war kaum zu lesen. Ursache waren nicht einzelne Karten, sondern
zwei Textfarben des Themes, die überall auf dunklen Flächen stehen.

- **Nebentext** (`textSecondary`: Abschnittstitel, Beschriftungen, Symbole der Transportleiste) heller:
  Kontrast auf Popover-Flächen von 3,6:1 auf 7,9:1.
- **Gedämpfter Text** (`textDim`: Statusleiste, Zeitstempel und Hinweise im Notizbuch, Schnellnotiz) heller:
  von 1,7:1 auf 4,8:1.
- **Beschriftung nicht aktiver Tasten** (kleine Tasten in allen Popovern, Pattern A–D, Richtungstasten im Spurkopf,
  Mute/Solo im Mixer) nutzt jetzt die Haupttextfarbe: auf der Taste von 2,0:1 auf 6,2:1.
- Zähler im Bruch der Popover „Step-Länge / Ratio" und „Step-Anzahl" nicht mehr abgeblendet.
- Betroffen sind damit alle Karten: Ratio, Step-Anzahl, Step-Detail, Mehrfacheditor, Feel, Tonart, Schnellnotiz,
  Notizbuch, Einstellungen sowie Transport- und Statusleiste.
- Neu: `ThemeContrastTests` sichern die Mindestkontraste (4,5:1 Nebentext und Tastenbeschriftung, 3:1 gedämpft).

Schriftgrößen sind unverändert. Die Werte sind berechnet, nicht am Bildschirm abgenommen.

---

## [1.13.2] — 2026-11-12

### App-Icon

- **Neu:** FIRSTofFIFTH hat ein eigenes Icon: fünf Tasten auf einer Kreisbahn in dunklem Metall, die erste leuchtet
  bernsteinfarben („first of fifth"); innen vier Punkte als Gegenrhythmus (5 gegen 4).
- Das Icon wird von `Tools/make_app_icon.swift` gezeichnet (`swift Tools/make_app_icon.swift <ziel.png>` → 1024 px);
  die Größen im Asset-Katalog sind daraus verkleinert. Kein Programmcode geändert.

---

## [1.13.1] — 2026-11-12

### Mixer: Kanalzüge am unteren Fensterrand

Das Instrumenten-Rack ist kein Dialog mehr, sondern ein Mischpult nach dem Vorbild von Planarium (Anordnung wie in
Logic), gebaut aus den vorhandenen Materialbausteinen.

**Neu**
- **Mixer-Bereich** am unteren Fensterrand über die volle Breite, ein- und ausblendbar mit dem Regler-Symbol in der
  Transportleiste (ersetzt das Klaviatur-Symbol und den Rack-Dialog). Der Zustand bleibt über Neustarts erhalten.
- **Kanalzüge** nebeneinander, von oben nach unten: Name (Glasanzeige, editierbar), Instrument-Platz (violett), vier
  Insert-Plätze (blau) in Signalfolge, Panorama-Knopf, dB-Anzeige, senkrechter Fader mit Stereo-Pegelanzeige, Mute und
  Solo. Klick auf einen belegten Platz öffnet den Plug-in-Editor; der Pfeil daneben öffnet das Menü.
- **Inserts:** An/Aus je Effekt (Punkt links im Platz), Umsortieren innerhalb der Kette (Menü → nach oben / nach unten).
- **Solo** je Kanal: steht ein Kanal auf Solo, sind nur Solo-Kanäle hörbar. Mute gewinnt gegen Solo.
- **Summe** fest ganz rechts: Master-Fader, Stereo-Pegelanzeige, **PANIC** (beendet alle Noten auf allen Instrumenten
  und auf allen 16 MIDI-Kanälen; die Wiedergabe läuft weiter).
- **Stereo-Pegelanzeigen** je Kanal und für die Summe, mit Spitzenhaltung.
- **Kanal duplizieren** (Kontextmenü des Zugs): gleiches Instrument samt aktuellem Klang, gleiche Effekte und
  Einstellungen, eigene Plug-in-Instanzen. Spuren bleiben beim Original.
- **Ausgangswahl im Spurkopf:** Die Taste „CH"/„AU" vor dem MIDI-Kanal öffnet die Auswahl (Externes MIDI oder ein
  Instrumentenkanal), rücknehmbar. Das Kontextmenü der Spur bleibt als zweiter Weg.
- **Zuordnung sichtbar:** Jeder Zug zeigt unten Punkte in den Farben der Spuren des aktuellen Patterns, die ihn spielen.
  Klick in einen Spurkopf oder eine Ausgangswahl hebt den zugehörigen Zug hervor.

**Verhalten**
- Fader: Stellung 0…100 wirkt quadratisch auf den Pegel (feiner im oberen Bereich), oben = 0 dB. Verstärkung über 0 dB
  gibt es nicht.
- Kanal löschen fragt nach, wenn Spuren (in irgendeinem Pattern) den Kanal spielen; sie fallen auf externes MIDI zurück.
- Behoben (nie ausgeliefert): Nach dem Löschen des einzigen Solo-Kanals blieben die übrigen stumm.

**Preset-Format** (dokumentationspflichtig)
- Neue optionale Keys: `masterVolume` (Datei), `isSoloed` (Instrumentenkanal), `bypassed` (Plug-in-Verweis).
  Projekte aus v1.13.0 laden unverändert (Vorgaben: 1,0 / false / false). v1.13.0 ignoriert die neuen Keys beim Laden
  und verliert sie beim erneuten Speichern.

**Grenzen**
- Rack- und Mixer-Änderungen (Pegel, Plug-ins, Kanäle) sind weiterhin nicht rücknehmbar; nur die Ausgangswahl der Spur.
- Kein Tastaturkürzel für den Mixer, keine Kanal-Presets, keine Wahl des Ausgabegeräts, keine MIDI-Effekt-Plätze.
- Die Oberfläche ist übersetzt und durch Unit-Tests der Logik abgesichert, aber noch nicht in der laufenden App
  gesehen oder gehört worden — Abstände, Faderbedienung und Meter-Ballistik brauchen eine Sichtprüfung.

---

## [1.13.0] — 2026-11-12

### AU-Hosting: Instrumenten-Rack mit Effektkette und Mixer

Erster Schritt der Standalone-Vision (`Docs/STANDALONE_VISION_UND_AU_HOSTING.md`): FIRSTofFIFTH kann installierte
AU-Instrumente selbst spielen. Externe MIDI-Ausgabe bleibt unverändert und ist weiter der Standard jeder Spur.

**Neu**
- **Instrumenten-Rack** (Klaviatur-Symbol in der Transportleiste): bis zu 16 Kanäle, je ein AU-Instrument, bis zu vier
  AU-Effekte in Reihe, Pegel, Panorama, Mute. Plug-in-Editoren öffnen in eigenen Fenstern; Plug-ins ohne eigenen Editor
  bekommen die Parameteransicht des Systems.
- **Ausgang je Spur** (Kontextmenü der Spur → „Ausgang", rücknehmbar): „Externes MIDI" oder ein Instrumentenkanal.
  Mehrere Spuren dürfen denselben Kanal spielen, auch CC-Spuren. Der Spurkopf zeigt dann „AU" statt „CH"; der
  MIDI-Kanal gilt innerhalb des Instruments.
- **Gleiche Zeitbasis für innen und außen:** Gehostete Instrumente bekommen ihre Noten samplegenau zum selben
  Zeitpunkt, zu dem externe Geräte ihre MIDI-Events erhalten. Gemessen mit Apples DLS-Synthesizer: Klangeinsatz
  0,11 … 0,15 ms nach dem geplanten Zeitpunkt.
- **Projekt speichert das Rack:** Kanäle, Plug-ins, deren vollständigen Klangzustand, Pegel und das Routing der Spuren.
- **Fehlende Plug-ins** werden als „FEHLT" angezeigt; ihr gespeicherter Klang bleibt erhalten und wird beim Speichern
  unverändert wieder geschrieben. Nichts wird stillschweigend ersetzt.
- Vorhören (Klaviatur, Drum-Auswahl, Ziehen der Tonhöhe) erklingt am Ausgang der Spur.

**Verhalten**
- Ohne Instrumentenkanäle öffnet die App weiterhin kein Audiogerät.
- Plug-ins laufen in einem eigenen Prozess (Sandbox-Vorgabe; ein abstürzendes Plug-in reißt die App nicht mit).
- Wird ein Kanal entfernt, spielen seine Spuren wieder über externes MIDI.
- Änderungen im Rack (Plug-in-Wahl, Pegel …) sind nicht rücknehmbar; das Routing einer Spur ist es.

**Preset-Format**
- Neue optionale Keys: `instruments` (Projektebene) und `instrumentID` (Spur). Presets ohne Rack sehen aus wie bisher.
  Ältere App-Versionen ignorieren beide Keys und spielen alles über MIDI.

**Bekannte Grenzen**
- Getestet mit Apples DLS-Synthesizer. Fremd-Plug-ins, Gerätewechsel im Betrieb und Sleep/Wake sind nicht geprüft.
- Kein Latenzausgleich zwischen internem Audio und externen MIDI-Geräten (Ausgangs- und Plug-in-Latenz).
- Kein Audio- oder MIDI-Export, kein Solo im Rack, keine Pegelanzeige, Effekte nicht umsortierbar.
- Hostkontext für tempo-synchrone Plug-ins (Tempo, Taktposition) wird noch nicht geliefert.

---

## [1.12.23] — 2026-11-12

### GUI-Revision (Codex-Durchsicht 2026-11-12): Auto-Scroll, Undo, Tonzuordnung, Drum-Modus, Anfasser

**Behoben**
- **Auto-Scroll beim Ziehen** setzte viel zu früh ein: Die Randzonen waren je 300 px breit und überlappten in schmalen
  Lanes, sodass schon ein ruhender Zeiger in der Lane-Mitte scrollte. Jetzt 80 px je Seite, höchstens ein Viertel der
  Breite; die mittlere Hälfte ist immer scrollfrei. Ein über den Rand hinaus gezogener Zeiger scrollt weiter (vorher
  hielt das Scrollen dort an). Die Eck-Anfasser rechnen den Spurkopf nicht mehr als Scrollbereich.
- **Mehrfacheditor ist rücknehmbar:** alle Änderungen eines Dialogs ergeben einen Undo-Schritt. Auch die
  Ratio-Schnellwahl und „Reset 1:1" sind jetzt rücknehmbar.
- **Klaviatur spielt den Ton vor, der gespeichert wird.** Bei aktiver Skala war der angeklickte Ton zu hören, gespeichert
  wurde der auf die Skala gezogene.
- **Rubberband ohne Breite** wählt keinen Step mehr. Die Auswahlleiste erscheint erst nach dem Loslassen und verschiebt
  die Lane nicht mehr während des Ziehens. Wird die Spur kürzer, fallen nicht mehr vorhandene Steps aus der Auswahl.

**Neu**
- **Klaviatur mit zwei Modi:** TON (Klick ersetzt den Ton) und AKKORD (Klick fügt einen Akkordton hinzu oder entfernt
  ihn). ⇧-Klick wirkt immer als Akkord. Der Startmodus folgt dem Step. Vorher fügte jeder Klick einen Akkordton hinzu.
- **Drum-Spur als eigener Modus** (Kontextmenü der Spur, rücknehmbar), unabhängig vom MIDI-Kanal. Die Drum-Auswahl
  spielt den Klang beim Anklicken vor.
- **Step-Anzahl direkt eingeben:** Klick auf die Zahl öffnet Eingabefeld, ± und Schnellwahl (4 … 64).
- **Verhältnis immer als Zahl sichtbar** (auch 1:1, gedämpft) statt eines namenlosen Griffs.

**Preset-Format**
- Neuer optionaler Key `isDrum` je Spur. Fehlt er (Presets bis 1.12.22), gilt wie bisher „Kanal 10 = Drum-Spur".
  Ältere App-Versionen ignorieren den Key und zeigen wieder die Kanal-10-Regel.
- **Verhaltensänderung:** Eine Spur nachträglich auf Kanal 10 zu stellen schaltet nicht mehr automatisch die
  Drum-Ansicht ein.

**Tests**
- Die vier Legacy-Preset-Tests (Format vor 1.5.0, lädt seit dem Lane-Umbau nicht mehr) sind gestrichen
  (Stephan-Entscheid 2026-11-12). Der RubberBand-Nullbreite-Test ist durch die Korrektur grün. Die Suite hat keine
  bekannten roten Tests mehr.

---

## [1.12.22] — 2026-11-12

### Note-Offs aus dem Notenbuch, Mute-Menü, Spurgrenze

Kein Eingriff in Modell oder Preset-Format.

**Behoben**
- **Gleiche Note überlappt sich selbst:** Folgt dieselbe Tonhöhe, während die vorige noch klingt (Gate über 100 %, oder zwei
  Spuren auf demselben Kanal), schnitt das Ende der ersten Note die zweite ab. Jetzt wird die Note auf dem neuen Anschlag
  neu ausgelöst und klingt bis zum späteren der beiden Enden.
- **Stopp bei noch geplanten Noten** (Ratchet, Swing, Offset): Das Note-Off wird hinter den geplanten Anschlag datiert.
  Empfänger am virtuellen Ausgang behielten sonst eine hängende Note.
- **Mute-Menü** (Menü „Sequencer"): Die Einträge zeigen den aktuellen Mute-Zustand; vorher blieb die Beschriftung stehen.

**Geändert**
- Note-Offs werden nicht mehr zusammen mit dem Anschlag vorausgeplant, sondern kurz vor ihrem Zeitpunkt gesendet. Am
  Zeitpunkt selbst ändert sich nichts.
- Bleibt die externe Clock ohne Stop-Nachricht aus, beendet die App nach 0,3 s alle Noten, deren Ende überschritten ist.
- Höchstens 128 Spuren je Pattern; darüber legen „Neue Spur", „Einfügen" und „Duplizieren" nichts mehr an. (Vorher blieben
  Spuren jenseits der internen Grenze stumm.)

---

## [1.12.21] — 2026-11-12

### Clock-Quelle: Echtzeit-Thread statt AVAudioEngine-Tap (Review 2026-11-12, Paket 4)

Kein Eingriff in Modell, Preset-Format oder Oberfläche. Der Tick-Pfad selbst ist unverändert, nur sein Wecker ist neu.

**Geändert**
- **Kürzere Reaktionszeit im INT-Modus:** Noten, CCs und Clock werden nur noch ein Tick-Intervall plus 10 ms vorausgeplant
  (bei 120 BPM rund 31 ms) statt fest 120 ms. Start, Stopp, Mute, Step-Änderungen und Patternwechsel greifen entsprechend früher.
- **Gleichmäßige Ausgabe:** Die interne Clock weckt einmal pro Tick auf einem eigenen Echtzeit-Thread. Vorher lieferte das
  Audiosystem die Ticks in Schüben von etwa fünf alle 100 ms.
- **Unabhängig vom Audiogerät:** Die App öffnet kein Audiogerät mehr (kein stummer Ausgang, kein Einfluss durch Wechsel von
  Abtastrate oder Ausgabegerät, keine Wartezeit beim ersten Start).

**Messwerte (120 BPM, gleicher Rechner)**

| | vorher (Tap) | jetzt (Echtzeit-Thread) |
|---|---|---|
| Vorlauf eines Ticks (Ausgabe → Zeitpunkt) | 47 … 151 ms | 30,7 … 30,8 ms |
| Abstand der Tick-Ausgaben | Schübe alle ~104 ms | 20,79 … 20,89 ms |
| Größte Weckverspätung | 76 … 87 ms | 0,08 ms |

**Hinweis**
- Bei sehr langsamem Tempo wächst der Vorlauf mit dem Tick-Intervall (20 BPM: 135 ms).
- Die Zeitstempel der Events lagen schon vorher auf einem exakten Raster; hörbar ändert sich die Latenz, nicht das Raster.

---

## [1.12.20] — 2026-11-12

### Oberfläche: Beobachtungshygiene, Lokalisierung, Aufräumen (Review 2026-11-12, Paket 3)

Kein Eingriff in Tick-Pfad, Modell oder Preset-Format. Aussehen unverändert.

**Flüssigkeit**
- Playhead-, Scroll- und Drag-Updates lassen die Lanes nicht mehr komplett neu aufbauen: pro Tick laufen nur noch die zwei
  betroffenen Step-Taster je Spur neu, beim Scrollen und bei gespielten Noten gar keine Lane-Inhalte (gemessen offscreen an der
  echten Hauptansicht: Lane-Body 0 Läufe bei 24 Playhead- bzw. 20 Scroll-Updates).

**Behoben**
- **Hängende Drag-Session:** Verschwindet die Spur oder das Pattern unter einer laufenden Geste (Löschen, Undo, Patternwechsel,
  Laden), wird die Session abgebrochen; vorher blieben danach alle Gesten wirkungslos.
- **MIDI-Learn-Markierung** folgt jetzt sofort dem angetippten bzw. weitergerückten Step.
- **Klick in ein aktives Textfeld** beendet die Bearbeitung nicht mehr.
- **BPM-Doppelklick** setzt auf 120 statt auf 160 (Bereichsmitte).
- **Step-Breite** bleibt in jedem Build im Bereich 30…120 (Debug-Builds konnten größere Werte speichern).

**Lokalisierung (EN/DE)**
- Einstellungen, Notizen, Schnellnotiz, Schnellwahl der Step-Längen samt Erklärungen, Farbnamen sowie die Fehlermeldungen beim
  Laden/Speichern und bei getrenntem MIDI-Ausgang. Panel-Beschriftungen in Versalien (BPM, TAP, PATTERN, CLOCK, GATE …) bleiben englisch.

**Entfernt**
- Ungenutzter Code: `BPMGridView`, `EdgeAutoScroller` (Platzhalterdatei), Step-Zelle ohne Geste (Debug-Variante),
  sechs ungenutzte Theme-Konstanten, `TrackViewModel.isExpanded`, Debug-Ausgaben pro gespielter Note.

---

## [1.12.19] — 2026-11-12

### Engine-Kern: Patterngrenze, Stop-Offs, Tick-Zutritt (Review 2026-11-12, Paket 1)

Kein Eingriff in Preset-Format, Views oder Hazard-Pointer-Protokoll des Snapshot-Erwerbs.

**Hörbar geändert**
- **Start liegt auf dem ersten Clock-Puls:** Der erste Step erklingt zusammen mit MIDI-Start und dem ersten Clock-Puls.
  Vorher kam er eine volle Step-Länge später (bei 1/16 und 120 BPM ≈ 104 ms hinter Beat 1 eines mitlaufenden Geräts).
- **Quantisierter Patternwechsel sitzt auf der Grenze:** Das neue Pattern beginnt exakt an der Track-1-Grenze. Vorher
  spielte dort noch einmal Step 1 des alten Patterns, das neue startete einige Ticks versetzt zum Clock-Raster.
- **Das aktuelle Pattern erneut wählen** hebt eine Vormerkung auf (vorher: Neustart des Patterns an der Grenze).

**Behoben**
- **Hängende Noten beim Stopp:** Jede Note, deren Note-Off noch aussteht, bekommt beim Stopp ein sofortiges Note-Off auf
  ihrem ursprünglichen Kanal — aus einer Sendebuchhaltung im Tick-Pfad statt aus verzögertem UI-Zustand. CC 123 bleibt zusätzlich.
- **Externe Clock:** Nach einem externen Start blieb die Step-Anzeige stehen und der Display-Lebenszyklus geriet aus dem
  Gleichgewicht. MIDI-Start bei laufender Wiedergabe beginnt von vorn, Continue bei laufender Wiedergabe ist wirkungslos.
- **Spur einfügen/löschen im Playback:** kein Tick mehr mit vertauschter Zuordnung zwischen Spur und Abspielposition.
- **Verlorene Anzeige-/Wechselereignisse:** Die Ringpuffer zwischen Tick-Thread und Oberfläche sind jetzt lock-frei und größer;
  ein Patternwechsel kann nicht mehr verloren gehen.
- **Interne Clock:** Start/Stop ohne Lock; ein noch laufender Clock-Callback trifft beim Stopp nie auf zurückgesetzten Zustand.

---

## [1.12.18] — 2026-11-12

### Command-Schicht mit Identität: Struktur, Undo, Preset-IO (Review 2026-11-12, Paket 2)

Kein Eingriff in Tick-Pfad, Snapshot-Protokoll oder Preset-Format.

**Behoben**
- **Absturz ab 10 Spuren:** Das Mute-Menü vergibt Kürzel nur noch für ⌥1…⌥9.
- **Undo nach Spur-Löschen/-Wiederherstellen:** Undo setzt dieselbe Spur wieder ein; ältere Undo-Schritte (Step-Edits dieser Spur)
  funktionieren danach weiter. Bei Patterns mit unterschiedlicher Spurzahl landet jede Spur wieder in ihrem Pattern.
- **Undo über Projektgrenzen:** Öffnen und „Neu“ leeren den Undo-Verlauf; ⌘Z verändert nicht mehr das neu geladene Projekt.
- **Pattern einfügen:** erzeugt eigene Spur-Identitäten (vorher zeigten Quell- und Ziel-Pattern dieselben Spuren an; Edits waren
  sichtbar, aber unhörbar und ungespeichert), markiert das Projekt als geändert, ist rückgängig machbar und passt im Playback
  Spurzahl und Anzeige an.
- **Erneutes Öffnen derselben Datei:** Die Oberfläche bindet an die neu geladenen Spuren statt an die alten.
- **Neue Spur im letzten Pattern:** Edits setzen wieder das Änderungs-Flag und wirken im Playback sofort.
- **Tempoänderung im Playback:** Gate-Längen, Swing und Feinraster rechnen mit dem neuen statt dem vorherigen Tempo.
- **Speichern-Dialog bei ungespeicherten Änderungen:** Wird das Speichern abgebrochen oder schlägt es fehl, bleibt das Projekt
  erhalten (vorher wurde trotzdem geladen bzw. geleert). „Speichern“ schreibt in die aktuelle Datei, falls vorhanden.
- **Speichern ist atomar:** Ein Abbruch mitten im Schreiben lässt die bisherige Datei intakt.
- **Preset mit weniger als vier Patterns:** fehlende Slots werden leer aufgefüllt; ein Preset ohne Pattern wird abgelehnt.
- **Fehlermeldung beim Laden** nennt den Grund (z. B. fehlender Pflicht-Key samt Pfad).
- **MIDI-Learn:** kein Absturz mehr, wenn die Zielspur gelöscht wurde; die gelernte Note geht nur ins sichtbare Pattern
  (vorher in alle vier) und ist rückgängig machbar.
- **Externe Clock:** Die Tempo-Schätzung markiert das Projekt nicht mehr als geändert.

**Geändert**
- RND, CLR (Spur und Auswahl), Steps einfügen und Pattern einfügen sind einheitlich rückgängig machbar.
- Knob-Drags im Step-Editor erzeugen einen Undo-Schritt pro Drag statt einen pro Mausbewegung.
- Performance im Playback: Eine gespielte Note invalidiert nicht mehr die gesamte Spurzeile (`lastFiredNotes` ist nicht mehr `@Published`).

---

## [1.12.17] — 2026-10-20

### GUI-02 — Ruhigere, gleichmäßig beleuchtete Step-Taster (Round FOF-CX-2026-10-20-007)

Rein Darstellung. Keine Änderung an Geometrie, Clipping, Scrollgrenzen, Trefferflächen, Gesten, Bindings, Undo, Engine/MIDI,
Farbzuordnung oder Zustandslogik (Auftrag Stephan: Verlauf von Highlight/Schatten zu heftig, rechts zu dunkel).

- `PlasticKeyBackground` bekommt das Profil `.step` (Default `.standard` unverändert für alle anderen Taster): enger Helligkeitsbereich,
  gleichmäßige Track-Tönung, dezente obere Lichtkante und schmale weiche Unterkante statt Eck-zu-Eck-Diagonale. Nur `StepButtonView` nutzt `.step`.
- Aktiv/inaktiv, Notentext, Velocity, Ratchet/Probability, Auswahl, Learn und Playhead-LED bleiben unverändert und getrennt erkennbar.
- Bilder vorher/nachher bei 100 %: `Docs/GUI_REFERENCES/GUI-02/`; Evidenztest `GUI02StepMaterialEvidenceTests` nur im Evidenzlauf.
- `Docs/GUI_DESIGN_SYSTEM.md`: Muster „dezente, gleichmäßige Kunststoffbeleuchtung“ für dichte Taster-Raster (Planarium).
- Doku-Korrekturen aus dem Review -006: `G01R1ZoomBoundTests` hat sieben (nicht acht) Tests (R1-01); ENGINEERING G01 nennt nicht mehr den
  skalierten Slotanteil (R1-02); R1-03 (zwei identische Rundungsstellen) bleibt als Wartungsrisiko in der ROADMAP.

---

## [1.12.16] — 2026-10-20

### G01-R1 — Zoom-Grenze bei mehreren Updates konsistent (Round FOF-CX-2026-10-20-006, Review H1)

Rein Geometrie/Controller. Keine Engine-/Modell-/MIDI-Änderung, Zoom-Ankerformel und sichtbare G01-Korrektur unverändert.

- Behoben: Bei mehreren Pinch-Updates vor der nächsten Lane-Messung schrumpfte die Scrollgrenze (gemeldete Ausdehnung × inkrementelles
  Verhältnis; Review-Beispiel 1507 statt 1717), und `maxScrollOffset` blieb auf dem alten Wert und klemmte Folge-Schreiber zurück.
- Die Lanes melden jetzt Viewport und Topologie (`LaneShape`: Stepzahl, Ratio) statt einer Ausdehnung; die Ausdehnung wird für die
  jeweils wirksame WIDTH exakt aus Topologie und realer Rundung berechnet. Der Controller führt die wirksame WIDTH (`stepWidth`);
  alle Offset-Schreiber, Zoom-Kompensation und Scrollbar-Dokument nutzen dieselbe Grenze (`effectiveMaxOffset`).
- Tests: `G01R1ZoomBoundTests` (Review-Rechnung rot→grün, 4+ Updates, hinein/heraus/Richtungswechsel, Trackpad/Thumb/scroll dazwischen,
  verspätete Messungen, Resize/Count/Ratio danach, alle sortedRatios × gerundete WIDTH, gebrochene Pinch-Breiten); G01-Tests auf Topologie umgestellt.
- Bilder: `Docs/GUI_REFERENCES/G01-R1/` (repräsentativ, Scrollende).

---

## [1.12.15] — 2026-10-20

### G01 — Lane-Viewport und konsistente horizontale Scrollgrenzen (Round FOF-CX-2026-10-20-005)

Schließt GR-01 und GR-02 aus Revisorbericht `FOF-RV-2026-10-20-001`. Rein Layout/Geometrie — keine Engine-, Modell-,
Command-, MIDI- oder Dateiformat-Änderung, kein Handle-Redesign, Lane-Material und Zoom-Ankerformel unverändert.

- **GR-01:** Der scrollende Bereich von Step- und CC-Lane wird auf die gemessene Größe des Lane-GeometryReaders
  gelayoutet (`.frame(width:height:)` vor `.clipped()`/`.contentShape`). Zuvor wuchs der ZStack auf die Inhaltsbreite
  (z. B. 1884 pt bei 551 pt Viewport), Steps/Knobs malten in die feste 80-pt-Zone und den Außenrand.
- **GR-02:** Eine Scrollgrenze `max(0, Inhalt − Viewport)` (`LaneGeometry.maxOffset`) für Trackpad, Edge-Scroll,
  Scrollbar-Sync und Zoom-Kompensation. Inhaltsbreite aus den real gerenderten `distributedStepWidth`-Zellen
  (`LaneGeometry.contentExtent`); die frühere Schätzung `VintageTheme.laneContentWidth` (+80/+0 Buffer) entfällt.
- **Viewport-Quelle:** Die Lanes melden Viewport-Beginn/-Breite und Inhaltsausdehnung per Preference
  (`LaneViewportKey`, `LaneExtentKey`); `MainView` leitet sie an `ViewportController.reportLaneViewport/-Extent`.
  Angewendet wird gebündelt auf der nächsten Main-Queue-Runde (`applyLaneMetrics`): setzt `maxScrollOffset` und klemmt
  einen ungültigen Offset nach (Resize, WIDTH, Ratio, Stepzahl). Kein synchrones Published-Schreiben im View-Update.
- **Scrollbar:** `NativeHScrollbar` erhält Clip = Lane-Viewport (Beginn und Breite gemessen) und Dokument = Inhaltsausdehnung;
  das native Maximum (Dokument − Clip) ist damit exakt das gemeinsame Maximum. `GlobalHScrollbar` beobachtet jetzt
  `ScrollState` (Blattview), damit der Thumb Trackpad-, Edge-Scroll- und Zoom-Offsets folgt (zuvor nur bei zufälligem
  Neuaufbau). Pinch-Anker nutzt den gemessenen Viewport-Beginn.
- `VintageTheme.cornerHandlesWidth` (12 pt) benennt die bisher in `CornerHandlesView` fest codierte Breite; Wert unverändert.
- Tests: `G01LaneGeometryTests` (alle sortedRatios × WIDTH 30/54/120 × Count 1/16/64 gegen explizite Zellsumme),
  `G01ViewportControllerTests` (gemeinsame Grenze aller Schreibpfade, Nachklemmen, Koaleszierung),
  `G01ScrollbarBridgeTests` (echter NSScrollView), `G01LaneRenderTests` (gerenderte Breite == Formel, Clip == Viewport),
  Evidenzlauf `G01LaneViewportTests` (nur mit `TEST_RUNNER_G01_PREFIX`: 18 Bilder + Messwerte).
- Bilder: `Docs/GUI_REFERENCES/G01/`.
- Bekannt/unverändert: Edge-Scroll-Zonen und Handle-Koordinaten (G03), Session-Abbruch (G02), Mute-/Stop-Befunde.

---

## [1.12.14] — 2026-10-20

### GUI-01-R1 — Transportkorrektur (Round FOF-CX-2026-10-20-004)

Kleine Korrektur auf Stephans Rückmeldung zu GUI-01. Rein visuell — keine Engine-, Modell-, Command-, MIDI-,
Binding- oder Dateiformat-Änderung; Material und Patina unverändert.

- Die drei hellen Transportplatten (BPM, SWING, WIDTH) haben dieselbe sichtbare Außenhöhe
  (`TransportView.plateHeight`, 84 pt, gemeinsame obere/untere Flucht); Transporthöhe bleibt 100 pt.
- BPM und SWING zeigen unter dem Knopf nur noch das Label. `KnobView` hat den rein visuellen Parameter
  `showsValue` (Standard `true`); nur die beiden Transport-Aufrufe setzen `false`. Bei ausgeblendeter Zahl bleibt der
  aktuelle Wert für Accessibility (Label + Wert) erhalten. Andere Knobs und GateKnob-Labels unverändert.
- „FIRSTofFIFTH“ steht bei 920 pt (DE/EN) vollständig auf einer Zeile (feste Größe, höchste Layoutpriorität);
  Untertitel kürzt zuerst. Schriftgröße und Mindestbreite unverändert. Kompaktere Abstände im Transport;
  Labels PATTERN/CLOCK/LEARN/WIDTH, INT/EXT, ON/OFF, TAP und ▲▼ werden nicht mehr gestaucht (zuvor bei 920 pt
  umgebrochen bzw. ▲▼ verdrängt).
- Tests: `GUI01SceneRenderTests` rendert jetzt 920/1600 pt × DE/EN × WIDTH 30/120. Keine neuen Gradient-/Frame-Tests.
- Bilder: `Docs/GUI_REFERENCES/GUI-01-R1/`.

---

## [1.12.13] — 2026-10-20

### GUI-01 — Materialsystem und Bedienelemente als FoF-Pilot (Round FOF-CX-2026-10-20-003)

Sichtbarer Pilot in der normalen App (Transport, Step- und CC-Spuren, Taster, WIDTH-Fader),
Richtung: Re-Rebirth-Materialwirkung + Sick-Griffwirkung, dazu dezente Patina (gebrauchtes,
gepflegtes Studiogerät). Rein visuell — keine Engine-, Modell-, Command-, MIDI- oder Dateiformat-Änderung.

- Neu `Theme/VintageMaterials.swift`: gebürstetes Anthrazit-Metall, helles (leicht warmes, nachgedunkeltes)
  Aluminium, ruhige Grid-Fläche, Anzeigeglas, Kunststofftaster, geriffeltes Knopf-Face, Materialfader.
  Bürstungstextur einmalig erzeugt (`static let`, deterministisch), Patina statisch.
- Transport: Metallgehäuse, Parameterflächen (BPM/SWING/WIDTH) auf hellem Aluminium mit dunkler Schrift,
  BPM-Anzeigeglas, Gravurtrenner, plastische Tasten.
- WIDTH: horizontaler Materialfader (Griff 35×17, Riffelzonen, dunkler Mittelindex, Führungsschlitz,
  Marken 30/75/120), Hit-Fläche 30 pt hoch; gleiche Binding-Strecke (`StepWidthState.size`, 30…120, Schritt 1),
  Keyboard (←/→) und Accessibility (adjustable, Wert).
- Spuren: gleicher Modulrahmen für Step- und CC-Lane, versenktes Namensfeld, Richtungstasten und
  `VintageSmallButtonStyle`/`VintagePatternButtonStyle` als Kunststoff.
- Step-Taster: Kunststoff mit Aktivitäts-Tönung; Auswahl/Learn getrennte Überlagerung; Playback bleibt LED.
- Tests: `MaterialFaderMathTests` (5), `GUI01PlaybackLoadTests`, `GUI01SceneRenderTests` (Offscreen-Bilder).
- Bekannt/unverändert: Transport bricht bei 920 pt Mindestbreite Logo-/PATTERN-Text um (bestand vorher).

---

## [1.12.12] — 2026-10-20

### S01-R1 — Fehlerzustellung und Verifikation des Snapshot-Fixes (Round FOF-CX-2026-10-20-002)

- **StatusBar-Hinweis (H1):** Wird ein Tick wegen nicht erwerbbarem Snapshot abgebrochen,
  zeigt die Statusleiste orange „TIMING: n dropped“ / „TAKT: n ausgelassen“ (seit dem letzten
  Start). Im Normalbetrieb unsichtbar; kein Dialog, keine Eingabesperre. Der erste Fehler
  erscheint sofort, weitere Änderungen höchstens 1×/s (Zähler je Sitzung zurückgesetzt).
- **Tests (H2/M1):** `liveSwingRepublishDuringPlayback` auf Main-Writer-Vertrag umgestellt
  (@MainActor, beobachtet das publizierte Bundle, begrenzt 5 s, Diagnose in der Meldung).
  S01-Hooks werden nach jedem Test abgebaut, alle Semaphore-Waits sind begrenzt.
  Neu: `S01ErrorDeliveryTests` (echter Clock-Reader → StatusBar).
- DEBUG-Injektion `_s01ForceExhaustion` im unveränderten Erwerbsprotokoll.
- Release-Erwerb: Aufrufziel der swift-atomics-Accessoren geprüft (siehe ENGINEERING).

---

## [1.12.11] — 2026-10-20

### S01 — Snapshot-Lesepfad auf jedem Ausgang absichern (Round FOF-CX-2026-10-20-001)

Schließt Befund B1: Nach mehr als acht gescheiterten Hazard-Revalidierungen
dereferenzierte `advanceSteps` den zuletzt gelesenen, nicht im Hazard
gemeldeten Pointer (Use-after-free-Fenster bei Publish-Bursts).

- Erwerb als eigene, beschränkte Funktion `acquireSnapshot()`: höchstens
  9 Durchläufe, Dereferenzierung nur nach Melden + Validieren. Erschöpfung
  ist ein definierter Erwerbsfehler, kein Fall-through.
- Erwerbsfehler (und fehlendes Bundle) brechen den Gesamttick ab: kein
  Mailbox-Drain, kein Pulse-/Step-/PRNG-Fortschritt, kein 0xF8/0xFA
  (`midiStartPending` bleibt gesetzt). Fehler werden atomar gezählt und im
  Display-Drain nach `clockDiagnostics.snapshotAcquireFailures` gespiegelt (ab 1.12.12 in der StatusBar sichtbar).
- Speicherordnung: Hazard-Store/Validate-Load (Reader) und Publish-Store/
  Hazard-Load (Writer) sind jetzt `seq_cst` (Store-Buffering-Lücke von
  Release/Acquire geschlossen). `superseded` wird bis nach dem Hazard-Load gehalten.
- Verhaltensfolge: Drain läuft nach dem Erwerb; die Richtung des bekannten
  Ein-Tick-Versatzes Snapshot/Runtime (B3, S03) kehrt sich um.
- Kein Preset-Format- oder Clock-Quellen-Eingriff. Ungelöst: B2–B5.
- Tests: `S01SnapshotAcquireTests` (13 Testfälle).

---

## [1.12.10] — 2026-07-15

### RT-4c — sendRTSafe: atomarer Endpoint-Snapshot statt Trylock-Drop

Dritter Teil-Slice von RT-4, von Stephan per AskUserQuestion gewählt.
`MIDIManager.sendRTSafe()` las den gewählten Output-Endpoint über
`os_unfair_lock_trylock`. Scheiterte der Trylock (Main-Thread schreibt
gerade `selectedOutput`, Mikrosekunden-Fenster), wurde der Send für dieses
eine Event still übersprungen — bislang als „acceptable" hingenommener,
aber real stiller Datenverlust ohne Diagnose.

**Entscheidung:** `ManagedAtomic<MIDIEndpointRef>` statt Lock — ein
einzelnes 32-Bit-Wort kann nicht zerreißen, Store/Load sind wait-free und
schlagen nie fehl. Der Drop-Pfad ist damit kategorisch eliminiert, nicht
nur gezählt: `out == 0` bedeutet danach ausschließlich „kein Output-Gerät
gewählt", nie mehr „Lock war kurz contended". Selbes Muster wie RT-1
(`isPlaying`/`clockMode`/`queuedPatternIndex`).

**Geändert:**
- `Engine/MIDIManager.swift`: `import Atomics` statt `import os`;
  `_rtOutput`/`_rtOutputLock` → `rtOutputAtomic`; `selectedOutput`s
  `didSet` und `sendRTSafe()` auf Store/Load umgestellt. DEBUG-Hook
  `_rt4cReadOutputAtomic()`.
- `MIDIManagerRTSafeTests.swift` (neu, 3 Tests): Atomic-Mirror-
  Synchronität, Zero-Erhalt bei keinem gewählten Gerät, und der
  eigentliche Regressionstest — unter paralleler Schreiblast auf
  `selectedOutput` (nie 0) liefert der atomare Read über 5000 Iterationen
  nie fälschlich 0.

**Scope-Fence:** `outPort`/`virtSrc`/`virtDst` (effektiv unveränderlich
nach `setup()`) und `send()` (Main-Thread-only, kein Kontentionsproblem)
unangetastet.

**Verifikation:** build-for-testing SUCCEEDED · `MIDIManagerRTSafeTests`
(3) grün · TSan über MIDIManagerRTSafeTests + RT-4b/RT-4a/RT-3b/RT-3a/
RT-3/RT-2/RT-1a sauber · voller Unit-Lauf: 395 passed, unverändert nur die
5 bekannten roten Tests · `git diff --check` sauber.

**Offen (Rest von RT-4, eigene Freigabe nötig):** `EngineEventBuffer` —
garantierte Zustellung von `patternSwitch`; RT-Nachweis für
DispatchSource-Wakeup dokumentieren.

---

## [1.12.9] — 2026-07-14

### RT-4b — RT-sicherer PRNG statt Int/Double.random im Tick-Pfad

Zweiter Teil-Slice von RT-4 (Hot-Path-Audit), von Stephan per
AskUserQuestion als nächster Teilschritt gewählt. Zwei Aufrufstellen von
Swifts Standard-Zufallszahlengenerator liefen unconditional auf jedem Tick
im RT-Pfad (`advanceRuntime()` — Random-Step-Direction; `advanceSteps()` —
Per-Step-Trigger-Probability). `Int/Double.random(in:)` nutzt implizit
`SystemRandomNumberGenerator`, auf Darwin über `arc4random_buf` — ein CSPRNG
ohne dokumentierte Alloc-/Lock-Freiheits-Garantie.

**Entscheidung:** eigener alloc-freier PRNG (xorshift64*, neue Datei
`Engine/RTRandom.swift`) statt CSPRNG-Wrapper oder eigenem Lock-freien Pool
— einfachster Ansatz ohne kryptografische Anforderungen, deterministisch
seedbar (test-freundlich), kein Heap, kein Syscall.

**Geändert:**
- `Engine/RTRandom.swift` (neu): xorshift64*-Struct (`next()`,
  `nextUnitDouble()`, `nextInt(bound:)`).
- `SequencerEngine.swift`: neues Feld `rtRandom` (Seed einmalig bei
  Konstruktion auf dem Main-Thread gezogen — nicht RT); Zeile 1454
  (`advanceRuntime`, `.random`-Zweig) und Zeile 1673 (`advanceSteps`,
  Probability-Gate) nutzen jetzt `rtRandom` statt `Int/Double.random`.
  Invariante wie `trackRuntimes` (RT-2): ausschließlich vom Audio-/
  MIDI-Read-Thread innerhalb des `activeTick`-Fensters mutiert, kein
  Atomic nötig. DEBUG-Hook `_rt4bSetRandomSeedForTest(_:)`.
- `RTRandomTests.swift` (neu): isolierte Struct-Tests (Bound-Einhaltung,
  Determinismus bei gleichem Seed, Seed-0-Sonderfall).
- `WorkflowEngineTests.swift`: neue `struct RT4bSeededRandomTests` (2
  Tests) — beweist über die echte Engine, dass beide Aufrufstellen
  konsistent dieselbe seedbare Quelle nutzen.

**Scope-Fence:** sechs weitere Random-Aufrufe im Projekt (Main-Only-Button-
Callbacks „Randomize CC Lane"/„Randomize Track") bleiben unangetastet —
nicht RT-pfad-erreichbar. `MockAdvanceRuntimeSource.swift` (Test-Doppel für
`AdvanceRuntimeTests.swift`) bleibt unverändert.

**Verifikation:** build-for-testing SUCCEEDED · `RTRandomTests` (6) +
`RT4bSeededRandomTests` (2) grün · `AdvanceRuntimeTests`-Familie unverändert
grün · TSan über RT-4b/RT-4a/RT-3b/RT-3a/RT-3/RT-2/RT-1a sauber · voller
Unit-Lauf: 392 passed, unverändert nur die 5 bekannten roten Tests · ein
transienter Malloc-Crash im ersten Vollauf (direkt nach dem TSan-Pass,
kaskadierte auf ~390 unbeteiligte Tests) reproduzierte sich im sofortigen
Wiederholungslauf nicht — deckt sich mit dem bestehenden PROJECT_LOG-Eintrag
zu Test-Artefakten nach TSan-/Host-Last, kein Codebug · `git diff --check`
sauber.

**Offen (Rest von RT-4, eigene Freigabe nötig):** `sendRTSafe` — atomarer
Endpoint-Snapshot statt Trylock-Drop; `EngineEventBuffer` — garantierte
Zustellung von `patternSwitch`; RT-Nachweis für DispatchSource-Wakeup
dokumentieren.

---

## [1.12.8] — 2026-07-14

### RT-4a — Catch-up-/Resync-Strategie formalisiert (intern vs. ausgehende 0xF8)

RT-3, RT-3a und RT-3b sind final abgenommen (Codex-Rücklauf Round
`FOF-CX-2026-07-14-007`: RT-3b akzeptiert, kein neuer Blocker). Erster
Teil-Slice von RT-4 (Hot-Path-Audit): die Catch-up-/Resync-Strategie für
verspätete Audio-Callbacks — bislang nur im Code kommentiert (Arch-Slice-15/
16b), jetzt als verbindliche Entscheidung getestet und dokumentiert.

**Entscheidung:** Kommt der Audio-Callback zu spät und `AudioClockSource`
feuert mehrere Catch-up-Ticks in einem Callback (Timestamps in der
Vergangenheit), gilt:
1. Der interne Step-/Note-Fortschritt (`advanceSteps()`) driftet nie — jeder
   Catch-up-Tick zählt, unabhängig davon, ob sein Timestamp geclampt wird.
2. Die ausgehende MIDI-Clock (0xF8) für geclampte Pulse wird still verworfen,
   nicht als Burst nachgeholt — ein kurzer ~100ms-Aussetzer beim
   Empfängergerät ist unauffälliger als ein hörbares Einhaken von dessen
   Arp-/LFO-/Delay-Takt beim gleichzeitigen Eintreffen mehrerer Pulse.

**Geändert:**
- `SequencerEngine.swift`: neuer DEBUG-Hook `_rt4ClampCountClock` (Test-Fenster
  auf den bestehenden `clampCountClock`-Zähler). Kein Produktionscode-Verhalten
  geändert — die Strategie war bereits implementiert (Arch-Slice-15/16b).
- `WorkflowEngineTests.swift`: neue `struct RT4ResyncStrategyTests` (2 Tests) —
  verifiziert beide Hälften der Entscheidung direkt über `clockTick(at:)`
  (deterministisch, ohne `AudioClockSource`).

**Testfund (Testcode, kein Produktionsbug):** Die feste `futureTick`-Konstante
(`1_000_000_000_000`) aus den bestehenden RT-1a-Tests ist auf Apple Silicon
(`mach_absolute_time()` ≈ ns seit Boot) nach ausreichender Systemlaufzeit
tatsächlich in der Vergangenheit — für die RT-1a-Tests irrelevant (die prüfen
nur, dass `advanceSteps()` unabhängig vom Clamp-Status läuft), hätte aber den
neuen Clamp-Zähler-Test verfälscht. `RT4ResyncStrategyTests` berechnet den
Future-Timestamp deshalb relativ zur echten `mach_absolute_time()` zur
Laufzeit.

**Verifikation:** build-for-testing SUCCEEDED · `RT4ResyncStrategyTests` (2)
grün · TSan über RT-4a/RT-3b/RT-3a/RT-3/RT-2/RT-1a sauber · voller Unit-Lauf:
381 passed, unverändert die 5 bekannten roten Tests plus 3 dokumentierte
spuriöse `measure`-Baseline-Artefakte unter Parallel-Last (kein Codebug,
s. bestehender PROJECT_LOG-Eintrag) · `git diff --check` sauber.

**Offen (Rest von RT-4, eigene Freigabe nötig):** eigener PRNG statt
`Int/Double.random`; `sendRTSafe` — atomarer Endpoint-Snapshot statt
Trylock-Drop; `EngineEventBuffer` — garantierte Zustellung von
`patternSwitch`; RT-Nachweis für DispatchSource-Wakeup dokumentieren.

---

## [1.12.7] — 2026-07-14

### RT-3b — Fail-Safe Deferred Cleanup (Korrektur zu RT-3a, schließt Codex-Befund H3)

Codex-Rücklauf (Round `FOF-CX-2026-07-14-006`): RT-3a (v1.12.6, Commit
`60ab41b`) war **nicht abgenommen** — Blocker H3. Der 2-Sekunden-Backstop im
Sync-Spin führte den Teardown (`atomicBundleRaw`/`bundleCurrent`/
`bundleDeferred`/`trackRuntimes`/`runtimeCommands`) trotzdem durch, sobald er
erreicht wurde — auch wenn `activeTick` zu diesem Zeitpunkt noch `true` war.
Das ist Codex-Befund H2 in anderer Form: ein Tick, der (Scheduler-Preemption,
Debugger-Pause, Host-Last) länger als 2 s braucht, ließ `stop()` genau die
Strukturen freigeben, die RT-3a eigentlich schützen sollte.

**Fail-Safe statt Backstop-Durchbruch:** `activeTick == true` bedeutet jetzt
hart, auf jedem Pfad — auch dem Timeout-Pfad —, dass Main nichts freigibt.
Ein neuer Sync-Spin (150 ms, deutlich kürzer als der frühere 2-s-Wert, weil
die genaue Dauer jetzt unkritisch für die Sicherheit ist) deckt den
Normalfall ab; erreicht er seine Deadline, wird der Teardown auf einen
Main-seitigen Async-Retry (`DispatchQueue.main.asyncAfter`, ~20-ms-Takt)
verschoben, bis `activeTick` wirklich `false` ist. `play()`/
`startFromExternal()` dürfen währenddessen keine neue Session starten (sonst
überlappt sie mit dem noch laufenden alten Tick — dieselbe Race eine Ebene
höher) und lehnen einen Start ab, statt RT-State zu korrumpieren.

**Geändert:**
- `stop()`: Inline-Teardown ersetzt durch `awaitActiveTickQuiescence()` (150 ms
  Sync-Spin) → `teardownRTState()` bei Erfolg, sonst
  `scheduleDeferredRTStateCleanup()` (Fail-Safe).
- `play()`/`startFromExternal()`: Guard gegen einen noch ausstehenden
  Deferred-Cleanup aus einem vorherigen `stop()`.
- Neues `stopCleanupPending`-Feld (Main-only, GCD-serialisiert — kein Atomic
  nötig, da alle Aufrufer auf Main laufen).

**RT-Pfad-Bestätigung:** unverändert — `advanceSteps()` selbst (activeTick-
Store/Defer aus RT-3a) wurde nicht angefasst; der Fix ist rein Main-seitig,
kein Lock/Alloc/Retain im Tick-Pfad.

**Tests:** `RT3bDeferredCleanupTests` (2: `stop()` kehrt über den Fail-Safe-
Pfad zurück, ohne die RT-Strukturen unter einem noch aktiven Tick
freizugeben; `play()` lehnt einen Start ab, solange ein Cleanup aussteht,
und startet normal, sobald er abgeschlossen ist). `RT3aStopQuiescenceTests.
stopBlocksUntilInFlightExternalTickExits` umgebaut: prüft jetzt den Zustand
direkt statt sich auf `stop()`s Rückkehr-Timing zu verlassen — robust
gegenüber der genauen Backstop-Dauer. TSan über RT-3b/RT-3a/RT-3/RT-2/RT-1a/
Pattern sauber (mehrfach wiederholt). Dabei zwei **vorbestehende**,
unabhängige TSan-Funde in `RT1aModeSwitchTests` behoben
(`liveSwingRepublishDuringPlayback`, `rapidModeToggleUnderPlayback`): beide
riefen `engine.stop()` direkt aus einem Nicht-Main-Testkontext auf, was mit
Main-seitiger Publish-Aktivität (Swing-Republish bzw. clockMode-Sink)
kollidieren kann — `activeTick` deckt nur den RT-/MIDI-Reader ab, nicht einen
zweiten Main-Schreiber. Beide Tests dispatchen `stop()` jetzt korrekt auf
Main. Voller Unit-Lauf: 382 passed, unverändert 5 bekannte rote Tests.

**Unverändert / bewusst außerhalb:** RT-4-Hot-Path-Audit, UI-/Usability-
Redesign, MIDIManager-/AudioClockSource-Redesign, PRNG/Random-Mode,
Preset-Format.

---

## [1.12.6] — 2026-07-14

### RT-3a — Stop-/External-Clock-Quieszenz (Korrektur zu RT-3, schließt Codex-Befund H2)

Codex-Rücklauf (Round `FOF-CX-2026-07-14-005`): RT-3 (v1.12.5, Commit
`5c0bb94`) war **nicht abgenommen** — Blocker H2. `stop()` riss Hazard-Pointer,
Bundle-Box-Referenzen und `trackRuntimes` bedingungslos ab. Das
Sicherheitsargument („`audioClock.stop()` hat synchron geblockt") gilt nur für
den **internen** Clock-Thread. Ein externer MIDI-Tick
(`tick(scheduledAt:)`, direkt aus `midi.onClockPulse` auf dem CoreMIDI-Read-
Thread, nicht über Main dispatcht) kann den `isPlayingRT`-Guard schon
passiert haben und noch in `advanceSteps()` laufen, während `stop()`
gleichzeitig auf Main den Hazard fremd löscht, die Bundle-Box dealloziert und
`trackRuntimes` leert → Use-after-free bzw. Data-Race auf dem externen Pfad.

**Quieszenz-Beweis statt Zeitannahme:** neues `activeTick`-Atomic
(`ManagedAtomic<Bool>`), das die **gesamte** `advanceSteps()`-Funktion umschließt
(Mailbox-Drain + Hazard-Fenster) — unabhängig vom internen oder externen
Clock-Pfad. `stop()` wartet per bounded Spin (`sched_yield()`, Backstop 2 s) auf
`activeTick == false`, bevor es Snapshot-Box/`trackRuntimes`/Mailbox anfasst.
`stop()` schreibt `hazardBundleRaw` nicht mehr selbst — nur der Reader löscht
seinen eigenen Hazard; nach bewiesener Quieszenz ist er ohnehin bereits 0
(DEBUG-`assert` prüft das).

**Geändert:**
- `advanceSteps()`: `activeTick.store(true, .releasing)` + `defer { … false }`
  als allererste Zeilen — läuft dank Swift-Defer-LIFO garantiert nach dem
  bestehenden Hazard-Clear.
- `stop()`: bounded Spin-Wait auf `activeTick`, kein `hazardBundleRaw.store(0)`
  mehr (nur DEBUG-Assert).
- DEBUG-Hooks `_rt3aPausePoint`, `_rt3aActiveTick`,
  `_rt3aDriveOneExternalTick(at:)`.

**RT-Pfad-Bestätigung:** 2 zusätzliche atomare Bool-Stores pro Tick, kein
Lock/Alloc/Retain — gleiche Kategorie wie der bestehende Hazard-Mechanismus.

**Tests:** `RT3aStopQuiescenceTests` (2: `stop()` blockt, solange ein
geparkter externer Tick aktiv ist — Snapshot-Box und `trackRuntimes` bleiben
währenddessen unangetastet; `stop()` kehrt ohne aktiven Tick praktisch sofort
zurück). Thread-Sanitizer über RT-3a/RT-3/RT-2/RT-1a/Pattern/Transport inkl.
des neuen, echten externen Stop-Races: sauber.

**Unverändert / bewusst außerhalb:** RT-4-Hot-Path-Audit, UI/Usability,
MIDIManager-/AudioClockSource-Redesign, PRNG/Random-Mode, Preset-Format,
`publishSnapshot()` und der bestehende Hazard-Mechanismus für Bundle-Boxen.
Die 5 bekannten roten Legacy-/RubberBand-Tests bleiben unverändert.

---

## [1.12.5] — 2026-07-14

### RT-3 — Snapshot-Lebensdauer formal garantiert (Hazard-Pointer)

Schließt Codex-Befund #2. Der Audio-Thread liest den Playback-Zustand lock-frei
über einen rohen Pointer auf eine `PlaybackBundleBox` und hält ihn über den
**ganzen Tick**. Die Lebensdauer sicherte bisher ein Triple-Slot-ARC-Fenster,
dessen Garantie rein **zeitlich** war („älteste Box frühestens nach ≥33 ms
frei"). Wird der Audio-Thread mitten im Tick preemptiert und publiziert der
Main-Thread in diesem Fenster ≥3-mal, konnte die gehaltene Box freigegeben
werden, während sie noch dereferenziert wird → Use-after-free.

**Formale Absicherung (harte Garantie):** Es gibt genau einen Audio-Leser
(`advanceSteps`). Er meldet die aktuell benutzte Box vor dem Dereferenzieren in
einem Hazard-Pointer (mit Re-Validierung gegen den publizierten Pointer) und
gibt sie am Tick-Ende frei. `publishSnapshot()` dealloziert eine Box nie,
solange der Hazard auf sie zeigt — sie wird höchstens einen Zyklus aufgeschoben.
Die Garantie ist damit preemptions-unabhängig statt zeitbasiert.

**Geändert:**
- Triple-Slot-Fenster (`bundleSlot0/1/2`) ersetzt durch `hazardBundleRaw`
  (Atomic) + `bundleCurrent`/`bundleDeferred` (max. eine aufgeschobene Box, da
  Single-Reader).
- `advanceSteps`: Announce + Re-Validate am Tick-Anfang, Hazard-Clear per `defer`.
  Audio-Kosten: 2 atomare Stores + 1 Re-Validate-Load pro Tick, kein Lock/Alloc/
  Retain.
- `publishSnapshot`/`stop`: aufgeschobene Freigabe bzw. Aufräumen.

**Verhalten:** unverändert. Publish-Aufrufstellen und -Timing bleiben gleich —
der Hazard-Pointer macht auch rapide Publish-Bursts sicher.

**Tests:** `RT3SnapshotLifetimeTests` (5: aufgeschobene Freigabe bei aktivem
Hazard via weak-Sonde; sofortige Freigabe ohne Hazard; Tick dereferenziert die
aktuelle Box und räumt den Hazard; rapide Publishes gegen den echten
AudioClock-Thread; stop()-Cleanup). Thread-Sanitizer über RT-3/RT-2/RT-1/
Pattern/Transport inkl. echtem Audio-Thread-Race: sauber.

**Unverändert / bewusst außerhalb:** Snapshot-Inhalt/D9-Immutabilität,
RT-2-Mailbox, Ring-Buffer/Display-Wakeup, MIDIManager, AudioClockSource, RNG,
Preset, UI. Das Koaleszieren-Alternativ aus Codex #2 wurde bewusst nicht
genommen (der Hazard-Pointer gibt eine harte Garantie, Koaleszieren nur eine
Wahrscheinlichkeitssenkung). Die 5 bekannten roten Legacy-/RubberBand-Tests
bleiben unverändert.

---

## [1.12.4] — 2026-07-14

### RT-2 — `trackRuntimes`-Ownership: Struktur-Mutation während Playback ist race-frei

Schließt Befund K1 (Code-Review 2026-07-13), den nächsten crashfähigen
Release-Blocker nach RT-1/RT-1a. Bisher fasste der Main-Thread das
`trackRuntimes`-Array beim Hinzufügen/Einfügen/Duplizieren/Wiederherstellen/
Entfernen von Tracks und beim quantisierten Patternwechsel direkt an —
während der Audio-Thread dasselbe Array in jedem Tick liest und fortschreibt.
Das konnte zu Use-after-free (Array-Reallokation unter dem Audio-Thread),
Index-Verschiebung (Cursor am falschen Track) und Snapshot-Mismatch führen.

**Owner-Regel (neu, code-durchgesetzt):** Ab `play()` ist der Audio-Thread
alleiniger Mutator von `trackRuntimes`. Main/UI schreibt es während Playback
nicht mehr direkt, sondern reicht Strukturänderungen als RT-sichere Commands
über eine lock-freie SPSC-Mailbox (`RuntimeCommandBuffer`) ein; der
Audio-Thread wendet sie am Tick-Anfang selbst an.

**Geändert:**
- Neue Datei `RuntimeCommandBuffer.swift` (lock-freier Main→Audio-SPSC-Ring,
  atomare Head/Tail-Indizes, `insert`/`remove`/`resetAll`).
- `advanceSteps` drained die Mailbox vor dem Snapshot-Read. `play()`/
  `startFromExternal()` reservieren die Runtime-Kapazität vor — die
  Anwendung im RT-Pfad ist so realloc- und allokationsfrei.
- Alle Struktur-Mutatoren und `applyPatternSwitch` reihen Commands ein statt
  `trackRuntimes` direkt zu mutieren.

**Verhalten:** unverändert. Worst Case beim Umbau ist ein Ein-Tick-Versatz
zwischen Snapshot und Runtime-Zahl — nie ein Crash, nie ein Cursor am
falschen Track; im Folgetick konsistent.

**Tests:** `RT2RuntimeOwnershipTests` (5: Add konsistent; Insert/Remove an
korrekter Position mit erhaltenen Nachbar-Cursorn; Patternwechsel baut
Runtimes konsistent neu auf; schnelle Strukturmutation unter laufender
interner Clock). Thread-Sanitizer über RT-2/RT-1/Pattern/Transport inkl.
echtem Audio-Thread-Race: sauber.

**Unverändert / bewusst außerhalb (siehe ROADMAP Phase 1):**
Triple-Slot-Lifetime (RT-3), Display-Wakeup/Ring-Buffer, MIDIManager,
AudioClockSource, RNG, UI, Preset-Format. Die 5 bekannten roten Legacy-/
RubberBand-Tests bleiben unverändert.

---

## [1.12.3] — 2026-07-14

### RT-1a — Atomare Modusumschaltung: Clock und Steps bleiben auf einer Pulsfolge

Folge-Slice zu RT-1 (Codex-Befund H1). Beim Clock-Moduswechsel konnte der
interne Sequencer einen Puls fortschreiten, den das externe Gerät nie
erhielt: Die Computed-Setter schrieben zuerst das `@Published`-Objekt und
erst danach den atomaren Spiegel. Der `$clockMode`-Sink startet die
AudioClock aber synchron im `willSet` — ein erster `clockTick` konnte so
`clockIsInternal` noch im alten Zustand sehen und `advanceSteps` ausführen,
während der ausgehende 0xF8-Puls verworfen wurde. Kein hörbares Verhalten
im stationären Betrieb; die Änderung schließt das Umschalt-Zeitfenster.

**Geändert:**
- Computed-Setter `isPlaying`, `clockMode`, `queuedPatternIndex` schreiben
  den atomaren Spiegel jetzt VOR dem `@Published`-Write
  (Producer-before-observer). Für `clockMode` ist die Reihenfolge zwingend.
- `clockTick` wertet den INT-Guard VOR `advanceSteps` aus: ein verspäteter
  Tap nach INT→EXT schreitet weder den Step fort noch sendet er MIDI.

**Tests:** `RT1aModeSwitchTests` (5 Tests: clockTick advanciert nur im
INT-Modus; verspäteter Tap nach EXT advanciert nicht; Atomic-Konsistenz
über beide Richtungen; Live-Swing-Republish während Playback, async).
Thread-Sanitizer über schnelle INT→EXT→INT-Wechsel unter Playback: sauber.

**Unverändert / bewusst außerhalb (siehe ROADMAP Phase 1):**
`trackRuntimes`-Ownership (K1 / RT-2), Triple-Slot-Lifetime (RT-3),
Ring-Buffer, MIDIManager, RNG, Display-Wakeup, UI, Preset-/Clock-Quelle.
Die 5 bekannten roten Legacy-/RubberBand-Tests bleiben unverändert.

---

## [1.12.2] — 2026-07-14

### RT-1 — Playback-State-Ownership: keine @Published-Reads mehr im Audio-Thread

Der Audio-/Clock-Thread las bisher `swing`, `clockMode`, `isPlaying` und
`queuedPatternIndex` direkt aus den `@Published`-Objekten — Cross-Thread-
Datenrennen. Diese Reads laufen jetzt über das atomar publizierte
`PlaybackStateBundle` bzw. dedizierte Atomics. Kein hörbares Verhalten
ändert sich; die Änderung schließt formale Races im Tick-Pfad.

**Geändert:**
- `PlaybackStateBundle` trägt neu `swing`; `advanceSteps` liest
  `bundle.swing`. Republish bei Swing-Änderung über neuen
  `presetEditorState.$swing`-Sink (koalesziert).
- Atomare Spiegel `queuedPatternAtomic` (Sentinel −1), `clockIsInternal`,
  `isPlayingRT` — geschrieben ausschließlich über die Computed-Setter,
  gelesen im Audio-/MIDI-Read-Thread (`advanceSteps`, `clockTick`,
  `tick`, `onClockPulse`, `onStop`, `startFromExternal`).
- Toter Zweig `if clockMode == .internal { midi.clock() }` in `tick()`
  entfernt (unerreichbar — `tick()` läuft nur im EXT-Pfad).

**Tests:** `RT1PlaybackStateOwnershipTests` (5 Tests: Bundle trägt
bpm/swing, Atomic-Spiegel für isPlaying/clockMode/queuedPatternIndex).
Thread-Sanitizer-Lauf über Transport-/Pattern-/RT-1-Tests: sauber.

**Unverändert / bewusst außerhalb (siehe ROADMAP Phase 1):**
`trackRuntimes`-Ownership (K1), Triple-Slot-Lifetime, Ring-Buffer,
MIDIManager, RNG im Hot-Path, UI, Preset-Format. Die 5 bekannten roten
Legacy-/RubberBand-Tests bleiben unverändert (Entscheidung offen,
ROADMAP Phase 0.2).

---

## [1.12.1] — 2026-04-18

### Track-Farben — UX-Korrektur: Farbwahl im Kontextmenü

Der farbige 6×6-Punkt im Track-Header ist als Klickziel zu klein und
verhielt sich bei CC-Tracks nicht zuverlässig. Die Farbwahl wandert
in das bestehende Track-Kontextmenü; der Header-Punkt bleibt reine
Anzeige.

**Geändert:**
- `TrackHeaderView`: Farbpunkt wieder als reine `Circle()`-Anzeige
  (kein Menu, kein Button). `TrackColorMenu`-Sub-View entfernt.
- `TrackRowView.trackContextMenu`: neuer Untermenü-Eintrag
  „Track Color" mit den 8 Paletteneinträgen, Checkmark auf der
  aktuellen Farbe. Funktioniert für Step- und CC-Tracks gleich,
  da das Kontextmenü bereits über `TrackSideHeaderView` für beide
  Lane-Typen am Spurkopf liegt.
- `Str.trackColorMenu` hinzugefügt (EN: „Track Color",
  DE: „Spurfarbe").

**Unverändert:** `TrackData.colorIndex`, `ModelCommand.setTrackColorIndex`,
`ModelWriter`, `VintageTheme.color(forTrack:)`,
`SequencerEngine.firstFreeColorIndex(in:)`, alle Tests — reiner UI-Umbau.

---

## [1.12.0] — 2026-04-18

### Track-Farben-Slice — Persistente, frei wählbare Track-Farbe

Die Track-Akzentfarbe (bisher rein aus dem Index abgeleitet, nicht persistent
und nicht änderbar) ist jetzt ein benutzersteuerbares, gespeichertes Attribut
des Tracks. Die Farbe ist Eigenschaft des Tracks; Lanes haben **keine** eigene
Farbe und erben die Track-Farbe ausschließlich per Parameter-Durchreich.

**Hinzugefügt:**
- `VintageTheme.color(forTrack:)` — einziger Resolver-Ort für
  `colorIndex → Color`, aufgerufen ausschließlich in `MainView`.
- `ModelCommand.setTrackColorIndex` + `ModelWriter`-Handler mit Undo/Redo.
- `TrackColorMenu` in `TrackHeaderView`: der vorhandene 6×6-Farbpunkt ist
  jetzt ein Menu-Trigger mit 8 Paletteneinträgen, Checkmark markiert die
  aktuelle Farbe; das Layout bleibt unverändert.
- `SequencerEngine.firstFreeColorIndex(in:)` — neue Tracks bekommen die
  kleinste freie Palettenfarbe statt `count % palette`; `addTrack` und
  `insertTrack` nutzen den Helfer.

**Geändert:**
- `MainView` reicht `accentColor: Color` (bereits aufgelöst) an
  `TrackRowView` durch — keine weitere Stelle löst den Index selbst auf.

**Tests:**
- `UndoRedoTests.setTrackColorIndexUndoRedo` — Undo/Redo-Symmetrie.
- `UndoRedoTests.addTrackPicksSmallestFreeColorSlot` — Slot-Allokation
  nach Löschungen deterministisch kleinster freier Index.
- `TrackCodableTests.roundtrip` — `colorIndex` überlebt JSON-Roundtrip.

**Preset-Format:**
- `colorIndex` ist seit v1.9.1 Bestandteil von `TrackData` (Codable);
  kein Format-Bruch, keine Migration nötig.

---

## [1.11.0] — 2026-04-18

### Step-Lane-Purify P3 — Codable-Altlasten aus dem Modell entfernt

Abschluss der Step-Lane-Purify-Serie. **Preset-Format-Änderung (vorwärts
bereinigt, rückwärtstolerant).** Alte Presets laden weiterhin fehlerfrei —
die entfernten Keys werden beim Decodieren stillschweigend ignoriert.

**Removed (Modell):**
- `Step.cc1Value`, `Step.cc2Value` (Felder + `CodingKeys` + Encode/Decode).
- `TrackData.cc1Number`, `cc2Number`, `cc1Label`, `cc2Label`,
  `cc1IsMuted`, `cc2IsMuted` (Felder + `CodingKeys` + Encode/Decode).
- Zugehörige Propagation in `TrackData.freshCopy()` und
  `clampToValidRanges()`.

**Removed (Tests):**
- `PresetIOTests.roundtrip()` — direkte Property-Zugriffe auf die
  entfernten Felder (`cc1Number`, `cc2Number`, `cc1Label`, `cc2Label`,
  `cc1IsMuted`, `cc2IsMuted`, `step.cc1Value`, `step.cc2Value`).
- `PresetIOTests.outOfRangeValuesAreClamped()` +
  `validValuesAreUnchangedByClamp()` — `cc1Number`/`cc2Number`-Zweige
  entfernt.

**Geändert (Tests, Scope-Creep aus P2):**
- `MockAdvanceRuntimeSource.TrackSnapshot.forTest` — Aufruf an die
  aktuelle `LaneSnapshot`-API angepasst (`payload: .step(steps:)` statt
  veralteter `steps:`/`stepCount:`-Flachform aus der Zeit vor Lane
  Slice 6) und die vier Legacy-CC-Argumente an `TrackSnapshot(...)`
  (seit P2 nicht mehr vorhanden) entfernt. Das Test-Target war seit
  P2 (bzw. teilweise seit Lane Slice 6) nicht mehr kompilierfähig —
  wurde mit P3 zusammen reaktiviert, damit `xcodebuild test`
  wieder läuft.

**Bewusst beibehalten (Backward-Compat):**
- JSON-Fixture-Strings in `PresetIOTests` und `WorkflowEngineTests`,
  die die Legacy-Keys `cc1Number`/`cc2Number`/… enthalten, bleiben
  unverändert. Da Swifts `KeyedDecodingContainer` unbekannte Keys
  default-mäßig ignoriert, laden diese Fixtures weiterhin fehlerfrei
  — und dokumentieren genau diese Rückwärtstoleranz.

**Explizit nicht Teil von P3 (eigene UX-Slice):**
- `CCRowView`-Speaker-Symbol (Lane-scoped Mute-Toggle auf
  `lane.ccIsMuted`). Bleibt bewusst unangetastet — redundant zur
  Track-Mute-Schaltfläche im 1-Track-1-Lane-Modell, semantisch aber
  nicht deckungsgleich (Lane-Scope vs. Track-Scope). Entscheidung
  über Entfernung/Umbenennung gehört in eine saubere UX-Slice, nicht
  in einen Codable-Purify.

**Preset-Kompatibilität:**
- Neue Writes enthalten die entfernten Keys nicht mehr.
- Alte Reads funktionieren unverändert (unbekannte Keys werden
  ignoriert, keine Migration nötig).

**Version:** 1.10.1 → 1.11.0 (MINOR — Preset-Format entwickelt sich,
bleibt aber rückwärtskompatibel).

---

## [1.10.1] — 2026-04-18

### Step-Lane-Purify P2 — Abbau toter Read-/Command-/UI-Pfade

Rein interne Bereinigung. **Keine Verhaltens- oder Preset-Format-Änderung.**
Entfernt werden ausschließlich Pfade, die nach P1 bereits wirkungslos waren.

**Removed (Runtime / Snapshot):**
- `TrackSnapshot.cc1Number`, `cc2Number`, `cc1IsMuted`, `cc2IsMuted`
  (aus `PlaybackSnapshot.swift`).
- Entsprechende Argumentübergabe in `SequencerEngine.buildPatternSnapshot()`.

**Removed (Command-Schicht):**
- `ModelCommand.setCC1Muted`, `ModelCommand.setCC2Muted`
  (inklusive `undoActionName`-Einträge).
- Zugehörige Handler in `ModelWriter.apply(_:undoManager:)`.

**Removed (ViewModel):**
- `TrackViewModel.cc1IsMuted`, `cc2IsMuted`
- `TrackViewModel.cc1Label`, `cc2Label`
- `TrackViewModel.cc1Number`, `cc2Number`

**Removed (UI):**
- `SettingsView` → „CC ASSIGNMENTS (per track)"-Sektion vollständig
  entfernt inkl. privatem `TrackCCRow` (Labels + Stepper auf
  `track.cc1Number`/`cc2Number`). Die Bedienelemente hatten seit P1
  keine Wirkung mehr.
- Datei `Views/CCLabelRowView.swift` gelöscht (seit P1 ohne Caller).
- Veralteter Kommentarverweis in `TrackRowView.swift` entfernt.

**Bewusst nicht entfernt (bleibt für P3 — Codable-Purify):**
- `Step.cc1Value`, `Step.cc2Value` (Modellfelder + Codable-Keys).
- `TrackData.cc1Number/cc2Number/cc1Label/cc2Label/cc1IsMuted/cc2IsMuted`
  (Modellfelder + Codable-Keys).
- `PresetIOTests`-Pfade, die genau diese Felder prüfen.

**Preset-Kompatibilität:** unverändert. Das On-Disk-Format ist
bitgleich zu v1.10.0 — alle bestehenden Presets laden und speichern
ohne Migration.

**Version:** 1.10.0 → 1.10.1 (PATCH, reine interne Bereinigung ohne
funktionale Änderung).

---

## [1.10.0] — 2026-04-18

### Step-Lane-Purify P1 — Per-Step-CC aus Step-Lanes entfernt

**Breaking change im Produktverhalten.** Step-Lanes (`LaneKind.step`)
sind ab dieser Version reine Noten-/Step-Lanes. Die bisherige
Möglichkeit, pro Step zwei CC-Werte (CC1/CC2) einzuzeichnen und
mitzusenden, wurde ersatzlos entfernt.

**Vorgesehener Ersatzpfad:** CC-Verläufe werden ausschließlich über
eigene CC-Lanes (`LaneKind.cc`) modelliert. Diese stehen seit 1.8.0
zur Verfügung und sind jetzt der einzige CC-Pfad.

**Nutzerseitig sichtbar:**
- Step-Lanes senden keine CCs mehr — auch nicht aus Presets, die
  noch Per-Step-CC-Daten enthalten. Die Daten werden geladen, aber
  nicht mehr interpretiert (tote Altlast, Entfernung in P2 geplant).
- Die zwei CC-Knob-Reihen rechts unter der Step-Lane sind entfernt.
- Die zwei CC-Label-/Mute-Reihen links unter dem Track-Header sind
  entfernt.
- Der Expand/Collapse-Chevron an der rechten Track-Seite ist entfernt
  (es gibt nichts mehr zum Expanden).
- Im Step-Editor (`StepDetailView`) sind die CC1/CC2-Knobs entfernt.
- „Randomize" erzeugt keine zufälligen CC-Werte mehr in Step-Lanes.

**Code / Technik:**
- `SequencerEngine.advanceSteps()`: Per-Step-CC-MIDI-Emission im
  Step-Zweig entfernt. Der CC-Lane-Zweig ist unverändert.
- `SequencerEngine.buildPatternSnapshot()`: befüllt die Step-CC-
  Felder nicht mehr.
- `PlaybackSnapshot.swift`: `StepSnapshot.cc1Value` / `cc2Value`
  entfernt. RT-Snapshot ist jetzt strukturell frei von Step-CC.
- `SequencerEngine+MIDILearn.swift`: `randomize()` setzt keine
  Step-CC-Werte mehr.
- Views entfernt: `TrackCCKnobSectionView.swift`, `CCRowView.swift`
  (enthielt `CCKnobRowView`), `TrackCCSectionView.swift`.
- `TrackRowView`, `TrackSideHeaderView`, `LaneBodyView`, `StepGridView`:
  `cc1DrawMode` / `cc2DrawMode` Bindings + CC-Sektionen entfernt.
- Tests: `StepSnapshot.testDefault` ohne CC-Felder;
  `PresetIOTests` bleibt unverändert (verifiziert weiterhin
  Codable-Round-Trip der noch erhaltenen Step-CC-Datenfelder).

**Bewusst NICHT in P1 enthalten:**
- `Step.cc1Value` / `cc2Value` bleiben im Modell und Codable → keine
  Preset-Formatänderung. Altpresets laden ohne Throw.
- `TrackData.cc1Number/Label/IsMuted`, `cc2*` bleiben auf dem
  Container.
- `TrackSnapshot.cc1Number/cc2Number/cc1IsMuted/cc2IsMuted` bleiben.
- `LaneData.ccValues/ccNumber/ccLabel/ccIsMuted` bleiben (Slice-6-
  Übergangsform).
- `ModelCommand.setCC1Muted` / `.setCC2Muted` und zugehörige Writer-
  Pfade bleiben.
- `CCLabelRowView.swift` **bleibt**, ist nach P1 aber ungenutzt.

Der Abbau dieser toten Datenschicht erfolgt planmäßig in P2/P3.

---

## [1.9.1] — 2026-04-18

### Slice A — Persistente Trackfarbe + monotone Tracknamen

Bugfamilie „Position statt Identität" behoben: Trackfarben und
Track-Namen hingen bisher an der Array-Position und wanderten beim
Löschen/Einfügen anderer Tracks. Beide Größen sind jetzt an die
Track-Identität gebunden.

- **`Models/TrackData.swift`**: neues persistentes Feld
  `colorIndex: Int`. Wird beim Erzeugen eines Tracks gesetzt und
  bleibt über Löschen/Einfügen anderer Tracks stabil. Codable
  rückwärtskompatibel: fehlt das Feld in Legacy-Presets, wird
  Sentinel `-1` dekodiert und im Pattern-Decoder positionsbasiert
  nachgepatcht.
- **`Models/Pattern.swift`**: neuer monotoner Zähler
  `nextTrackOrdinal: Int`. Wird bei jeder Track-Erzeugung gelesen
  und inkrementiert. Keine `count+1`-Ableitung mehr → keine
  Namenskollisionen nach Löschungen. Codable: Legacy-Default
  `max(maxExtractedOrdinal, tracks.count) + 1`.
- **`Engine/SequencerEngine.swift`** — `addTrack` / `insertTrack`:
  nutzen `pattern.nextTrackOrdinal` für den Namen und
  `pattern.tracks.count % palette` für `colorIndex`.
- **`Views/MainView.swift`**: `accentColor` liest jetzt
  `td.colorIndex` statt des laufenden `idx`.
- **`freshCopy()`**: übernimmt `colorIndex` — der Duplikat-Track
  behält bewusst die Farbe des Originals (visuelle Gruppierung).
- **Scope-Fence eingehalten**: Mute-Pfade unberührt. Solo, Theme,
  Lane-Farben, Preset-Format (strukturell), Undo/Redo,
  `ModelWriter`, `ModelCommand` und Views jenseits von MainView
  nicht angetastet.

---

## [1.9.0] — 2026-04-18

### Lane Slice 6 — Snapshot-Payload als discriminated union

Typsichere Umstellung der RT-Boundary. Kein UI-Impact, kein Preset-
Impact, keine Undo-/Redo-Änderung, kein Umbau von `LaneData`,
`ModelCommand`, `ModelWriter` oder Views. Die pragmatische Payload-
Mischform auf `LaneData` bleibt bewusst bestehen — sie ist nicht mehr
auf den Audio-Thread durchgereicht.

- **`Engine/PlaybackSnapshot.swift`**: neuer Enum
  `LaneSnapshotPayload` mit Cases `.step(steps:)` und
  `.cc(values:number:isMuted:)`. `LaneSnapshot` schlank umgebaut:
  trägt nur noch `kind`, `stepCount`, `direction`, `pulsesPerStep`,
  `payload`. Flache Sentinel-Felder (`steps`, `ccValues`, `ccNumber`,
  `ccIsMuted`) entfernt. D9-Immutabilität strukturell erhalten — alle
  assoziierten Werte sind Werttypen mit `let`-Semantik.
- **`Engine/SequencerEngine.swift`** — `buildPatternSnapshot()`: beide
  Kind-Cases konstruieren jetzt das passende `payload`. Clamp-Logik
  unverändert.
- **`Engine/SequencerEngine.swift`** — `advanceSteps()`: switcht auf
  `trackSnap.lane.payload`. CC-Zweig liest CC-Werte direkt aus dem
  Case-Binding; Sentinel-Guards gegen leere `ccValues`/`steps`-Arrays
  entfallen. Step-Zweig strukturell unverändert — nur ein
  `guard case let .step(laneSteps) = …`-Auspack-Einstieg, restlicher
  Step-Pfad 1:1 wie vorher.
- **`LaneSnapshot.kind`** bleibt bewusst erhalten als schneller
  Diskriminator für Nicht-Hot-Path-Code (Display/Logging).
- **`VERSION`**: 1.8.2 → 1.9.0 (MINOR — strukturelle RT-Boundary-Änderung,
  auch wenn nach außen unsichtbar).

---

## [1.8.2] — 2026-04-18

### CC-Lane Slice 1.2 — Kurven-Visual-Refinement

Rein visuelle Nachschärfung der CC-Kurve. Kein Funktionsumfang, kein
Datenmodell, kein Draw-/Knob-/Undo-Verhalten geändert.

- **`Views/CCLaneBodyView.swift`**: `curveCanvas` verankert Kurven-
  Geometrie jetzt an Slot-KANTEN statt an Knob-Mitten.
  - Erste Stützstelle beginnt am linken Rand des ersten Slots, letzte
    endet am rechten Rand des letzten Slots — Kurve läuft sauber über
    die gesamte Lane-Breite.
  - Marker pro Step sind jetzt kurze waagerechte Linien auf dem
    Wertniveau (Slot-Innenbreite, lineWidth 2) statt isolierter Punkte.
  - Übergänge zwischen Slots = dünne Diagonalen von Slot-Ende zu
    Slot-Anfang (lineWidth 1, leicht transparent).
  - Flächen-Fill als step-hold-Shape mit Gap-Überbrückung auf gleichem
    Niveau + vertikalem Sprung auf den nächsten Wert.

---

## [1.8.1] — 2026-04-18

### CC-Lane Slice 1.1 — UI-Refinement (Geometrie-Angleichung)

Nachschärfung der CC-Lane-UI. Kein neues Verhalten, keine Modell-/Audio-/
Snapshot-Änderungen, keine neuen Editier-Tools und keine CC-Funktionen —
rein visuelle und geometrische Angleichung an die Step-Lane, damit
CC- und Step-Lanes sich bei Scrolling, Pinch-Zoom, Ratio- und
Step-Count-Änderungen gleich anfühlen.

- **`Views/CCLaneBodyView.swift`**: Geometrie spiegelt jetzt
  `StepGridView`:
  - Outer `HStack { GeometryReader { ZStack … }.clipped(); StretchHandleView }`.
  - Horizontales Scrolling über `scrollState.hScrollOffset` — CC- und
    Step-Lanes teilen exakt dasselbe Scroll-Verhalten.
  - `CornerHandlesView` liegt INNERHALB der gescrollten Knob-Row nach
    dem letzten Knob. Die Handles sitzen am realen Content-Edge und
    bewegen sich mit Scroll und Step-Count-Drag.
  - `StretchHandleView` (80 pt) liegt wie in Step-Lane außerhalb des
    Scroll-Bereichs, stabil am rechten Fenster­rand.
  - `StepBeatLinesView` als Hintergrund wiederverwendet — Raster,
    Ratio und rhythmische Struktur sind in der CC-Lane sichtbar.
  - Playback-Highlight ist pro Zelle als kleine LED oberhalb des Knobs
    realisiert (`amberBright` + Glow, identisches Muster zu
    `StepButtonView`). Das frühere springende Rechteck-Overlay
    entfällt.
- **`Views/StepGridView.swift`**: `StepBeatLinesView` von `private` auf
  internal-`struct` angehoben. Kein Verhalten geändert; nur Sichtbarkeit
  für die Wiederverwendung in `CCLaneBodyView`.
- **`VERSION`**: 1.8.0 → 1.8.1.

---

## [1.8.0] — 2026-04-17

### CC-Lane Slice 1 — Erster echter zweiter Lane-Typ

Erste Extraktion des CC-Subsystems in einen eigenständigen Lane-Typ
`LaneKind.cc`. CC-Lanes sind vollwertige Tracks mit eigener MIDI-Channel,
Playback-Richtung, Step-Anzahl, Ratio und einer Knob-Reihe pro Step für
eine einzelne CC-Controller-Nummer. Vertikaler Durchstich durch Model,
Snapshot, RT-Pfad, ModelWriter und UI.

- **`Models/LaneKind.swift`**: `.cc`-Case ergänzt.
- **`Models/LaneData.swift`**: CC-Payload-Felder (`ccValues`, `ccNumber`,
  `ccLabel`, `ccIsMuted`) in `LaneData` ergänzt — als **pragmatische
  Übergangsform** kind-abhängig befüllt. Strict-Codable kind-geschaltet;
  kein `decodeIfPresent`-Fallback.
- **`Engine/PlaybackSnapshot.swift`**: `LaneSnapshot` trägt zusätzlich
  `ccValues`, `ccNumber`, `ccIsMuted` — alle `let`, D9 bleibt gewahrt.
- **`Engine/SequencerEngine.swift`**:
  - `buildPatternSnapshot()` kind-geschaltet (Exhaustiveness-Anker).
  - `advanceSteps()` kind-geschaltet: `.cc` sendet genau einen
    `midi.cc(...)` pro aktivem Step.
  - `addTrack(kind:)` / `insertTrack(after:, kind:)` erhalten
    `LaneKind`-Parameter (Default `.step`).
- **`Engine/ModelCommand.swift`** / **`ModelWriter.swift`**: fünf neue
  CC-Lane-Commands; Undo an den Stellen registriert, an denen Step-
  Lanes Undo haben, Mute ohne Undo (konsistent zu CC1/CC2).
- **`Engine/InteractionController.swift`**: `requireStepLane(_:)` auf
  `beginPitchDrag` + `beginStepSwap` beschränkt — die vier lane-
  neutralen Corner-Handle-Einstiege lassen den Guard fallen.
- **`Views/CCLaneBodyView.swift`** (neu): Knob-Reihe pro Step, Canvas-
  Kurve (abschaltbar), Draw-Overlay mit Interpolation, Playback-
  Cursor, `CornerHandlesView`.
- **`Views/CCLaneHeaderView.swift`** (neu): linker Spurkopf für CC-Lanes.
- **`Views/TrackSideHeaderView.swift`** (neu): Dispatch-Shell der
  linken Spalte (vierter Exhaustiveness-Anker auf der UI-Seite).
- **`Views/LaneBodyView.swift`**: `.cc`-Case ergänzt.
- **`Views/TrackRowView.swift`**: nutzt `TrackSideHeaderView`;
  Expand-Chevron nur bei `.step`-Lanes; Kontext-menü „Insert Track
  Below" als Untermenü Step/CC.
- **`Views/MainView.swift`**: Plus-Button zur Menü-Auswahl Step/CC.
- **`Str.swift`**: `addStepTrack`, `addCCTrack`, `ccNumberLabel`,
  `undoCCLaneDraw`, `undoCCLaneRandomize`, `undoCCLaneReset`.
- **`VERSION`** / **`MARKETING_VERSION`** (Debug + Release):
  1.7.0 → 1.8.0.

### Nicht enthalten (bewusst)

- Keine Enum-Payload-Migration — Payload bleibt pragmatisch
  kind-abhängig auf einer gemeinsamen `LaneData`.
- Kein Legacy-Fallback für Presets ohne `kind`-Feld.
- Keine Horizontal-Scroll-Kopplung von CC-Lane mit `StepGridView`.
- Kein dedizierter Drag-Undo-Punkt für Knob-Drag — Live-Writes ohne
  Undo; Reset/Randomize/Draw liefern Undo.
- Keine Umstellung der Track-internen CC1/CC2-Reihen auf Step-Lanes.

---

## [1.7.0] — 2026-04-17

### Lane Slice 5 — Interaktions-Dispatch `requireStepLane(_:)`

Fünfter Schritt der Lane-Migration: `LaneKind` wirkt jetzt auch strukturell
in der Interaktionsschicht. `InteractionController` hält einen privaten
Helper `requireStepLane(_:)` mit `switch lane.kind { case .step: break }`.
Jeder step-lane-spezifische `begin*`-Einstieg ruft ihn auf und bildet damit
den dritten Exhaustiveness-Anker (nach `buildPatternSnapshot()` auf der
Daten-Seite und `LaneBodyView` auf der UI-Seite).

- **`Engine/InteractionController.swift`**: privater Helper
  `requireStepLane(_ lane: LaneData)` ergänzt. Aufruf in sechs
  Session-Öffnern, jeweils unmittelbar nach dem modalen
  `guard _session == nil else { return }`:
  `beginHandleDrag`, `beginRatioDrag`, `beginPitchDrag`, `beginStepSwap`,
  `beginStretchRatioDrag`, `beginStretchCountDrag`. Gruppiert unter neuem
  MARK-Header „Step-Lane Sessions (Lane Slice 5)". Keine Verhaltens-
  änderung — der Switch trifft heute ausschließlich `.step`.
- **`VERSION`** / **`MARKETING_VERSION`** (App-Target Debug + Release):
  1.6.0 → 1.7.0. GUI-Versionsanzeige synchronisiert über
  `CFBundleShortVersionString` automatisch.
- **`ENGINEERING.md`**: Abschnitt „Interaktions-Dispatch (ab Lane Slice 5,
  v1.7.0)" im Lane-Modell-Kapitel ergänzt; Nicht-Ziele-Liste um
  Slice-5-Abgrenzungen erweitert.
- **`PROJECT_LOG.md`**: Phase, Versionshistorie und Aufgabenliste auf
  Slice 5 / v1.7.0 aktualisiert.

### Nicht enthalten (bewusst)

- Kein Guard in Update-/Commit-/Cancel-Pfaden — das modale Modell
  garantiert, dass eine Session nur fortgesetzt wird, wenn sie zuvor
  erfolgreich geöffnet wurde.
- Kein Guard für `beginRubberBand` — Rubber-Band ist lane-kind-agnostisch
  (reine Selektionsgeometrie).
- Keine Umbenennungen, keine Signaturänderungen, keine neuen LaneKind-Fälle,
  keine Änderungen an View-, Model- oder Command-Schicht.

---

## [1.6.0] — 2026-04-17

### Lane Slice 4 — View-Shell `LaneBodyView` mit lane-kind-Dispatch

Vierter Schritt der Lane-Migration: `LaneKind` wirkt zum ersten Mal strukturell
in der View-Schicht. Eine dünne View-Shell trennt den lane-kind-neutralen
Track-Rahmen (Header, CC-Panels, Expand-Button, Selection-Toolbar) vom
lane-kind-abhängigen Body. Damit sitzt der zweite Exhaustiveness-Anker nach
`buildPatternSnapshot()` nun auf der UI-Seite.

- **`Views/LaneBodyView.swift`** (neu): View-Shell mit exakt einem
  `switch track.lane.kind`; Case `.step` rendert `StepGridView`. Kein
  `default`, kein `AnyView`, kein eigener State, keine Gesten —
  Pass-Through-Parameter identisch zu `StepGridView`.
- **`Views/TrackRowView.swift`**: der einzige direkte `StepGridView(...)`-
  Aufruf ersetzt durch `LaneBodyView(...)`. Kommentar an der Call-Site auf
  Slice 4 aktualisiert. Kein Signatur- oder Umbau-Change.
- **`MARKETING_VERSION`** (App-Target Debug + Release): 1.5.0 → 1.6.0.
  GUI-Versionsanzeige synchronisiert über `CFBundleShortVersionString`
  automatisch.
- **`ENGINEERING.md`**: Abschnitt „UI-Dispatch (ab Lane Slice 4, v1.6.0)" im
  Lane-Modell-Kapitel ergänzt; Nicht-Ziele-Liste um Slice-4-Abgrenzungen
  erweitert.

Rein strukturell: keine Verhaltensänderung, keine UI-Änderung, keine
Performance-Auswirkung, keine angefassten Tests. Bewusst nicht Teil dieses
Slices: zweiter `LaneKind`-Case, Interaction-Shell, `LaneViewModel`,
Umbau/Umbenennung von `StepGridView`, Command-/Writer-Änderungen.

---

## [1.5.0] — 2026-04-17

### Lane Slice 3 — Lane-Typ-Enum (`LaneKind`) eingeführt

Dritter Schritt der Lane-Migration: das Lane-Modell bekommt einen expliziten
Typ-Diskriminator. Heute existiert genau ein Case (`.step`) — der Enum ist
dennoch bereits eingeführt, damit das Persistenzschema gesperrt ist und
künftige Lane-Typen mechanisch an allen Exhaustiveness-Stellen vom Compiler
markiert werden, statt sich in Default-Zweigen zu verstecken. Rein strukturell:
null Verhaltensänderung, null UI-Änderung, null Performance-Impact.

- **`Models/LaneKind.swift`** (neu): `enum LaneKind: String, Codable, Sendable`
  mit genau einem Case `.step`.
- **`Models/LaneData.swift`**: `let kind: LaneKind` als Pflichtfeld; `init`
  mit Default `.step`; JSON kodiert `kind` immer, dekodiert mit `decode` (nicht
  `decodeIfPresent`) — **kein Legacy-Fallback**. Preset-Dateien aus v1.4.0 und
  älter schlagen bewusst sauber fehl und werden bei Bedarf manuell konvertiert.
- **`Engine/PlaybackSnapshot.swift`**: `LaneSnapshot.kind: LaneKind` als
  Diskriminator im RT-Pfad; `let`, `Sendable`, D9-konform.
- **`Engine/SequencerEngine.swift`**: `buildPatternSnapshot()` enthält den
  einzigen Exhaustiveness-Anker (`switch lane.kind`) — ohne `default`. Baut den
  Step-Snapshot im `.step`-Case; `advanceSteps(tickTime:)` bleibt bewusst
  step-only, die Weiche sitzt im Publish-Pfad, nicht im Hot-Path.
- **`Models/TrackData.swift`**: `freshCopy()` übernimmt `lane.kind`.
- **`VintageSequencerTests/MockAdvanceRuntimeSource.swift`**: `LaneSnapshot`-
  Test-Fabrik um `kind: .step` ergänzt.
- **`MARKETING_VERSION`** (App-Target Debug + Release): 1.4.0 → 1.5.0. GUI-
  Versionsanzeige synchronisiert über `CFBundleShortVersionString` automatisch.
- **`ENGINEERING.md`**: Abschnitt „Lane-Typisierung (ab Slice 3)" ergänzt;
  Nicht-Ziele um explizite Einträge erweitert.

Bewusst nicht Teil dieses Slices: kein JSON-Migrationspfad, keine View-
Änderungen, kein `InteractionController`-Touch, keine ModelCommand-Umbenennung,
keine Varianten-Aufspaltung von `LaneSnapshot`.

---

## [1.4.0] — 2026-04-17

### Lane Slice 2 — View-Layer auf `track.lane.*` umgestellt

Zweiter Schritt der Lane-Migration: die View-Schicht greift jetzt lane-explizit
auf Sequenzfelder zu. Die fünf Komfort-Forwardings auf `TrackViewModel`
(`steps`, `stepCount`, `direction`, `stepLengthNumerator`, `stepLengthDenominator`)
sind ersatzlos entfernt — Views lesen diese Felder ausschließlich über
`track.lane.xxx`.

- **`Models/TrackViewModel.swift`**: die fünf Lane-Forwardings entfernt.
  Container-Forwardings (`name`, `midiChannel`, `isMuted`, `isSolo`,
  `timingOffset`, `scaleRoot`, `scaleIndex`, `cc1/cc2`-Felder) und der Accessor
  `lane: LaneData` bleiben unverändert; Doku-Kommentar nachgezogen.
- **Views (10 Dateien)** auf `track.lane.*` umgestellt:
  `TrackHeaderView`, `TrackCCKnobSectionView`, `TrackCCSectionView`,
  `StepGridView`, `StepButtonView`, `StepDetailView`, `StepSelectionToolbar`,
  `StretchHandleView`, `CornerHandlesView`, `CCRowView`.
- **`MARKETING_VERSION`** (App-Target Debug + Release in
  `FIRSTofFIFTH.xcodeproj/project.pbxproj`): 1.1.2 → 1.4.0. Die GUI-Versions­anzeige
  (`VintageTheme.appVersion` liest `CFBundleShortVersionString`) synchronisiert
  damit automatisch.
- **`ENGINEERING.md`**: Hinweis ergänzt, dass `track.lane` die kanonische
  Zugriffsform für Sequenzdaten in Views ist.

Keine Semantik- oder Verhaltensänderung: reine Mechanik-Umstellung, keine
Init-Signaturen angefasst, keine Commands oder Mutations-Pfade berührt.

---

## [1.3.1] — 2026-04-17

### Bugfix — Redo-Pfad: symmetrische Undo-Registrierung

Redo war systemweit nie operativ: Undo-Closures stellten den alten Zustand
wieder her, registrierten aber kein Counter-Undo. Der `NSUndoManager` baut
seinen Redo-Stack jedoch ausschließlich dadurch auf, dass eine laufende
Undo-Operation erneut `registerUndo` aufruft (Cocoa leitet diese Registrierung
bei `isUndoing == true` automatisch in den Redo-Stack um).

- **`Engine/ModelWriter.swift`** (neu): Hilfsfunktion `registerReversibleUndo`
  auf Dateiebene — registriert eine Undo-Closure, die sich bei ihrem Aufruf
  mit getauschtem `forward`/`backward` selbst erneut registriert und so einen
  vollständigen Undo/Redo-Zyklus aufbaut.
- **`Engine/ModelWriter.swift`**: Die Cases `.setStepCount`, `.setRatio`,
  `.setPitchNotes`, `.setSteps`, `.setName` auf die neue Hilfsfunktion
  umgestellt.
- **`Views/TrackHeaderView.swift`**: RND/CLR erfassen den Post-Mutation-Zustand
  (`new`) nach der Aktion und registrieren zustandsbasiert — damit Redo nach
  RND exakt den zuvor erzeugten Random-Zustand wiederherstellt statt neu zu
  würfeln.
- **`Views/MainView.swift`**, **`Views/TrackRowView.swift`**:
  Add-/Insert-/Duplicate-/Delete-Track ebenfalls zustandsbasiert (via
  `snapshotTracks`/`restoreTracks`) über die neue Hilfsfunktion registriert.

### Unverändert (bewusst nicht undo-fähig, bleibt auch nicht redo-fähig)

`.setDirection`, `.setMuted`, `.setSolo`, `.setMIDIChannel`,
`.setTimingOffset`, `.setScaleRoot`, `.setScaleIndex`, `.setCC1Muted`,
`.setCC2Muted`. Dieser Slice erweitert die Undo-Menge nicht.

---

## [1.3.0] — 2026-04-17

### Architektur — Lane-Modell v1 (TrackData/LaneData-Split)

Struktureller Umbau: `TrackData` wird zum reinen Container; der Sequenzkern
zieht in eine neue `LaneData`-Klasse um. Verbindliche 1:1-Beziehung.

- **`Models/LaneData.swift`** (neu):
  Trägt `steps`, `stepCount`, `direction`, `stepLengthNumerator/Denominator`.
  Eigenes `changed`-Subject für Sequenz-Mutations-Signale.

- **`Models/TrackData.swift`**:
  Beibehaltene Container-Felder: `name`, `midiChannel`, `isMuted`, `isSolo`,
  `timingOffset`, `scaleRoot/Index`, `cc1/cc2`-Routing, `isExpanded`.
  Neues Feld: `let lane: LaneData`.

- **`Models/TrackViewModel.swift`**:
  Zwei Subscriptions (`dataSub` + `laneSub`) — Views sehen einen einheitlichen
  Invalidierungsstrom unabhängig davon, ob Container- oder Sequenzfeld mutiert.
  Sequence-Forwarding (`steps`, `stepCount`, …) delegiert auf `data.lane.*`.

- **`Engine/PlaybackSnapshot.swift`**:
  Neuer `LaneSnapshot`-Typ. `TrackSnapshot` hält `lane: LaneSnapshot` statt
  Sequenz-Felder direkt.

- **`Engine/ModelWriter.swift`**:
  Sequence-Cases (`.setSteps`, `.setStepCount`, `.setRatio`, `.setPitchNotes`,
  `.setDirection`) schreiben auf `td.lane`; Container-Cases bleiben auf `td`.

- **Engine / IC / Views**: Alle direkten Sequenz-Zugriffe auf `td.lane.*`
  migriert. IC, MIDILearn, Randomize, Paste vollständig umgezogen.

- **Vor-Lane-Stabilisierungsslices** (1–5) in dieser Version enthalten:
  Track-Identity/vmCache, NotesStore async, Snapshot-Coalescing,
  MIDI-RT-Verifikation, Mutations-Invariante dokumentiert.

---

## [1.2.1] — 2026-04-17

### Feature — Notizfunktion

- **Quick Capture** (`pencil.circle`-Button in der Toolbar):
  Schnelle Eingabe von Notizen, Ideen und Bug-Reports als Popover.
  Typ-Auswahl (NOTE / IDEA / BUG), ⌘↩ speichert und leert das Feld.
  Popover bleibt offen für mehrere Einträge hintereinander.

- **Notes Reader** (`note.text`-Button mit Badge in der Toolbar):
  Separates Sheet mit Zwei-Panel-Layout (Liste + Editor).
  Alle Einträge sichtbar, bearbeitbar und löschbar.
  Badge zeigt Anzahl vorhandener Einträge.

- **NotesStore** (`Notes/NotesStore.swift`):
  Vollständig von SequencerEngine entkoppelt.
  Speichert JSON-Datei unter `~/Library/Application Support/FIRSTofFIFTH/notes.json`.
  Atomares Schreiben nach jeder Mutation.

- **NoteEntry** (`Notes/NoteEntry.swift`):
  Datenmodell mit `id`, `createdAt`, `updatedAt`, `kind`, `text`.

- Debug-Panels nach links gerückt (`.padding(.trailing, 60)`) —
  überdecken nicht mehr den Notiz-Bereich.

---

## [1.2.0] — 2026-04-17

### Architektur — Slice G: TrackData / TrackViewModel Split

- **`Track` aufgeteilt in `TrackData` + `TrackViewModel`** (Pre-Lane-Umbau).
  `TrackData` ist ein reines Datenmodell (`Codable`, kein `ObservableObject`),
  `TrackViewModel` ist der View-Layer-Wrapper (`ObservableObject`, hält `let data: TrackData`).
- **`Pattern.tracks: [TrackData]`** — strukturelle Änderungen feuern `@Published`.
- **`TrackData.changed: PassthroughSubject`** — feuert nach jedem Feldschreiben
  durch `ModelWriter`; bewusst nicht Codable (kein CodingKey).
- **`TrackData.id: UUID` ist persistent Codable** — Backward-Compat-Fallback
  `(try? decode) ?? UUID()` für alte Presets ohne `id`-Key.
- **`SequencerEngine.vmCache: [UUID: TrackViewModel]`** — lazy, per `viewModel(for:)`,
  wird nach Preset-Load und `newProject` via `pruneVMCache(keeping:)` bereinigt.
- **`ModelWriter`** schreibt auf `TrackData`, feuert `td.changed.send()` nach
  jeder Mutation und in jedem Undo-Closure.
- **Views**: Alle `@ObservedObject var track: Track` → `TrackViewModel` migriert
  (TrackRowView, TrackHeaderView, StepGridView, StepButtonView, StepDetailView,
  CornerHandlesView, StretchHandleView, CCRowView/CCKnobRowView,
  TrackCCSectionView, TrackCCKnobSectionView, StepSelectionToolbar,
  SettingsView/TrackCCRow).
- **`MainView` ForEach** iteriert `[TrackData]`, holt `TrackViewModel` via
  `engine.viewModel(for: td)`.
- **`Track.swift` gelöscht** — `ScaleDefinition`, `PlayDirection` leben jetzt
  exklusiv in `TrackData.swift`.
- **`TrackViewModel`** ergänzt um read-write Setter für `cc1Label`, `cc1Number`,
  `cc2Label`, `cc2Number` (SettingsView-Bindings) und `isExpanded`.

---

## [1.1.8] — 2026-04-16

### Bugfix

- **Slice F Restfix: Track add/remove während Playback sofort in UI sichtbar.**
  `objectWillChange.send()` in alle 5 strukturellen Track-Methoden eingefügt
  (`addTrack`, `insertTrack`, `duplicateTrack`, `restoreTracks`, `removeTrack`).
  Ursache (Slice-C-Regression): `hasUnsavedChanges` liegt seit Slice C auf
  `presetEditorState` — schreiben dorthin feuert nur `presetEditorState.objectWillChange`,
  nicht `engine.objectWillChange`. `MainView`'s `ForEach(engine.currentPattern.tracks)`
  evaluierte das Array deshalb nicht neu → neue/gelöschte Track-Zeile erst nach
  Stop/Play sichtbar. Expliziter `objectWillChange.send()` unmittelbar nach der
  Array-Mutation behebt dies.

---

## [1.1.7] — 2026-04-16

### Bugfix

- **Slice F Nachtrag: Track add/remove während Playback sofort wirksam.**
  Strukturelle Track-Mutationen (add, insert, duplicate, restore, remove)
  synchronisieren jetzt `trackRuntimes` und `playbackDisplay.steps` vor
  `publishSnapshot()`. Vorher: neuer Track spielte erst nach Stop/Play mit
  (`trackRuntimes`-Guard in `advanceSteps` hat neuen Index übersprungen).
  Pre-existing-Bug; nicht durch Slice F eingeführt.

---

## [1.1.6] — 2026-04-16

### Architektur

- **Slice F: Reaktive Track-Subscription (Pre-Lane-Umbau).**
  `resubscribeTrackChanges()` vollständig entfernt. Track-Subscriptions werden
  jetzt automatisch reaktiv aus der aktuellen `patterns`-/`tracks`-Struktur
  abgeleitet. Keine manuellen Call-Sites mehr erforderlich.

  **Zwei reaktive Ebenen:**
  - `$patterns` (Engine) — reagiert auf Preset-Load, `newProject()`, `pasteToCurrentPattern()`
  - `pattern.$tracks` (je Pattern) — reagiert auf `addTrack()`, `removeTrack()`,
    `insertTrack()`, `duplicateTrack()`, `restoreTracks()`

  **Timing-Fix im Track-Sink:** `hasUnsavedChanges = true` wird jetzt synchron
  gesetzt statt via `DispatchQueue.main.async`. Dadurch kann `loadData()` →
  `hasUnsavedChanges = false` die Schreibung korrekt überschreiben, ohne eine
  deferred-write Race Condition. `publishSnapshot()` bleibt weiterhin deferred
  (liest den Wert nach dem `@Published`-Write).

  **9 Call-Sites entfernt:** `init()`, `addTrack()`, `insertTrack()`,
  `duplicateTrack()`, `restoreTracks()`, `removeTrack()` (Engine.swift),
  `loadData()`, `newProject()`, `pasteToCurrentPattern()` (PresetIO.swift).

  **Keine semantischen Änderungen** an Live-Edits, Playback, Undo, MIDI.

---

## [1.1.5] — 2026-04-16

### Architektur

- **Slice E: View→Track-Mutations auf ModelWriter vereinheitlicht (Pre-Lane-Umbau).**
  Alle direkten View→Track-Schreibzugriffe laufen jetzt über `ModelWriter`.
  Kein View-Code mutiert mehr `track.*` oder `track.steps` direkt.

  **Neue ModelCommand-Cases:** `setName`, `setMuted`, `setSolo`, `setDirection`,
  `setMIDIChannel`, `setTimingOffset`, `setScaleRoot`, `setScaleIndex`,
  `setCC1Muted`, `setCC2Muted`.
  Bestehende Cases `setSteps` und `setRatio` für alle Bulk-Step- und
  Ratio-Presets-Mutations wiederverwendet.

  **Undo-Regel eingehalten:** Was heute Undo hat (StepButton, StepDetail,
  CC-Draw, CC-Randomize/Reset, RND/CLR-Button), behält es.
  TrackHeader-Zustandsfunktionen (Mute, Solo, Direction, MIDI-Channel,
  TimingOffset, ScaleRoot, ScaleIndex) landen **nicht** im Undo-Stapel —
  das sind Routing-/Zustandsaktionen, keine Pattern-Inhalt-Edits.

  **`$track.name` TextField:** Umgestellt auf lokales `@State nameEdit`.
  Commit über `ModelWriter.apply(.setName)` beim Focus-Out. Undo bleibt.
  Externe Änderungen (Paste-Pattern, Undo) werden per `onChange(of: track.name)`
  in den lokalen State synchronisiert.

  **`$track.midiChannel` Picker:** Direktes Binding durch manuelles
  `Binding(get:set:)` ersetzt, set-Pfad über `ModelWriter`.

### Betroffene Dateien
- `Engine/ModelCommand.swift` — 10 neue Cases
- `Engine/ModelWriter.swift` — 10 neue apply-Branches
- `Views/StepButtonView.swift` — `modifyStep()` → `writer.apply(.setSteps)`
- `Views/StepDetailView.swift` — `modify()` + MultiStep + Transpose → `writer.apply`
- `Views/StepSelectionToolbar.swift` — CLR → `writer.apply(.setSteps)`
- `Views/CCRowView.swift` — Knob-Binding + applyDraw → `writer.apply(.setSteps)`
- `Views/TrackCCSectionView.swift` — CC1/CC2 Randomize/Reset/Mute → `writer.apply`
- `Views/MainView.swift` — `onClear` → `writer.apply(.setSteps)`
- `Views/TrackHeaderView.swift` — Name/Mute/Solo/Direction/Channel/Feel/Scale
- `Views/StretchHandleView.swift` — Ratio-Preset-Buttons → `writer.apply(.setRatio)`
- `VintageSequencerApp.swift` — Mute-CommandMenu → `ModelWriter().apply(.setMuted)`

---

## [1.1.4] — 2026-04-16

### Architektur

- **Slice D: MIDILearnState-Isolation (Pre-Lane-Umbau).**
  `patternSwitchCC`, `trackMuteCCs`, `learnMode` (@Published) und
  `learnTarget` (plain var) aus `SequencerEngine` in neues
  `MIDILearnState: ObservableObject` ausgelagert.
  CC-Remote-Control-Schreibzugriffe und Learn-Mode-Toggles feuern nur
  noch `midiLearnState.objectWillChange` — nicht mehr `engine.objectWillChange`.
  Eliminiert spurious StepButton-/TrackRow-/TrackHeader-Rebuilds beim
  Aktivieren/Deaktivieren des Learn-Modus.
  `TransportView`, `StepButtonView` und `SettingsView` subscriben direkt
  via `@EnvironmentObject MIDILearnState`.
  `SequencerEngine+MIDILearn.swift` bleibt unverändert — Computed-Accessors
  auf der Engine machen den Übergang für Extensions transparent.
  `learnTarget` bewusst NICHT @Published: schrittweise Advances während
  einer aktiven Learn-Session feuern kein objectWillChange (identisch
  zum bisherigen Verhalten).

### Betroffene Dateien
- `Engine/MIDILearnState.swift` (NEU)
- `Engine/SequencerEngine.swift` — 4 Deklarationen → `let midiLearnState` + Computed-Accessors
- `Engine/BodyRunCounter.swift` — Subscription auf `engine.midiLearnState.$learnMode`
- `Views/TransportView.swift` — `@EnvironmentObject mls: MIDILearnState`
- `Views/StepButtonView.swift` — `@EnvironmentObject mls: MIDILearnState`
- `Views/SettingsView.swift` — `@EnvironmentObject mls: MIDILearnState`
- `VintageSequencerApp.swift` — `.environmentObject(engine.midiLearnState)` ergänzt

---

## [1.1.3] — 2026-04-16

### Architektur

- **Slice C: PresetEditorState-Isolation (Pre-Lane-Umbau).**
  `swing`, `hasUnsavedChanges`, `currentPresetURL`, `recentFiles`,
  `lastErrorMessage`, `clipboard`, `stepClipboard` aus `SequencerEngine`
  in neues `PresetEditorState: ObservableObject` ausgelagert.
  Preset-I/O-Writes, Track-Edit-Marks (`hasUnsavedChanges = true`) und
  Swing-Knob-Drehungen feuern nur noch `presetEditorState.objectWillChange` —
  nicht mehr `engine.objectWillChange`. Eliminiert spurious StepButton-/
  TrackRow-/TrackHeader-Rebuilds bei Track-Edits und Swing-Änderungen.
  `TransportView` und `StepSelectionToolbar` subscriben direkt via
  `@EnvironmentObject PresetEditorState`.
  Fünfter Schritt der State-Isolation-Reihe nach PlaybackDisplayState,
  ScrollState, StepWidthState, TransportState, ClockDiagnosticsState.

  Gezielte Forwarding-Sinks für `recentFiles` und `clipboard` halten
  VintageSequencerApp-Commands (Open Recent, Paste Pattern `.disabled`)
  reaktiv — diese ändern sich nur bei expliziten Benutzeraktionen.

### Betroffene Dateien
- `Engine/PresetEditorState.swift` (NEU)
- `Engine/SequencerEngine.swift` — 7 @Published-Felder → `let presetEditorState`,
  Computed-Accessors, Forwarding-Sinks für recentFiles + clipboard
- `Engine/BodyRunCounter.swift` — `engine.$hasUnsavedChanges` → `engine.presetEditorState.$hasUnsavedChanges`
- `Views/TransportView.swift` — `@EnvironmentObject pes: PresetEditorState`,
  swing/hasUnsavedChanges/currentPresetURL → `pes.*`
- `Views/StepSelectionToolbar.swift` — `@EnvironmentObject pes: PresetEditorState`,
  `engine.stepClipboard` → `pes.stepClipboard`
- `VintageSequencerApp.swift` — `.environmentObject(engine.presetEditorState)` ergänzt

---

## [1.1.2] — 2026-04-16

### Architektur

- **Slice B: midi.objectWillChange-Forwarding entfernt (Pre-Lane-Umbau).**
  `midi.objectWillChange.sink { self?.objectWillChange.send() }` aus `SequencerEngine`
  entfernt. `MIDIManager` ist jetzt als eigenes `.environmentObject(engine.midi)`
  injiziert. `SettingsView` und `StatusBar` subscriben direkt via
  `@EnvironmentObject private var midi: MIDIManager`. MIDI-Device-Änderungen
  (Port-Discovery, Output-/Input-Selektion) feuern nicht mehr `engine.objectWillChange`
  und invalidieren keine Engine-Subscriber-Views mehr.

### Betroffene Dateien
- `Engine/SequencerEngine.swift` — Forwarding-Sink entfernt
- `VintageSequencerApp.swift` — `.environmentObject(engine.midi)` ergänzt
- `Views/SettingsView.swift` — `@EnvironmentObject midi: MIDIManager`, alle `engine.midi.*`-Reads → `midi.*`
- `Views/MainView.swift` — StatusBar: `@EnvironmentObject midi: MIDIManager`, MIDI-Out-Anzeige → `midi.*`

---

## [1.1.1] — 2026-04-16

### Architektur

- **Slice A: ClockDiagnosticsState-Isolation (Pre-Lane-Umbau).**
  `clockJitterAvgUs`, `clockJitterMinUs`, `clockJitterMaxUs`, `clockJitterOuts`
  aus `SequencerEngine` in neues `ClockDiagnosticsState: ObservableObject` ausgelagert.
  Engine hält jetzt `let clockDiagnostics = ClockDiagnosticsState()`.
  Sobald Jitter-Writes aktiviert werden (~1×/s während Playback), feuert nur noch
  `clockDiagnostics.objectWillChange`, nicht mehr `engine.objectWillChange`.
  Alle Engine-Subscriber (TrackRowView ×8, StepGridView, TransportView etc.)
  werden damit von Jitter-Updates vollständig entkoppelt.

### Betroffene Dateien
- `Engine/ClockDiagnosticsState.swift` (NEU)
- `Engine/SequencerEngine.swift` — 4 @Published-Felder → `let clockDiagnostics`
- `Views/MainView.swift` — StatusBar: `engine.clockJitter*` → `clockDiagnostics.*`
- `Engine/BodyRunCounter.swift` — Subscription: `engine.$clockJitterAvgUs` → `engine.clockDiagnostics.$avgUs`
- `VintageSequencerApp.swift` — `.environmentObject(engine.clockDiagnostics)` ergänzt

---

## [1.1.0] — 2026-04-16

### Architektur

- **Arch-Slice-19: TransportState-Isolation.**
  `bpm`, `isPlaying`, `clockMode`, `currentPatternIndex`, `queuedPatternIndex` aus
  `SequencerEngine` in neues `TransportState: ObservableObject` ausgelagert.
  BPM-Knob-Drehungen lösen keine StepButton-/StepGrid-/TrackRow-/TrackHeader-
  Rebuilds mehr aus. Eliminiert ~6.700 StepButton-body-Evaluierungen pro
  BPM-Tick-Burst. Vierter und letzter Schritt der State-Isolation-Reihe
  (nach PlaybackDisplayState, ScrollState, StepWidthState).

- **Arch-Slice-20: GlobalPinchZoomModifier.**
  Per-Lane `PinchZoomModifier` aus `StepGridView` entfernt und durch einen
  einzigen `GlobalPinchZoomModifier` auf dem ScrollView in `MainView` ersetzt.
  Erstmalige Anbindung der vollständig implementierten, aber bisher verwaisten
  `InteractionController`-Pinch-API (`beginPinchZoom` / `updatePinchZoom` /
  `endPinchZoom`). Ankerstabiler Scroll-Offset-Ausgleich via
  `ViewportController.adjustScroll` — der Zoom-Pivot bleibt am Finger fixiert.

### Behoben

- **`hasUnsavedChanges`-Leak über `engine.objectWillChange`.**
  Combine-Sink in `SequencerEngine` für `transportState.$bpm` schrieb
  `hasUnsavedChanges = true` bei jedem BPM-Tick — auch wenn bereits `true`.
  `@Published` hat kein Gleichheits-Gate, daher feuerte `engine.objectWillChange`
  bei jedem Tick und invalidierte alle Engine-Subscriber. Behoben:
  `if !self.hasUnsavedChanges { self.hasUnsavedChanges = true }`.

- **"Publishing changes from within view updates" — Cursor-Freeze bei Pinch/Width.**
  `NativeHScrollbar.updateNSView`: `sv.documentView?.frame.size.width = contentWidth`
  lief vor dem `isSyncingScrollbar`-Guard. Frame-Resize löste synchron
  `boundsDidChangeNotification` → `syncFromScrollbar` → `@Published`-Schreibzugriff
  innerhalb des SwiftUI-Update-Passes → Feedback-Loop → Cursor-Freeze.
  Behoben: Document-Resize in den `defer`-geschützten `isSyncingScrollbar`-Block
  verschoben.

### Verbessert

- **Pinch-Quantisierung.**
  `stepWidthState.size` wird nur noch bei ganzzahligem Pixelwechsel geschrieben
  (entspricht dem `step: 1`-Verhalten des Width-Sliders). Reduziert Schreibrate
  von ~120/s auf ~10–15/s.

- **`adjustScroll`-Gate.**
  `updatePinchZoom` (und damit `ViewportController.adjustScroll`) wird nur
  aufgerufen, wenn tatsächlich eine ganzzahlige Layout-Grenze überschritten wird.
  Verhindert Scroll-Offset-Divergenz (bis >1.000 px) bei langsamen Pinch-Gesten.

- **`syncFromScrollbar` Equality-Gate.**
  `abs(clamped - scrollState.hScrollOffset) > 0.5` verhindert spurious
  `objectWillChange`-Fires, wenn NSScrollView nach programmatischem Scroll
  dieselbe Position meldet.

- **`StepWidthState`-Kommentar aktualisiert.**
  Schreiber: `GlobalPinchZoomModifier (MainView)` statt veraltetem `PinchZoomModifier`.

### Bekannte Einschränkungen

- Bei sehr langsamen Pinch-Gesten (eine Umdrehung ≈ 1 px/Commit) ist ein leichtes
  LED-Stocken sichtbar — eine StepButton-Reihe wird pro 1-px-Layout-Commit neu
  evaluiert. Legitime Restlast, kein kaputter Pfad. Separater Optimierungsslice
  geplant.

### Betroffene Dateien
- `Engine/TransportState.swift` (NEU)
- `Engine/SequencerEngine.swift` — 5 Properties delegiert, Combine-Sink-Guard
- `Engine/ViewportController.swift` — `syncFromScrollbar` Equality-Gate
- `Engine/StepWidthState.swift` — Schreiber-Kommentar aktualisiert
- `Engine/BodyRunCounter.swift` — Subscriptions auf `transportState.*`
- `Views/TransportView.swift` — alle Transport-Lesezugriffe → `ts.*`
- `Views/MainView.swift` — StatusBar `@EnvironmentObject ts`, GlobalPinchZoomModifier,
  NativeHScrollbar-Fix
- `Views/StepGridView.swift` — PinchZoomModifier entfernt (42 Zeilen)
- `VintageSequencerApp.swift` — `.environmentObject(engine.transportState)`

---

## [1.0.20] — 2026-04-15

### Geändert
- **`stepWidthSize` aus SequencerEngine isoliert.** Neues `StepWidthState` ObservableObject (analog zu `PlaybackDisplayState`, `ScrollState`). Width-/Pinch-Änderungen feuern nicht mehr `engine.objectWillChange` — nur noch `stepWidthState.objectWillChange`. Eliminiert ~40–50 unnötige View-Invalidierungen pro Frame bei Width-Änderung (TransportView, TrackRowView ×8, TrackHeaderView ×8, StepSelectionToolbar ×8, StretchHandleView ×8, SettingsView).

### Betroffene Dateien
- `StepWidthState.swift` (NEU)
- `SequencerEngine.swift` — `@Published var stepWidthSize` → computed `var stepWidthSize` (Convenience-Accessor, kein @Published)
- `VintageSequencerApp.swift` — `.environmentObject(engine.stepWidthState)` ergänzt
- `StepGridView.swift` — `@EnvironmentObject stepWidthState` + 7 Lesezugriffe umgestellt
- `PinchZoomModifier` — `engine` → `stepWidthState` (liest/schreibt nur noch `stepWidthState.size`)
- `TransportView.swift` — Slider-Binding auf `$stepWidthState.size`
- `MainView.swift` — `laneContentWidth` + scrollMonitor auf `stepWidthState.size`
- `CCRowView.swift` — 4 Lesezugriffe umgestellt

---

## [1.0.19] — 2026-04-15

### Geändert
- **Display-Drain: Timer → Event-Signal.** `displayDrainTimer` (16ms-Polling-Timer) ersetzt durch `displaySignal` (DispatchSource.makeUserDataOrSource). Signal feuert nur wenn advanceSteps tatsächlich neue Display-Events produziert hat. Eliminiert Timer-Moiré-Interferenz.
- **Debug-Instrumentierung:** Temporäre Messpunkte für `lastFiredNotes`-Hypothese (notesFired/Clear-Logging, Drain-Dauer, silenceFiredNotes-Flag). Nur in DEBUG-Builds aktiv.

### Bekannte Probleme
- Cursor verharrt subjektiv auf Step 0 ("der 1") — vermutlich Main-Thread-Last durch Track.objectWillChange-Broadcasts (lastFiredNotes set/clear)
- Width-Änderung während Playback blockiert Cursor-Updates (engine.objectWillChange-Kaskade)

---

## [1.0.18] — 2026-04-15

### Behoben
- **Pinch-Zoom-Desync** behoben: scaleEffect komplett entfernt, Pinch schreibt jetzt direkt in engine.stepWidthSize (identisch zum Width-Slider)
- **PlaybackCursorOverlay Y-Offset:** Korrekte vertikale Zentrierung statt hardcodiertem y:6
- **Hit-Testing:** .contentShape(Rectangle()) für Pinch-Geste über gesamte Grid-Fläche

### Geändert
- PinchZoomModifier auf 7 Zeilen reduziert (MagnifyGesture → stepWidthSize, kein Sonderweg)
- VintageTheme.stepGridLeadingPad als zentrale Konstante (ersetzt hardcodierte 8)

---

## [1.0.15] — 2026-04-12

### Behoben
- Alle 5 Critical-Blocker geschlossen (B1–B6)
- Timing-Korrektheit intern + extern (T2: Overshoot-Korrektur, EMA-Lookahead)

### Hinzugefügt
- Performance Baseline Tests (Arch-Slice-11)
- 36 Unit-Tests (PresetIO, DisplayEventBuffer, EngineEventBuffer)
- 32 AdvanceRuntime-Tests

---

## [1.0.14] — 2026-04-11

### Behoben
- 14/25 Review-Issues geschlossen
- MIDI Device Disconnect Handling (C1)
- Track.Codable: isSolo + isExpanded ergänzt (C2)
- MIDI-In modernisiert (C3)
- quantizedNote O(1) Lookup (C4)

---

## [1.0.13] — 2026-03

### Status
- Erste reviewte Version
- 5 Critical-Blocker identifiziert
- Bewertung: 3.5/5
