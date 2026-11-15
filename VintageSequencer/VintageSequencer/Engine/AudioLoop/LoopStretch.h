// Zeitdehnung der Audio-Loops (v1.18.13): schlanke C-Schnittstelle zu Signalsmith Stretch
// (MIT, vendored unter ThirdParty/). Anlegen/Freigeben nur auf Main; alle übrigen Aufrufe aus
// genau einem Render-Thread. `fof_stretch_process` und `fof_stretch_output_seek` allokieren
// nicht (gemessen, v1.18.13), solange nicht transponiert wird.
#ifndef FOF_LOOP_STRETCH_H
#define FOF_LOOP_STRETCH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FoFStretch FoFStretch;

/// Stereo-Stretcher mit fester Blockgröße (Frames) und Analyseabstand.
FoFStretch *fof_stretch_create(int channels, int blockSamples, int intervalSamples);
void fof_stretch_destroy(FoFStretch *s);
/// Latenzen: Ausgabe zur Zeit t zeigt das Material bei Cursor(t) − (Eingang + Ausgang × Verhältnis).
int fof_stretch_input_latency(const FoFStretch *s);
int fof_stretch_output_latency(const FoFStretch *s);
void fof_stretch_reset(FoFStretch *s);
/// `inputFrames` Eingangs- zu `outputFrames` Ausgangsframes; Verhältnis = inputFrames / outputFrames.
void fof_stretch_process(FoFStretch *s, const float *const *inputs, int inputFrames,
                         float *const *outputs, int outputFrames);
/// Setzt neu auf: die nächste Ausgabe beginnt mit dem ersten Eingangsframe. Länge siehe
/// `fof_stretch_output_seek_length`.
void fof_stretch_output_seek(FoFStretch *s, const float *const *inputs, int inputFrames);
int fof_stretch_output_seek_length(const FoFStretch *s, double rate);

/// Vorberechnung (v1.18.15, nicht Echtzeit, allokiert): dehnt einen Loop von `inFrames` auf
/// `outFrames` Frames, nahtlos umlaufend. Feineres Analyseraster als im Echtzeitweg, drei
/// Umläufe, ausgegeben wird der mittlere; der Anfang blendet aus der Fortsetzung des Endes über.
/// Ausgabe(k) entspricht Material(k × inFrames / outFrames). Rückgabe 0 bei ungültigen Werten.
int fof_stretch_render_loop(int channels, double sampleRate, const float *const *inputs, int inFrames,
                            float *const *outputs, int outFrames);

#ifdef __cplusplus
}
#endif
#endif
