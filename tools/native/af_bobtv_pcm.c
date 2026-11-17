/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Bounded decoded audio tap. The original frame and audible samples pass unchanged.
 * A rolling mono 16 kHz window is exported through mpv filter metadata, before mute.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "libavutil/base64.h"
#include "libavutil/dict.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libswresample/swresample.h"
#include "audio.h"
#include "avfilter.h"
#include "internal.h"
#define RATE 16000
#define CAPACITY 32000

typedef struct BobPCM {
    SwrContext *swr;
    AVDictionary *metadata;
    int16_t ring[CAPACITY], ordered[CAPACITY];
    float mono[32768];
    int16_t converted[32768];
    char encoded[AV_BASE64_SIZE(CAPACITY*2)];
    int head, count, since, epoch;
    int64_t sequence;
    double end, expected;
} BobPCM;
static int config_input(AVFilterLink *link) {
    BobPCM *s=link->dst->priv;
    AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
    int r=swr_alloc_set_opts2(&s->swr,&mono,AV_SAMPLE_FMT_S16,RATE,&mono,AV_SAMPLE_FMT_FLT,link->sample_rate,0,NULL);
    s->expected=NAN;
    return r<0?r:swr_init(s->swr);
}
static float value(const AVFrame *f,int i,int channels) {
    int planar=av_sample_fmt_is_planar(f->format);
    const void *p=f->extended_data[0]; int n=planar?i:i*channels;
    switch(av_get_packed_sample_fmt(f->format)) {
      case AV_SAMPLE_FMT_S16:return ((const int16_t*)p)[n]/32768.f;
      case AV_SAMPLE_FMT_S32:return ((const int32_t*)p)[n]/2147483648.f;
      case AV_SAMPLE_FMT_FLT:return ((const float*)p)[n];
      case AV_SAMPLE_FMT_DBL:return ((const double*)p)[n];
      default:return 0;
    }
}
static int filter_frame(AVFilterLink *link,AVFrame *frame) {
    BobPCM *s=link->dst->priv;char text[80];
    double pts=frame->pts==AV_NOPTS_VALUE?NAN:frame->pts*av_q2d(link->time_base);
    if(isfinite(pts)&&frame->nb_samples<=32768) {
      if(isfinite(s->expected)&&fabs(pts-s->expected)>.15) {
        s->head=s->count=s->since=0;s->epoch++;swr_close(s->swr);swr_init(s->swr);
      }
      double delay=swr_get_delay(s->swr,link->sample_rate)/(double)link->sample_rate;
      for(int i=0;i<frame->nb_samples;i++)s->mono[i]=value(frame,i,link->ch_layout.nb_channels);
      const uint8_t *in=(const uint8_t*)s->mono;uint8_t *out=(uint8_t*)s->converted;
      int n=swr_convert(s->swr,&out,32768,&in,frame->nb_samples);
      if(n>0) {
        for(int i=0;i<n;i++){s->ring[s->head]=s->converted[i];s->head=(s->head+1)%CAPACITY;s->count=FFMIN(CAPACITY,s->count+1);}
        s->end=pts-delay+n/(double)RATE;s->since+=n;
      }
      s->expected=pts+frame->nb_samples/(double)link->sample_rate;
      if(s->since>=RATE/5) {
        s->since=0;s->sequence++;
        for(int i=0;i<s->count;i++)s->ordered[i]=s->ring[(s->head-s->count+i+CAPACITY)%CAPACITY];
        av_base64_encode(s->encoded,sizeof(s->encoded),(const uint8_t*)s->ordered,s->count*2);
        av_dict_set(&frame->metadata,"lavfi.bobtv_pcm.pcm",s->encoded,0);
        snprintf(text,sizeof(text),"%.9f",s->end-s->count/(double)RATE);av_dict_set(&frame->metadata,"lavfi.bobtv_pcm.start",text,0);
        snprintf(text,sizeof(text),"%.9f",s->end);av_dict_set(&frame->metadata,"lavfi.bobtv_pcm.end",text,0);
        snprintf(text,sizeof(text),"%lld",(long long)s->sequence);av_dict_set(&frame->metadata,"lavfi.bobtv_pcm.sequence",text,0);
        snprintf(text,sizeof(text),"%d",s->epoch);av_dict_set(&frame->metadata,"lavfi.bobtv_pcm.epoch",text,0);
        av_dict_free(&s->metadata);av_dict_copy(&s->metadata,frame->metadata,0);
      } else {av_dict_copy(&frame->metadata,s->metadata,0);}
    }
    return ff_filter_frame(link->dst->outputs[0],frame);
}
static av_cold void uninit(AVFilterContext *ctx){BobPCM *s=ctx->priv;swr_free(&s->swr);av_dict_free(&s->metadata);}
static const AVFilterPad inputs[]={{.name="default",.type=AVMEDIA_TYPE_AUDIO,.config_props=config_input,.filter_frame=filter_frame}};
static const AVFilterPad outputs[]={{.name="default",.type=AVMEDIA_TYPE_AUDIO}};
const AVFilter ff_af_bobtv_pcm={.name="bobtv_pcm",.description=NULL_IF_CONFIG_SMALL("Export bounded decoded PCM with timestamps without changing audible audio."),
 .priv_size=sizeof(BobPCM),.uninit=uninit,FILTER_INPUTS(inputs),FILTER_OUTPUTS(outputs),
 FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_S16,AV_SAMPLE_FMT_S16P,AV_SAMPLE_FMT_S32,AV_SAMPLE_FMT_S32P,AV_SAMPLE_FMT_FLT,AV_SAMPLE_FMT_FLTP,AV_SAMPLE_FMT_DBL,AV_SAMPLE_FMT_DBLP),.flags=AVFILTER_FLAG_METADATA_ONLY};
