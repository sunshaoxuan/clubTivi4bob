// Local stream-copy pipe. No audio/video decoder, encoder, or ASR is linked.
extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
}
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#define write _write
#define STDOUT_FILENO 1
#else
#include <unistd.h>
#endif
#include <csignal>
#include <cmath>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <cerrno>
#include <algorithm>
static volatile sig_atomic_t stopped=0;
static void stop(int){stopped=1;}
static int interrupt(void*){return stopped;}
static void safe_log(void*,int level,const char* format,va_list args){
 if(level>AV_LOG_ERROR)return;char line[512];vsnprintf(line,sizeof(line),format,args);
 if(strstr(line,"://"))return;std::string escaped;
 for(char c:std::string(line)){if(c=='"'||c=='\\')escaped+='\\';if(c=='\n'||c=='\r')escaped+=' ';else if((unsigned char)c>=32)escaped+=c;}
 fprintf(stderr,"{\"event\":\"remux_mux_diagnostic\",\"message\":\"%s\"}\n",escaped.c_str());
}
static int open_resource(AVFormatContext* context,AVIOContext** io,const char* url,int flags,AVDictionary** options){
 av_dict_set(options,"tls_verify","1",0);return avio_open2(io,url,flags,&context->interrupt_callback,options);
}
static int output(void*,uint8_t* data,int size){
 int done=0;while(done<size&&!stopped){auto n=write(STDOUT_FILENO,data+done,size-done);if(n<0){if(errno==EINTR)continue;return AVERROR(errno);}done+=n;}
 return stopped?AVERROR_EXIT:done;
}
static void check(int status,const char* label){if(status<0){fprintf(stderr,"{\"event\":\"remux_error\",\"stage\":\"%s\",\"code\":%d}\n",label,status);std::exit(2);}}
static void learn_aac(AVCodecParameters* par,const AVPacket* packet){
 if(par->codec_id!=AV_CODEC_ID_AAC||par->sample_rate>0)return;
 static const int rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
 for(int j=0;j+7<=packet->size&&j<64;j++){
  auto* b=packet->data+j;if(b[0]!=0xff||(b[1]&0xf6)!=0xf0)continue;
  int frequency=(b[2]>>2)&15,channels=((b[2]&1)<<2)|(b[3]>>6);if(frequency>=13||channels==0)continue;
  par->sample_rate=rates[frequency];par->profile=(b[2]>>6)&3;par->frame_size=1024;av_channel_layout_default(&par->ch_layout,channels==7?8:channels);break;
 }
}
int main(int argc,char**argv){
 if(argc!=2||std::string(argv[1]).rfind("http://127.0.0.1:",0)!=0)return 2;
 #ifdef _WIN32
 _setmode(_fileno(stdout),_O_BINARY);
#else
 signal(SIGPIPE,stop);
#endif
 signal(SIGTERM,stop);signal(SIGINT,stop);av_log_set_level(AV_LOG_ERROR);av_log_set_callback(safe_log);avformat_network_init();
 AVFormatContext* in=avformat_alloc_context();in->io_open=open_resource;in->interrupt_callback={interrupt,nullptr};AVDictionary* opts=nullptr;
 av_dict_set(&opts,"analyzeduration","1000000",0);av_dict_set(&opts,"probesize","524288",0);av_dict_set(&opts,"allowed_extensions","ALL",0);av_dict_set(&opts,"prefer_x_start","1",0);av_dict_set(&opts,"seg_max_retry","5",0);av_dict_set(&opts,"rw_timeout","8000000",0);
 check(avformat_open_input(&in,argv[1],nullptr,&opts),"open_input");av_dict_free(&opts);check(avformat_find_stream_info(in,nullptr),"stream_info");
 std::vector<AVPacket*> queued;
 auto missing_audio=[&](){for(unsigned i=0;i<in->nb_streams;i++)if(in->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO&&in->streams[i]->codecpar->sample_rate<=0)return true;return false;};
 while(missing_audio()&&queued.size()<512){auto* p=av_packet_alloc();check(av_read_frame(in,p),"audio_header_packet");queued.push_back(p);learn_aac(in->streams[p->stream_index]->codecpar,p);}
 if(missing_audio())check(AVERROR_INVALIDDATA,"audio_header_missing");
 AVFormatContext* out=nullptr;check(avformat_alloc_output_context2(&out,nullptr,"mpegts",nullptr),"allocate_output");
 std::vector<int> map(in->nb_streams,-1);int video=-1,audio=-1;
 for(unsigned i=0;i<in->nb_streams;i++){
  auto* src=in->streams[i];int* chosen=src->codecpar->codec_type==AVMEDIA_TYPE_VIDEO?&video:src->codecpar->codec_type==AVMEDIA_TYPE_AUDIO?&audio:nullptr;
  if(!chosen||*chosen>=0)continue;auto* dst=avformat_new_stream(out,nullptr);if(!dst)return 2;*chosen=dst->index;map[i]=dst->index;
  check(avcodec_parameters_copy(dst->codecpar,src->codecpar),"copy_codec");dst->codecpar->codec_tag=0;dst->time_base=src->time_base;
 }
 auto* buffer=(unsigned char*)av_malloc(32768);auto* io=avio_alloc_context(buffer,32768,1,nullptr,nullptr,output,nullptr);if(!io)return 2;
 out->pb=io;out->flags|=AVFMT_FLAG_CUSTOM_IO;out->flush_packets=1;out->max_delay=100000;
 av_dict_set(&opts,"mpegts_flags","+resend_headers",0);check(avformat_write_header(out,&opts),"write_header");av_dict_free(&opts);
 double origin=in->start_time!=AV_NOPTS_VALUE?-in->start_time/(double)AV_TIME_BASE:NAN;
 std::vector<double> shifts(in->nb_streams,origin),last(out->nb_streams,NAN),duration(out->nb_streams,0);
 std::vector<int64_t> ticks(out->nb_streams,AV_NOPTS_VALUE);auto* packet=av_packet_alloc();long count=0;size_t queued_index=0;
 while(!stopped){
  int status=0;if(queued_index<queued.size()){av_packet_move_ref(packet,queued[queued_index]);av_packet_free(&queued[queued_index++]);}else status=av_read_frame(in,packet);
  if(status==AVERROR_EOF||stopped)break;check(status,"read_frame");
  // A new movie can introduce new TS PIDs. Map them onto the same output AV
  // streams, with independent input clock offsets and monotonic output DTS.
  while(map.size()<in->nb_streams){unsigned i=map.size();auto* par=in->streams[i]->codecpar;int target=par->codec_type==AVMEDIA_TYPE_VIDEO?video:par->codec_type==AVMEDIA_TYPE_AUDIO?audio:-1;
   if(target>=0&&par->codec_id!=out->streams[target]->codecpar->codec_id)check(AVERROR_INVALIDDATA,"codec_changed");
   map.push_back(target);shifts.push_back(NAN);fprintf(stderr,"{\"event\":\"remux_stream_changed\",\"input\":%u,\"output\":%d,\"pid\":%d}\n",i,target,in->streams[i]->id);
  }
  int index=packet->stream_index;if(index<0||index>=(int)map.size()||map[index]<0){av_packet_unref(packet);continue;}int target=map[index];auto* src=in->streams[index];auto* dst=out->streams[target];learn_aac(src->codecpar,packet);double unit=av_q2d(src->time_base);
  int64_t stamp=packet->dts!=AV_NOPTS_VALUE?packet->dts:packet->pts;
  if(stamp==AV_NOPTS_VALUE){av_packet_unref(packet);continue;}
  double original=stamp*unit;if(!std::isfinite(shifts[index]))shifts[index]=std::isfinite(last[target])?last[target]+duration[target]-original:-original;
  double current=original+shifts[index];double step=packet->duration>0?packet->duration*unit:src->codecpar->codec_type==AVMEDIA_TYPE_AUDIO?1024./std::max(1,src->codecpar->sample_rate):.04;
  if(std::isfinite(last[target])){double delta=current-last[target]-duration[target];if(delta>10||delta< -1){shifts[index]-=delta;current-=delta;fprintf(stderr,"{\"event\":\"remux_discontinuity\",\"stream\":%d,\"removedSeconds\":%.9f,\"outputDts\":%.9f,\"packets\":%ld}\n",target,delta,current,count);}}
  // Unwrap PTS relative to DTS before applying the common packet shift.
  if(packet->pts!=AV_NOPTS_VALUE&&packet->dts!=AV_NOPTS_VALUE){double relative=(packet->pts-packet->dts)*unit;double wrap=(1LL<<33)/90000.;if(std::abs(relative)>wrap/2)packet->pts=packet->dts+llround(std::remainder(relative,wrap)/unit);}
  int64_t offset=llround(shifts[index]/unit);if(packet->pts!=AV_NOPTS_VALUE)packet->pts+=offset;if(packet->dts!=AV_NOPTS_VALUE)packet->dts+=offset;
  av_packet_rescale_ts(packet,src->time_base,dst->time_base);packet->stream_index=target;packet->pos=-1;
  if(packet->dts==AV_NOPTS_VALUE)packet->dts=packet->pts;
  if(ticks[target]!=AV_NOPTS_VALUE&&packet->dts<=ticks[target]){
   int64_t adjustment=ticks[target]+std::max<int64_t>(1,llround(step/av_q2d(dst->time_base)))-packet->dts;
   shifts[index]+=adjustment*av_q2d(dst->time_base);packet->dts+=adjustment;if(packet->pts!=AV_NOPTS_VALUE)packet->pts+=adjustment;
   fprintf(stderr,"{\"event\":\"remux_packet_adjusted\",\"stream\":%d,\"seconds\":%.9f}\n",target,adjustment*av_q2d(dst->time_base));
  }
  if(packet->pts==AV_NOPTS_VALUE||packet->pts<packet->dts)packet->pts=packet->dts;
  int64_t next=packet->dts;double position=next*av_q2d(dst->time_base);
  status=av_interleaved_write_frame(out,packet);av_packet_unref(packet);if(stopped)break;check(status,"write_frame");ticks[target]=next;last[target]=position;duration[target]=step;count++;
 }
 av_packet_free(&packet);av_write_trailer(out);avio_flush(io);av_freep(&io->buffer);avio_context_free(&io);avformat_free_context(out);avformat_close_input(&in);return 0;
}
