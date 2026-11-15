// Zeitdehnung der Audio-Loops (v1.18.13) — siehe LoopStretch.h.
#define SIGNALSMITH_USE_ACCELERATE 1
#include "LoopStretch.h"
#include "signalsmith-stretch/signalsmith-stretch.h"
#include <vector>

struct FoFStretch {
    // Fester Startwert: gleiche Eingabe → gleiche Ausgabe (Tests, Vergleich Echtzeit/Offline).
    signalsmith::stretch::SignalsmithStretch<float> impl{20261114};
};

namespace {
// Signalsmith erwartet `inputs[c]` als Zeiger auf Kanal c.
struct ConstChannels {
    const float *const *p;
    const float *operator[](int c) const { return p[c]; }
};
struct Channels {
    float *const *p;
    float *operator[](int c) const { return p[c]; }
};
}

extern "C" {

FoFStretch *fof_stretch_create(int channels, int blockSamples, int intervalSamples) {
    auto *s = new FoFStretch();
    s->impl.configure(channels, blockSamples, intervalSamples);
    return s;
}

void fof_stretch_destroy(FoFStretch *s) { delete s; }

int fof_stretch_input_latency(const FoFStretch *s) { return s->impl.inputLatency(); }
int fof_stretch_output_latency(const FoFStretch *s) { return s->impl.outputLatency(); }
void fof_stretch_reset(FoFStretch *s) { s->impl.reset(); }

void fof_stretch_process(FoFStretch *s, const float *const *inputs, int inputFrames,
                         float *const *outputs, int outputFrames) {
    s->impl.process(ConstChannels{inputs}, inputFrames, Channels{outputs}, outputFrames);
}

void fof_stretch_output_seek(FoFStretch *s, const float *const *inputs, int inputFrames) {
    s->impl.outputSeek(ConstChannels{inputs}, inputFrames);
}

int fof_stretch_output_seek_length(const FoFStretch *s, double rate) {
    return s->impl.outputSeekLength(static_cast<float>(rate));
}

int fof_stretch_render_loop(int channels, double sampleRate, const float *const *inputs, int inFrames,
                            float *const *outputs, int outFrames) {
    if (channels < 1 || inFrames < 1 || outFrames < 1 || !(sampleRate > 0)) return 0;
    try {   // Speichermangel: sauber 0, der Loop bleibt bei der Echtzeitdehnung (Codex R15-02)
    const int cycles = 3;
    signalsmith::stretch::SignalsmithStretch<float> st{20261114};
    // Block wie Echtzeit (120 ms), Analyseabstand halbiert (15 ms statt 30 ms): mehr Überlappung.
    st.configure(channels, static_cast<int>(sampleRate * 0.12), static_cast<int>(sampleRate * 0.015));
    // Je Kanal einzeln anlegen: `vector(n, vector(m))` hielte eine temporäre Kopiervorlage
    // zusätzlich im Speicher (Codex R15-02, Spitzenbedarf).
    std::vector<std::vector<float>> in(channels), out(channels);
    for (int c = 0; c < channels; ++c) {
        in[c].resize(size_t(cycles) * inFrames);
        out[c].resize(size_t(cycles) * outFrames);
    }
    for (int c = 0; c < channels; ++c)
        for (int k = 0; k < cycles; ++k)
            std::copy(inputs[c], inputs[c] + inFrames, in[c].begin() + size_t(k) * inFrames);
    struct VecIn { std::vector<std::vector<float>> &v; const float *operator[](int c) const { return v[c].data(); } };
    struct VecOut { std::vector<std::vector<float>> &v; float *operator[](int c) const { return v[c].data(); } };
    if (!st.exact(VecIn{in}, cycles * inFrames, VecOut{out}, cycles * outFrames)) return 0;
    // Mittlerer Umlauf; die ersten `fade` Frames blenden aus der Fortsetzung des Endes
    // (dritter Umlauf) über, damit Ende → Anfang lückenlos anschließt.
    const int fade = std::min(outFrames / 4, static_cast<int>(sampleRate * 0.02));
    for (int c = 0; c < channels; ++c) {
        const float *mid = out[c].data() + outFrames, *next = out[c].data() + 2 * size_t(outFrames);
        for (int k = 0; k < outFrames; ++k) {
            if (k < fade) {
                float g = float(k) / float(fade);
                outputs[c][k] = mid[k] * g + next[k] * (1 - g);
            } else {
                outputs[c][k] = mid[k];
            }
        }
    }
    return 1;
    } catch (...) {
        return 0;
    }
}

}
