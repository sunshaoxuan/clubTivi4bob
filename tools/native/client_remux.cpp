// Single local stream-copy pipe. No decoding, encoding, or ASR here.
extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
}
#include <unistd.h>
#include <csignal>
#include <cmath>
#include <cstdio>
#include <vector>
#include <string>
#include <cerrno>
static volatile sig_atomic_t stopped=0;
static void stop(int){stopped=1;}
static int interrupt(void*){return stopped;}
static int open_resource(AVFormatContext* context,AVIOContext** io,const char* url,int flags,AVDictionary** options){
 av_dict_set(options,"tls_verify","1",0);
 return avio_open2(io,url,flags,&context->interrupt_callback,options);
}
static int output(void*,uint8_t* data,int size){
 int done=0;
 while(done<size&&!stopped){auto n=write(STDOUT_FILENO,data+done,size-done);if(n<0){if(errno==EINTR)continue;return AVERROR(errno);}done+=n;}
 return done;
}
static void check(int status,const char* label){if(status<0){char error[256];av_strerror(status,error,sizeof(error));fprintf(stderr,"{\"event\":\"remux_error\",\"stage\":\"%s\",\"code\":%d}\n",label,status);std::exit(2);}}
int main(int argc,char**argv){
 if(argc!=2||std::string(argv[1]).rfind("http://127.0.0.1:",0)!=0)return 2;
 signal(SIGTERM,stop);signal(SIGINT,stop);signal(SIGPIPE,stop);av_log_set_level(AV_LOG_ERROR);
 avformat_network_init();AVFormatContext* in=avformat_alloc_context();in->io_open=open_resource;in->interrupt_callback={interrupt,nullptr};AVDictionary* opts=nullptr;
 av_dict_set(&opts,"analyzeduration","1000000",0);av_dict_set(&opts,"probesize","524288",0);av_dict_set(&opts,"allowed_extensions","ALL",0);av_dict_set(&opts,"prefer_x_start","1",0);av_dict_set(&opts,"seg_max_retry","5",0);av_dict_set(&opts,"rw_timeout","8000000",0);
 check(avformat_open_input(&in,argv[1],nullptr,&opts),"open_input");av_dict_free(&opts);check(avformat_find_stream_info(in,nullptr),"stream_info");
 // AAC framing supplies these fields without invoking an audio decoder.
 std::vector<AVPacket*> queued;
 auto missing_audio=[&](){for(unsigned i=0;i<in->nb_streams;i++)if(in->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO&&in->streams[i]->codecpar->sample_rate<=0)return true;return false;};
 while(missing_audio()&&queued.size()<512){
  auto* p=av_packet_alloc();check(av_read_frame(in,p),"audio_header_packet");queued.push_back(p);auto* par=in->streams[p->stream_index]->codecpar;
  if(par->codec_id==AV_CODEC_ID_AAC&&par->sample_rate<=0){
   static const int rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
   for(int j=0;j+7<=p->size&&j<64;j++){
    auto* b=p->data+j;if(b[0]!=0xff||(b[1]&0xf6)!=0xf0)continue;
    int frequency=(b[2]>>2)&15;int channels=((b[2]&1)<<2)|(b[3]>>6);
    if(frequency>=13||channels==0)continue;
    par->sample_rate=rates[frequency];par->profile=(b[2]>>6)&3;par->frame_size=1024;
    av_channel_layout_default(&par->ch_layout,channels==7?8:channels);break;
   }
  }
 }
 if(missing_audio())check(AVERROR_INVALIDDATA,"audio_header_missing");
 AVFormatContext* out=nullptr;check(avformat_alloc_output_context2(&out,nullptr,"mpegts",nullptr),"allocate_output");
 std::vector<int> map(in->nb_streams,-1);std::vector<double> last(in->nb_streams,NAN),duration(in->nb_streams,0);
 for(unsigned i=0;i<in->nb_streams;i++){
  auto* src=in->streams[i];auto kind=src->codecpar->codec_type;if(kind!=AVMEDIA_TYPE_VIDEO&&kind!=AVMEDIA_TYPE_AUDIO)continue;
  auto* dst=avformat_new_stream(out,nullptr);if(!dst)return 2;map[i]=dst->index;
  check(avcodec_parameters_copy(dst->codecpar,src->codecpar),"copy_codec");dst->codecpar->codec_tag=0;dst->time_base=src->time_base;
 }
 const int bytes=32768;auto* buffer=(unsigned char*)av_malloc(bytes);auto* io=avio_alloc_context(buffer,bytes,1,nullptr,nullptr,output,nullptr);if(!io)return 2;
 out->pb=io;out->flags|=AVFMT_FLAG_CUSTOM_IO;out->flush_packets=1;out->max_delay=100000;
 av_dict_set(&opts,"mpegts_flags","+resend_headers",0);check(avformat_write_header(out,&opts),"write_header");av_dict_free(&opts);
 double shift=in->start_time!=AV_NOPTS_VALUE?-in->start_time/(double)AV_TIME_BASE:NAN;auto* packet=av_packet_alloc();long count=0;size_t queued_index=0;
 while(!stopped){
  int status=0;
  if(queued_index<queued.size()){av_packet_move_ref(packet,queued[queued_index]);av_packet_free(&queued[queued_index++]);}
  else status=av_read_frame(in,packet);
  if(status==AVERROR_EOF)break;check(status,"read_frame");auto index=packet->stream_index;
  if(index<0||index>=(int)map.size()||map[index]<0){av_packet_unref(packet);continue;}
  auto* src=in->streams[index];double unit=av_q2d(src->time_base);int64_t stamp=packet->dts!=AV_NOPTS_VALUE?packet->dts:packet->pts;
  if(stamp!=AV_NOPTS_VALUE){
   double original=stamp*unit;if(!std::isfinite(shift))shift=-original;double current=original+shift;
   if(std::isfinite(last[index])){
    double delta=current-last[index]-duration[index];
    if(delta>10||delta< -1){shift-=delta;current-=delta;fprintf(stderr,"{\"event\":\"remux_discontinuity\",\"stream\":%d,\"removedSeconds\":%.9f,\"outputDts\":%.9f,\"packets\":%ld}\n",index,delta,current,count);}
   }
   last[index]=current;duration[index]=packet->duration>0?packet->duration*unit:(src->codecpar->codec_type==AVMEDIA_TYPE_AUDIO?1024./48000:.04);
  }
  int64_t ticks=llround(shift/unit);if(packet->pts!=AV_NOPTS_VALUE)packet->pts+=ticks;if(packet->dts!=AV_NOPTS_VALUE)packet->dts+=ticks;
  auto* dst=out->streams[map[index]];av_packet_rescale_ts(packet,src->time_base,dst->time_base);packet->stream_index=map[index];packet->pos=-1;
  status=av_interleaved_write_frame(out,packet);av_packet_unref(packet);if(stopped)break;check(status,"write_frame");count++;
 }
 av_packet_free(&packet);av_write_trailer(out);avio_flush(io);av_freep(&io->buffer);avio_context_free(&io);avformat_free_context(out);avformat_close_input(&in);return 0;
}
