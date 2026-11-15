# Drittbibliotheken (vendored, unverändert)

| Bibliothek | Version | Commit | Lizenz |
|---|---|---|---|
| [signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) | 1.4.0 | a670068d9aeb64913331d5cc29337b19a457a7df | MIT (`signalsmith-stretch/LICENSE-signalsmith-stretch.txt`) |
| [signalsmith-linear](https://github.com/Signalsmith-Audio/linear) | 0.6.4 | de55e6a50ffcf6f8f43f649692d94691c7025151 | MIT (`signalsmith-linear/LICENSE-signalsmith-linear.txt`) |

Nur Header, Dateien unverändert übernommen (Lizenzdateien umbenannt, damit sie im App-Bundle
nicht kollidieren; `platform/linear-xsimd-dispatch.cpp` und Tests weggelassen). Benutzt von
`Engine/AudioLoop/LoopStretch.cpp` (Zeitdehnung der Audio-Loops, ab v1.18.13) mit
`SIGNALSMITH_USE_ACCELERATE`. Suchpfade: `ThirdParty` und `ThirdParty/signalsmith-linear/include`.
