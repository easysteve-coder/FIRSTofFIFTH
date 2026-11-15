# FIRSTofFIFTH — Benutzerhandbuch

**Polyrhythmic Step Sequencer für macOS**

---

## 1. Einführung

### Was ist FIRSTofFIFTH?

FIRSTofFIFTH ist ein MIDI-Step-Sequencer für macOS. Er erzeugt keine eigenen Klänge, sondern sendet MIDI-Daten an externe Synthesizer, Drum Machines oder Software-Instrumente in einer DAW.

### Wofür ist es gedacht?

- Melodische und rhythmische Patterns erstellen
- Polyrhythmische Sequenzen bauen (unterschiedliche Taktarten pro Spur)
- Live-Performance mit Pattern-Wechsel
- Experimentelles Arbeiten mit Zufall, Wahrscheinlichkeiten und Ratchets

### Was macht es besonders?

- **Polyrhythmus:** Jede Spur kann eine eigene Step-Länge haben. Eine Spur spielt Triolen, eine andere punktierte Sechzehntel — gleichzeitig, synchron.
- **Akkorde pro Step:** Jeder Step kann mehrere Noten gleichzeitig spielen.
- **Wahrscheinlichkeit & Ratchets:** Steps können zufällig aussetzen oder mehrfach pro Schritt triggern.
- **16 Patterns (A–P):** Sofort umschaltbar, quantisiert am Ende von Track 1.
- **Song-Lane:** Szenenfolge über allen Patterns, Wechsel exakt auf dem Taktstrich.

---

## 2. Schnellstart

**Ziel:** In zwei Minuten etwas hören.

### Schritt 1: MIDI-Ausgang einrichten

1. Klicke oben rechts auf das **Regler-Symbol** (⚙ Settings).
2. Wähle unter **MIDI Output** dein Gerät oder deine DAW.
3. Schließe das Fenster.

> Ohne MIDI-Ausgang sendet die App Daten, aber du hörst nichts.

### Schritt 2: Steps setzen

- Du siehst eine Spur mit 16 leeren Steps (graue Kästchen).
- **Klicke auf ein paar Steps**, um sie zu aktivieren. Aktivierte Steps leuchten farbig und zeigen eine Tonhöhe (z.B. „C4").

### Schritt 3: Abspielen

- Drücke die **Leertaste** oder klicke den **Play-Button** (▶) oben links.
- Ein leuchtender Punkt wandert durch die Steps. Aktive Steps senden MIDI-Noten.

### Schritt 4: Anpassen

- **Tonhöhe ändern:** Halte ⌥ (Option) und klicke auf einen Step. Es öffnet sich der Step-Editor mit einer Klaviatur.
- **Tempo ändern:** Drehe am **BPM-Regler** in der Transportleiste.
- **Stoppen:** Leertaste oder Stop-Button (■).

Das war's. Ab hier kannst du experimentieren.

---

## 3. Grundkonzept

### Tracks (Spuren)

Jede Spur ist eine eigene Sequenz mit eigenem MIDI-Kanal, eigener Richtung und eigener Geschwindigkeit. Du kannst beliebig viele Spuren haben.

- **Track 1** könnte eine Basslinie auf Kanal 1 spielen.
- **Track 2** könnte ein Drum-Pattern auf Kanal 10 spielen.
- **Track 3** könnte eine Melodie in Triolen auf Kanal 3 spielen.

### Steps (Schritte)

Jeder Step ist ein Slot in der Sequenz. Ein Step kann:

- **Aktiv** sein (spielt eine oder mehrere Noten)
- **Inaktiv** sein (Pause)
- Eigene Tonhöhe, Velocity, Gate-Länge, Wahrscheinlichkeit und CC-Werte haben

### Sequenz

Die Sequenz läuft automatisch durch alle Steps einer Spur. Ist der letzte Step erreicht, beginnt sie von vorne (oder rückwärts, oder zufällig — je nach Einstellung).

### Richtung

Jede Spur hat eine eigene Abspielrichtung:

| Symbol | Richtung | Verhalten |
|--------|----------|-----------|
| ▶ | Forward | Vorwärts: 1 → 2 → 3 → ... → 16 → 1 |
| ◀ | Reverse | Rückwärts: 16 → 15 → ... → 1 → 16 |
| ↔ | Ping-Pong | Hin und her: 1 → 16 → 1 → 16 |
| ~ | Random | Zufällige Reihenfolge |

### Patterns

Es gibt 16 Patterns: **A bis P** (Transportleiste, zwei Reihen). Jedes Pattern enthält alle Spuren mit eigenen Step-Daten. ⌘1 … ⌘9 wählen A … I, die übrigen stehen im Menü *Sequencer*.

- Während des Abspielens: Pattern-Wechsel wird **am Ende von Track 1** (Track 1 erreicht Step 1) ausgeführt — kein abrupter Schnitt.
- Im Stopp-Zustand: Pattern-Wechsel erfolgt sofort.

### Song

Die **Song-Lane** über den Spuren reiht Szenen aneinander. Eine Szene spielt ein Pattern für eine Anzahl Takte (4/4).

- **+** fügt eine Szene hinzu (Kopie der letzten). Klick auf eine Szene wählt Pattern und Länge (1–64 Takte); Rechtsklick: duplizieren, verschieben, löschen. Alles mit Undo.
- **ON/OFF** schaltet den Song-Modus. Ist er an, beginnt Play mit der ersten Szene; die Patterns wechseln **exakt auf dem Taktstrich**, unabhängig davon, wie lang Track 1 ist. Folgen zwei Szenen mit demselben Pattern, läuft es ohne Neustart durch.
- **LOOP/ENDE**: am Songende von vorn beginnen oder anhalten.
- Während der Song läuft, bestimmen die Szenen das Pattern; die Pattern-Tasten sind dann ohne Wirkung. Änderungen am Song gelten ab dem nächsten Wechsel.

---

## 4. Arbeiten mit Steps

### Steps aktivieren und deaktivieren

- **Klick** auf einen Step schaltet ihn an/aus.
- Aktive Steps zeigen den Notennamen (z.B. „C4", „Ebm", „Kick") und einen Velocity-Balken am unteren Rand.

### Tonhöhe ändern

1. **⌥ + Klick** (Option + Klick) auf einen Step öffnet den **Step-Editor**.
2. Im Editor siehst du eine Klaviatur (oder eine Drum-Auswahl bei Kanal 10).
3. Klicke auf eine Taste, um die Tonhöhe zu setzen. Du hörst eine Vorschau.
4. Für **Akkorde:** Klicke mehrere Tasten. Der Step spielt dann alle gewählten Noten gleichzeitig.
5. Schließe den Editor mit **Enter** oder klicke außerhalb.

**Schnelle Tonhöhen-Änderung per Drag:**
- Ziehe einen Step **vertikal** (nach oben/unten), um die Tonhöhe in Halbtönen zu verschieben. Du hörst eine Vorschau bei jeder Änderung.

### Rechtsklick-Menü

Jeder Step hat ein Kontextmenü (Rechtsklick):

- **Edit Step** — Öffnet den Step-Editor
- **Clear Step** — Setzt den Step zurück
- **Max Velocity** — Setzt Velocity auf 127
- **Gate Full** — Setzt die Notenlänge auf 95%
- **Gate Short** — Setzt die Notenlänge auf 15% (Staccato)

### Mehrere Steps auswählen

- **⇧ + Klick** (Shift + Klick) auf Steps, um sie zur Auswahl hinzuzufügen oder zu entfernen.
- **Rubber-Band-Auswahl:** Ziehe mit der Maus über den leeren Bereich zwischen den Steps, um mehrere auf einmal auszuwählen.

Wenn Steps ausgewählt sind, erscheint eine **Aktionsleiste**:

| Button | Aktion |
|--------|--------|
| **EDIT** | Öffnet den Bulk-Editor für alle ausgewählten Steps |
| **COPY** (⌘C) | Kopiert die ausgewählten Steps |
| **PASTE** (⌘V) | Fügt kopierte Steps ein |
| **CLR** | Löscht alle ausgewählten Steps |
| **✕** (Esc) | Hebt die Auswahl auf |

### Bulk-Editor (mehrere Steps gleichzeitig)

Nach Klick auf **EDIT** in der Aktionsleiste:

- **Note setzen:** Wähle eine Note auf der Klaviatur — wird auf alle ausgewählten Steps angewendet.
- **Velocity, Gate, Probability:** Drehe die Regler — werden auf alle angewendet.
- **Transponieren:** Drehe den TRNS-Regler (−24 bis +24 Halbtöne). RESET stellt die Originaltöne wieder her.
- **ALL ON / ALL OFF:** Aktiviert oder deaktiviert alle ausgewählten Steps.

### Steps verschieben

- Ziehe einen Step **horizontal** auf eine andere Position. Die beiden Steps tauschen den Platz.
- Halte **⌥ (Option)** während des Ziehens, um den Step zu **kopieren** statt zu tauschen.

---

## 5. Step-Parameter im Detail

### Velocity (VEL)

Wie laut/stark die Note gespielt wird. Bereich: 1–127.

Der Velocity-Balken am unteren Rand jedes Steps zeigt den Wert visuell an.

### Gate

Wie lange die Note gehalten wird, relativ zur Step-Länge.

- **Short (15%):** Sehr kurz, staccato
- **Full (95%):** Fast die gesamte Step-Dauer
- Dazwischen gibt es 12 musikalische Abstufungen (1/64, 1/32, 1/16, 1/8, 1/4, 1/2, 3/4, 1, 1.5, 2, 3, 4 Steps)

### Probability (PROB%)

Wahrscheinlichkeit, dass der Step bei jedem Durchlauf tatsächlich spielt.

- **100%:** Spielt immer
- **50%:** Spielt durchschnittlich jedes zweite Mal
- **0%:** Spielt nie

Im Step wird die Wahrscheinlichkeit als kleine Prozentzahl angezeigt (nur wenn unter 100%).

### Ratchet

Wie oft die Note innerhalb eines Steps wiederholt wird.

- **×1:** Normal (eine Note pro Step)
- **×2:** Doppelt so schnell (wie ein Drum-Roll)
- **×4:** Vierfach schnell

Im Step wird der Ratchet-Wert als kleine Zahl angezeigt (z.B. „2×").

### CC1 und CC2

Jeder Step kann zwei MIDI-CC-Werte senden (z.B. Modulation, Filter-Cutoff, Lautstärke). Bereich: 0–127.

Die CC-Nummern und Labels werden pro Spur in den **Settings** konfiguriert.

---

## 6. Timing & Rhythmus

### Step-Länge (Ratio)

Die Standard-Step-Länge ist eine Sechzehntelnote (1:1). Du kannst die Step-Länge pro Spur ändern, um andere Rhythmen zu erzeugen.

**So änderst du die Step-Länge:**

Am rechten Rand jeder Spur gibt es einen **Stretch-Handle** (vertikaler Bereich). Die linke Hälfte steuert die Step-Länge:

- **Ziehen** ändert die Ratio
- **Klick** öffnet ein Auswahlmenü

Alternativ: Ziehe den **oberen Punkt** am Ende der Step-Reihe horizontal.

**Verfügbare Ratios:**

| Ratio | Bedeutung | Geschwindigkeit |
|-------|-----------|-----------------|
| 1:2 | 32tel | 2× schneller |
| 2:3 | 16tel-Triole | 1.5× schneller |
| 3:4 | Quartole | 1.33× schneller |
| **1:1** | **16tel (Standard)** | **Normal** |
| 5:4 | Quintole | 1.25× langsamer |
| 4:3 | 8tel-Triole | 1.33× langsamer |
| 3:2 | Punktierte 16tel | 1.5× langsamer |
| 2:1 | 8tel | 2× langsamer |

Und weitere Zwischenwerte (Septolen, Nonolen).

### Polyrhythmus in der Praxis

**Das Besondere:** Jede Spur kann eine andere Step-Länge haben. Alle Spuren bleiben synchron — sie starten und laufen gleichzeitig, aber ihre Steps haben unterschiedliche Dauern.

**Beispiel:**
- Track 1: 16 Steps bei 1:1 (16tel) = 1 Takt
- Track 2: 12 Steps bei 4:3 (8tel-Triolen) = 1 Takt
- Track 3: 8 Steps bei 2:1 (8tel) = 1 Takt

Alle drei Spuren brauchen genau gleich lang für einen Durchlauf, aber erzeugen komplett unterschiedliche Rhythmen.

### Step-Anzahl

Die Anzahl der Steps pro Spur (1–64) änderst du:

- Am **Stretch-Handle** (rechte Hälfte, ziehen)
- Oder am **unteren Punkt** am Ende der Step-Reihe (horizontal ziehen)

### Swing

Der **SWING-Regler** in der Transportleiste verschiebt jede zweite Sechzehntelnote leicht nach hinten. Doppelklick setzt ihn auf 0 %.

- **0%:** Gerade, mechanisch
- **50%:** Leicht groovend
- **100%:** Maximaler Swing (nahe Triolen-Feel)

Swing wirkt global auf alle Spuren.

### Feel (Timing-Offset)

Jede Spur kann einen eigenen Timing-Offset haben (−50 bis +50 Millisekunden):

- **Negative Werte (Pushed):** Die Spur spielt leicht vor dem Beat — wirkt drängend, aggressiv.
- **Positive Werte (Laid Back):** Die Spur spielt leicht hinter dem Beat — wirkt entspannt, groovend.

Stelle den Feel ein über den **FEEL-Button** im Track-Header.

---

## 7. CC-Steuerung

### CC-Reihen anzeigen

Am rechten Rand jeder Spur gibt es einen kleinen **Pfeil** (▼/▲). Klicke darauf, um die CC-Reihen ein- oder auszuklappen.

Jede Spur hat zwei CC-Reihen (CC1 und CC2). Jeder Step hat einen eigenen Regler für den CC-Wert.

### CC-Kurven zeichnen

1. Klappe die CC-Reihen auf (▼-Pfeil).
2. Klicke auf das **Stift-Symbol** (✏️) neben dem CC-Label, um den **Draw-Modus** zu aktivieren.
3. Ziehe mit der Maus über die CC-Regler, um eine Kurve zu zeichnen.
4. Klicke erneut auf den Stift, um den Draw-Modus zu beenden.

### CC-Funktionen

In jeder CC-Reihe gibt es diese Buttons:

| Button | Funktion |
|--------|----------|
| **RND** | Zufällige CC-Werte für alle Steps |
| **NEU** | Alle CC-Werte auf 64 (Mitte) zurücksetzen |
| **📈** | Kurven-Anzeige ein/ausblenden |
| **✏️** | Draw-Modus ein/aus |
| **🔇** | CC-Reihe stumm schalten (sendet keine CC-Daten) |

### CC-Nummern konfigurieren

Öffne die **Settings** (Regler-Symbol oben rechts). Unter **CC Assignments** kannst du für jede Spur die CC-Nummern und Labels festlegen.

---

## 8. Skalen

Jede Spur kann auf eine musikalische Skala eingeschränkt werden. Wenn eine Skala aktiv ist, werden Noten automatisch auf den nächsten Skalenton quantisiert.

**Skala einstellen:**
1. Klicke auf **SCL** im Track-Header.
2. Wähle einen **Grundton** (C, C#, D, ... B).
3. Wähle eine **Skala** (Major, Minor, Dorian, etc.).

**Verfügbare Skalen:**

| Kürzel | Name | Charakter |
|--------|------|-----------|
| — | Chromatisch | Keine Einschränkung (Standard) |
| MAJ | Major (Dur) | Hell, fröhlich |
| MIN | Minor (Moll) | Dunkel, melancholisch |
| DOR | Dorian | Jazzig, warm |
| PHR | Phrygian | Spanisch, mystisch |
| LYD | Lydian | Schwebend, verträumt |
| MIX | Mixolydian | Bluesy, rockig |
| HRM | Harmonisch Moll | Dramatisch, orientalisch |
| PM+ | Pentatonik Major | Einfach, offen |
| PM- | Pentatonik Minor | Blues, Rock |
| BLU | Blues | Bluesy mit Blue Note |
| WHL | Ganzton | Impressionistisch, schwebend |

Wenn eine Skala aktiv ist, zeigt die Klaviatur im Step-Editor die skalen-fremden Töne abgedimmt an.

---

## 9. Drum-Modus (MIDI-Kanal 10)

Wenn eine Spur auf **MIDI-Kanal 10** steht, schaltet sie in den Drum-Modus:

- Step-Labels zeigen Drum-Namen statt Notennamen (z.B. „Kick", „Snare", „HH Cls")
- Der Step-Editor zeigt ein **Drum-Auswahlgitter** statt einer Klaviatur
- Die Drums folgen dem **General MIDI Drum Map**

**Drum-Gruppen:**

| Gruppe | Sounds |
|--------|--------|
| **Kick / Snare** | Kick 2, Kick, Stick, Snare, Clap, Snare 2 |
| **Hi-Hat** | HH Closed, HH Pedal, HH Open |
| **Toms** | Tom Floor Low/High, Tom Low, Tom Low-Mid, Tom Hi-Mid, Tom High |
| **Cymbals** | Crash, Crash 2, Ride, Ride 2, China, Splash, Cowbell |

---

## 10. MIDI

### MIDI-Ausgang wählen

1. Öffne **Settings** (Regler-Symbol oben rechts).
2. Unter **MIDI Output** wähle dein Gerät oder deinen virtuellen MIDI-Port.
3. FIRSTofFIFTH erstellt zusätzlich automatisch einen virtuellen MIDI-Port namens „FIRSTofFIFTH", den du in jeder DAW als Eingang wählen kannst.

### Verbindung zu einer DAW

**Ohne externes Interface:**
1. In FIRSTofFIFTH: MIDI Output auf „None" lassen (der virtuelle Port ist immer aktiv).
2. In deiner DAW: Wähle „FIRSTofFIFTH" als MIDI-Eingang auf dem gewünschten Track.

**Mit externem Gerät:**
1. In FIRSTofFIFTH: Wähle dein USB-/DIN-MIDI-Interface als Output.
2. Verbinde das Interface mit deinem Synthesizer.

### MIDI-Kanäle

Der Ausgang einer Spur wird mit der Ausgangstaste im Spurkopf gewählt: **Externes MIDI ▸ Kanal 01–16** oder ein Instrumentenkanal. Bei externem MIDI sendet die Spur auf dem gewählten Kanal; stelle sicher, dass dein Empfänger auf dem gleichen Kanal empfängt. Gehostete Instrumente spielen immer auf Kanal 1, der MIDI-Kanal der Spur spielt dort keine Rolle (ab 1.18.33).

Kanal 10 ist konventionell für Drums reserviert (General MIDI).

### Externer Clock-Modus

Wenn du FIRSTofFIFTH als **Slave** einer DAW oder eines Drum Machines nutzen möchtest:

1. Stelle den **Clock-Modus** auf **EXT** (in der Transportleiste).
2. Wähle in den **Settings** unter **MIDI Input** das Gerät, das die Clock sendet.
3. Starte die Clock auf dem externen Gerät — FIRSTofFIFTH folgt automatisch.

Das BPM-Display zeigt das erkannte Tempo des externen Masters.

### Gerätewechsel während des Spielens

Wenn du während des Spielens ein MIDI-Gerät abziehst:
- Die App zeigt eine Fehlermeldung.
- Der Ausgang wird auf „None" zurückgesetzt.
- Du musst das Gerät manuell neu auswählen.

Es gehen keine Noten verloren — sie werden nur nicht mehr gesendet.

---

## 11. MIDI Learn & CC Remote

### MIDI Learn

Mit MIDI Learn kannst du Steps oder Parameter direkt von deinem MIDI-Controller aus zuweisen:

1. Klicke auf **LEARN** in der Transportleiste (wird gelb).
2. Klicke auf den Step oder Parameter, den du zuweisen willst.
3. Drehe den Regler oder drücke die Taste auf deinem Controller.
4. Die Zuordnung wird gespeichert.
5. Klicke erneut auf **LEARN**, um den Modus zu beenden.

### CC Remote Control

In den **Settings** kannst du CC-Nummern für Fernsteuerung zuweisen:

- **Pattern Switch CC:** Ein eingehender CC wechselt das Pattern in Achterschritten (0–7 = A, 8–15 = B … 120–127 = P).
- **Mute Track CC:** Pro Spur eine CC-Nummer, um Mute per Controller zu schalten.

Setze den Wert auf **−1**, um die Fernsteuerung zu deaktivieren.

---

## 12. Presets

### Projekt speichern

- **⌘S** oder Menü **File → Save Preset**
- Wähle einen Dateinamen und Speicherort.
- Das Preset enthält: alle 16 Patterns, den Song, alle Spuren, alle Steps, BPM und Swing.

Ein orangefarbener Punkt neben dem Dateinamen zeigt an, dass es ungespeicherte Änderungen gibt.

### Projekt laden

- **⌘O** oder Menü **File → Open Preset**
- Wähle eine `.json`-Datei.
- Wenn gerade abgespielt wird, wird die Wiedergabe gestoppt.
- Alle aktuellen Daten werden durch das geladene Preset ersetzt.

### Zuletzt geöffnete Dateien

- Menü **File → Open Recent** zeigt die letzten Dateien.
- „Clear Recent" löscht die Liste.

### Ältere Presets

Presets aus früheren Versionen werden automatisch gelesen. Fehlende Felder bekommen Standardwerte. Ungültige Werte werden still korrigiert.

---

## 13. Patterns kopieren

- **⌘⌥C** — Kopiert das aktuelle Pattern
- **⌘⌥V** — Fügt das kopierte Pattern in das aktuell ausgewählte Pattern ein

So kannst du schnell Variationen erstellen: Pattern A kopieren, in Pattern B einfügen, dort verändern.

---

## 14. Typische Workflows

### Einfacher Groove

1. Erstelle eine Drum-Spur: Setze den MIDI-Kanal auf **10**.
2. Setze Kick auf Steps 1, 5, 9, 13.
3. Setze Snare auf Steps 5 und 13.
4. Setze Hi-Hat auf alle geraden Steps (2, 4, 6, 8, ...).
5. Drücke Play.

### Variation erzeugen

1. Kopiere Pattern A nach Pattern B (⌘⌥C, dann B wählen, ⌘⌥V).
2. In Pattern B: Ändere ein paar Steps, füge einen Fill hinzu.
3. Während des Spielens: Wechsle zwischen A und B für Strophe/Refrain.

### Polyrhythmischen Beat bauen

1. Track 1: 16 Steps, Ratio 1:1 (16tel) — Grundrhythmus.
2. Track 2: 12 Steps, Ratio 4:3 (8tel-Triolen) — gegenläufige Triolen.
3. Track 3: 6 Steps, Ratio 2:1 (8tel) — langsame Melodie.
4. Alle drei laufen gleichzeitig und erzeugen ein sich verschiebendes Pattern.

### Experimentell arbeiten

1. Erstelle eine Spur mit 16 Steps.
2. Klicke **RND** (Randomize) — zufällige Noten und Velocities.
3. Setze die Richtung auf **Ping-Pong** (↔).
4. Setze verschiedene Steps auf unterschiedliche **Probability** (z.B. 50%, 75%).
5. Aktiviere eine **Skala** (z.B. C Minor), damit alles harmonisch klingt.
6. Füge **Ratchets** auf einzelnen Steps hinzu für rhythmische Akzente.

### Live-Performance

1. Bereite Patterns vor (A = Intro, B = Verse, C = Chorus, D = Break).
2. Starte Playback auf Pattern A.
3. Klicke auf **B** — der Wechsel passiert am nächsten Taktanfang.
4. Mute und Unmute einzelne Spuren live mit dem **M-Button** oder per MIDI-Controller (CC Remote).

---

## 15. Tipps für die Praxis

### Schneller arbeiten

- **Leertaste** ist dein Freund — schnell Play/Stop.
- **⌥ + Klick** zum Editieren ist schneller als Rechtsklick → Edit.
- **⇧ + Klick** für Mehrfachauswahl, dann EDIT für Bulk-Änderungen.
- **CC Draw-Modus** (Stift-Symbol) ist der schnellste Weg, CC-Kurven zu erstellen.

### Besser klingende Ergebnisse

- Nutze **unterschiedliche Velocities** — nicht alle Steps auf 127. Das klingt lebendiger.
- Setze einzelne Steps auf **kurze Gate-Werte** (Short) für rhythmischen Kontrast.
- **Probability unter 100%** auf Nebenstimmen erzeugt organische Variation.
- **Feel-Offset** von +5 bis +10ms auf einer Basslinie macht den Groove entspannter.
- **Skalen** verhindern falsche Noten — besonders nützlich nach Randomize.

### Typische Fehler vermeiden

- **Kein Sound?** Prüfe: MIDI-Output gewählt? Richtiger MIDI-Kanal? Empfänger auf dem gleichen Kanal?
- **Pattern klingt anders als erwartet?** Prüfe, ob du im richtigen Pattern bist (A–P).
- **Steps klingen zu lang/kurz?** Prüfe den Gate-Wert im Step-Editor.
- **Spur klingt nicht?** Prüfe den Mute-Status (M-Button) und Solo-Status anderer Spuren.

---

## 16. Tastaturkürzel

| Kürzel | Aktion |
|--------|--------|
| **Leertaste** | Play / Stop |
| **⌘S** | Preset speichern |
| **⌘O** | Preset öffnen |
| **⌘1 / ⌘2 / ⌘3 / ⌘4** | Pattern A / B / C / D wählen |
| **⌥1 / ⌥2 / ⌥3 / ...** | Track 1 / 2 / 3 / ... muten |
| **⌘⌥C** | Pattern kopieren |
| **⌘⌥V** | Pattern einfügen |
| **⌘C** | Ausgewählte Steps kopieren |
| **⌘V** | Steps einfügen |
| **Esc** | Auswahl aufheben |
| **Enter** | Step-Editor schließen |
| **⌘⌥T** | Tooltips ein/ausblenden |
| **⌘⌥L** | Sprache wechseln (EN/DE) |
| **⌘Z** | Rückgängig (Undo) |
| **⌘⇧Z** | Wiederherstellen (Redo) |

---

## 17. Die Oberfläche im Überblick

### Transportleiste (oben)

Von links nach rechts:

1. **Logo & Dateiname** — zeigt den aktuellen Preset-Namen und einen Punkt bei ungespeicherten Änderungen
2. **Play/Stop** — startet oder stoppt die Wiedergabe
3. **BPM** — Tempo-Regler (20–300), mit Fein-Buttons (▲/▼) und TAP-Button
4. **Swing** — Swing-Regler (0–100%)
5. **Pattern** — 4 Buttons (A, B, C, D) für die Pattern-Auswahl
6. **Clock** — INT (interner Takt) oder EXT (externer MIDI-Takt)
7. **Learn** — MIDI-Learn ein/aus
8. **Width** — Schieberegler für die visuelle Step-Breite
9. **Settings** — öffnet die Einstellungen

### Spur-Header (links)

Jede Spur zeigt links:

- **Spurname** (editierbar)
- **M** (Mute) und **S** (Solo)
- **Richtungs-Buttons** (Forward, Reverse, Ping-Pong, Random)
- **Ausgang** („MIDI 05“ oder Name des Instrumentenkanals; der MIDI-Kanal steckt im Untermenü „Externes MIDI“)
- **FEEL** (Timing-Offset)
- **SCL** (Skala)
- **RND** (Randomize) und **CLR** (Clear)

### Step-Grid (Mitte)

Die Steps als farbige Kästchen. Goldene vertikale Linien markieren jeden 4. Step (Beat-Raster).

### Stretch-Handle (rechts pro Spur)

Vertikaler Bereich zum Ändern von Step-Länge (links/oben) und Step-Anzahl (rechts/unten).

### CC-Reihen (unterhalb der Steps, ausklappbar)

Zwei Reihen mit Drehreglern für CC1 und CC2 pro Step. Ausklappen mit dem **Pfeil** (▼) am rechten Rand.

### Statusleiste (unten)

Zeigt: Play-Status, BPM, Clock-Modus, aktives Pattern, MIDI-Ausgang.

---

## 18. Einstellungen (Settings)

Erreichbar über das Regler-Symbol oben rechts:

| Bereich | Einstellung |
|---------|-------------|
| **MIDI Output** | Ausgabegerät wählen |
| **MIDI Input** | Eingabegerät für externe Clock |
| **Refresh** | MIDI-Ports neu scannen |
| **CC Assignments** | CC-Nummern und Labels pro Spur (CC1, CC2) |
| **CC Remote** | Pattern-Switch-CC und Mute-CCs für Fernsteuerung |

---

## 19. Bekannte Einschränkungen

- **Externer Clock-Modus:** Bei sehr schnellem Start/Stop vom externen Master kann es in seltenen Fällen zu einer kurzen Verzögerung beim Stoppen kommen.
- **Extreme Einstellungen:** Bei 300 BPM mit 8 Spuren, 8-Noten-Akkorden und 4-fach-Ratchets auf allen Steps wird die MIDI-Datenmenge sehr hoch. In diesem Fall können einzelne Display-Updates kurz aussetzen — die Musik läuft unverändert weiter.
- **MIDI-Gerätewechsel:** Nach Abziehen eines MIDI-Geräts muss der Ausgang manuell neu gewählt werden. Es gibt keinen automatischen Reconnect.
- **Sprache:** Die App unterstützt Englisch und Deutsch. Andere Sprachen sind nicht verfügbar.

---

## 20. Systemanforderungen

- **macOS** (native App)
- MIDI-Ausgang: externes MIDI-Interface, virtueller MIDI-Port, oder DAW mit MIDI-Routing
- Kein Audio-Interface nötig (die App erzeugt keine Klänge, nur MIDI-Daten)

---

*FIRSTofFIFTH — Polyrhythmic Step Sequencer*
