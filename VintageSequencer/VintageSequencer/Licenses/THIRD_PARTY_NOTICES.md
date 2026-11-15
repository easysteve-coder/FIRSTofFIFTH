# FIRSTofFIFTH — Lizenz und Drittkomponenten / License and third-party notices

Stand: v1.18.32 (15.11.2026). Diese Datei liegt im Quellcode und im App-Bundle
(`FIRSTofFIFTH.app/Contents/Resources/`). Sie dokumentiert die Lizenzlage nach bestem Wissen; sie
ist keine Rechtsberatung und keine rechtliche Freigabe.

## FIRSTofFIFTH

Copyright © 2026 Stephan Schmitt

FIRSTofFIFTH is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version (GPL-3.0-or-later). FoF verzichtet auf Kopfzeilen je
Quelldatei; diese Angabe gilt für den gesamten eigenen Quellcode.
Full text: `LICENSE` (repository root) and `LICENSE-FIRSTofFIFTH-GPL-3.0.txt` (this folder, app
bundle). Source code: https://github.com/easysteve-coder/FIRSTofFIFTH

## Mitgelieferte bzw. eingebundene Komponenten / Bundled components

### swift-atomics

- Version 1.3.0, revision `b601256eab081c0f92f059e12818ac1d4f178ff7`
  (gepinnt in `FIRSTofFIFTH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
  Anforderung im Projekt: „up to next major" ab 1.x).
- https://github.com/apple/swift-atomics
- Copyright (c) 2020–2025 Apple Inc. and the Swift project authors
- License: Apache License 2.0 with Runtime Library Exception. Full text:
  `LICENSE-swift-atomics.txt` (this folder, app bundle; unverändert aus dem Paket 1.3.0).
- Einbindung: nicht im Repository enthalten, Swift Package Manager lädt den Quellcode beim Bauen.
  In der App ist er in die ausführbare Datei kompiliert. Für diesen Fall erlaubt die Runtime
  Library Exception die Weitergabe ohne die Attribution nach Abschnitt 4(a), 4(b) und 4(d) der
  Apache-Lizenz. FoF legt Lizenztext und Hinweis trotzdem bei (freiwillig, schadet nicht).

### Signalsmith Stretch

- Version 1.4.0, commit `a670068d9aeb64913331d5cc29337b19a457a7df` — Zeitdehnung der Audio-Loops
  (seit v1.18.13).
- https://github.com/Signalsmith-Audio/signalsmith-stretch
- Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd.
- License: MIT. Full text: `ThirdParty/signalsmith-stretch/LICENSE-signalsmith-stretch.txt`
  (Quellcode) bzw. `LICENSE-signalsmith-stretch.txt` (App-Bundle).
- Einbindung: Header unverändert im Repository (`ThirdParty/`), in die App kompiliert. MIT
  verlangt den Copyright- und Erlaubnishinweis in allen Kopien — deshalb in Quellcode und Bundle.

### Signalsmith Linear

- Version 0.6.4, commit `de55e6a50ffcf6f8f43f649692d94691c7025151` (Abhängigkeit von Signalsmith
  Stretch).
- https://github.com/Signalsmith-Audio/linear
- Copyright (c) 2025 Signalsmith Audio
- License: MIT. Full text: `ThirdParty/signalsmith-linear/LICENSE-signalsmith-linear.txt`
  (Quellcode) bzw. `LICENSE-signalsmith-linear.txt` (App-Bundle).

### Systembibliotheken

Apple-Frameworks (SwiftUI, AVFoundation, CoreMIDI, AudioToolbox, Accelerate …) gehören zum
Betriebssystem und werden nicht mitgeliefert.

## Nicht Teil von FIRSTofFIFTH / Not part of FIRSTofFIFTH

Audio-Unit-Plug-ins (z. B. Odin 2, Decent Sampler, UAD), Sample-Bibliotheken und Instrumente
(z. B. Battery-, EXS- oder Decent-Sampler-Inhalte) sowie mit FoF erstellte Projekte und Presets
der Nutzer sind nicht Bestandteil von FIRSTofFIFTH, nicht im Repository und nicht in den
Veröffentlichungsartefakten. FoF lädt Plug-ins, die auf dem jeweiligen Rechner installiert sind;
für sie gelten deren eigene Lizenzen.
