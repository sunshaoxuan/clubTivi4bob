/* SPDX-License-Identifier: LGPL-2.1-or-later
 * BobTV real PCM spectrum analyzer for FFmpeg 6.0.
 * Reads samples and adds metadata; forwards the original AVFrame unchanged.
 */
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"
#include "libavutil/tx.h"
#include "audio.h"
#include "avfilter.h"
#include "internal.h"

#define FFT_SIZE 8192
#define BANDS 128

typedef struct BobSpectrum {
    AVTXContext *tx;
    av_tx_fn transform;
    AVComplexFloat *input, *output;
    float *ring;
    float window[FFT_SIZE];
    double power[FFT_SIZE / 2 + 1];
    double levels[BANDS];
    int channels, rate, position, filled, since_fft, ready;
} BobSpectrum;

static int config_input(AVFilterLink *inlink)
{
    BobSpectrum *s = inlink->dst->priv;
    int ret;
    s->channels = inlink->ch_layout.nb_channels;
    s->rate = inlink->sample_rate;
    s->ring = av_calloc(s->channels * FFT_SIZE, sizeof(float));
    s->input = av_calloc(FFT_SIZE, sizeof(*s->input));
    s->output = av_calloc(FFT_SIZE, sizeof(*s->output));
    if (!s->ring || !s->input || !s->output) return AVERROR(ENOMEM);
    for (int i = 0; i < FFT_SIZE; i++)
        s->window[i] = 0.5f - 0.5f * cos(2 * M_PI * i / FFT_SIZE);
    for (int i = 0; i < BANDS; i++) s->levels[i] = -INFINITY;
    ret = av_tx_init(&s->tx, &s->transform, AV_TX_FLOAT_FFT, 0, FFT_SIZE, NULL, AV_TX_UNALIGNED);
    return ret;
}

static float sample_value(const AVFrame *frame, int channel, int index, int channels)
{
    int planar = av_sample_fmt_is_planar(frame->format);
    const void *data = frame->extended_data[planar ? channel : 0];
    int offset = planar ? index : index * channels + channel;
    switch (av_get_packed_sample_fmt(frame->format)) {
        case AV_SAMPLE_FMT_S16: return ((const int16_t *)data)[offset] / 32768.f;
        case AV_SAMPLE_FMT_S32: return ((const int32_t *)data)[offset] / 2147483648.f;
        case AV_SAMPLE_FMT_FLT: return ((const float *)data)[offset];
        case AV_SAMPLE_FMT_DBL: return ((const double *)data)[offset];
        default: return 0;
    }
}

static void analyze(BobSpectrum *s)
{
    memset(s->power, 0, sizeof(s->power));
    for (int channel = 0; channel < s->channels; channel++) {
        for (int i = 0; i < FFT_SIZE; i++) {
            s->input[i].re = s->ring[channel * FFT_SIZE + (s->position + i) % FFT_SIZE] * s->window[i];
            s->input[i].im = 0;
        }
        s->transform(s->tx, s->output, s->input, sizeof(AVComplexFloat));
        // Combine channel energies after FFT, retaining opposite stereo phases.
        for (int k = 0; k <= FFT_SIZE / 2; k++) {
            double re = s->output[k].re, im = s->output[k].im;
            s->power[k] += (re * re + im * im) / s->channels;
        }
    }
    for (int band = 0; band < BANDS; band++) {
        double center = 40 * pow(400., (double)band / (BANDS - 1));
        double low = 40 * pow(400., (band - 0.5) / (BANDS - 1));
        double high = 40 * pow(400., (band + 0.5) / (BANDS - 1));
        int first = FFMAX(1, (int)ceil(low * FFT_SIZE / s->rate));
        int last = FFMIN(FFT_SIZE / 2, (int)floor(high * FFT_SIZE / s->rate));
        double energy = 0;
        if (center >= s->rate * 0.5) { s->levels[band] = -INFINITY; continue; }
        // Below FFT resolution, use the nearest measured bin; never invent data.
        if (first > last) first = last = av_clip((int)lrint(center * FFT_SIZE / s->rate), 1, FFT_SIZE / 2);
        for (int k = first; k <= last; k++) energy += s->power[k];
        energy *= 2. / (FFT_SIZE * (double)FFT_SIZE * 0.375);
        s->levels[band] = energy > 0 ? 10 * log10(energy) : -INFINITY;
    }
    s->ready = 1;
}

static int filter_frame(AVFilterLink *inlink, AVFrame *frame)
{
    BobSpectrum *s = inlink->dst->priv;
    char key[64], value[64];
    for (int i = 0; i < frame->nb_samples; i++) {
        for (int channel = 0; channel < s->channels; channel++)
            s->ring[channel * FFT_SIZE + s->position] = sample_value(frame, channel, i, s->channels);
        s->position = (s->position + 1) % FFT_SIZE;
        s->filled = FFMIN(FFT_SIZE, s->filled + 1);
        s->since_fft++;
    }
    if (s->filled == FFT_SIZE && s->since_fft >= s->rate / 25) {
        analyze(s);
        s->since_fft = 0;
    }
    av_dict_set(&frame->metadata, "lavfi.bobtv_spectrum.ready", s->ready ? "1" : "0", 0);
    for (int i = 0; i < BANDS; i++) {
        snprintf(key, sizeof(key), "lavfi.bobtv_spectrum.%d", i);
        snprintf(value, sizeof(value), "%.6f", s->levels[i]);
        av_dict_set(&frame->metadata, key, value, 0);
    }
    return ff_filter_frame(inlink->dst->outputs[0], frame);
}

static av_cold void uninit(AVFilterContext *ctx)
{
    BobSpectrum *s = ctx->priv;
    av_tx_uninit(&s->tx);
    av_freep(&s->input); av_freep(&s->output); av_freep(&s->ring);
}

static const AVFilterPad inputs[] = {
    { .name = "default", .type = AVMEDIA_TYPE_AUDIO, .config_props = config_input, .filter_frame = filter_frame },
};
static const AVFilterPad outputs[] = {
    { .name = "default", .type = AVMEDIA_TYPE_AUDIO },
};
const AVFilter ff_af_bobtv_spectrum = {
    .name = "bobtv_spectrum",
    .description = NULL_IF_CONFIG_SMALL("Measure 128 log-spaced FFT bands without changing audio."),
    .priv_size = sizeof(BobSpectrum),
    .uninit = uninit,
    FILTER_INPUTS(inputs), FILTER_OUTPUTS(outputs),
    FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P,
                      AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP),
    .flags = AVFILTER_FLAG_METADATA_ONLY,
};
