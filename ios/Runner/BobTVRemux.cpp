// In-process iOS transport. The timestamp algorithm below is generated from
// tools/native/client_remux.cpp; no subprocesses, global signals or stdio pipes.
#include "BobTVRemux.h"
extern "C" {
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
}
#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <deque>
#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <algorithm>
struct BobTVRemux {
 std::atomic<bool> cancelled{false}, running{true};
 std::atomic<int> client{-1};
 int server=-1, port=0;
 std::thread worker;
 std::mutex mutex;
 std::deque<std::string> events;
};
static thread_local BobTVRemux *remuxSession=nullptr;
#define stopped (remuxSession->cancelled.load())
static void emit_event(const char *format,...) {
 if(!remuxSession)return;
 char buffer[2048];va_list args;va_start(args,format);vsnprintf(buffer,sizeof(buffer),format,args);va_end(args);
 std::string value(buffer);while(!value.empty()&&(value.back()=='\n'||value.back()=='\r'))value.pop_back();
 if(value.empty()||value.front()!='{'||value.back()!='}')return;
 std::lock_guard<std::mutex> lock(remuxSession->mutex);
 if(remuxSession->events.size()>=128)remuxSession->events.pop_front();remuxSession->events.push_back(value);
}
static int interrupt(void *opaque){return static_cast<BobTVRemux*>(opaque)->cancelled.load();}
static int open_resource(AVFormatContext* context,AVIOContext** io,const char* url,int flags,AVDictionary** options){
 av_dict_set(options,"tls_verify","1",0);return avio_open2(io,url,flags,&context->interrupt_callback,options);
}
static int output(void *opaque,uint8_t *data,int size){
 auto* session=static_cast<BobTVRemux*>(opaque);int done=0;
 while(done<size&&!session->cancelled){auto n=send(session->client.load(),data+done,size-done,0);if(n<0){if(errno==EINTR)continue;return AVERROR(errno);}if(n==0)return AVERROR_EOF;done+=n;}
 return session->cancelled?AVERROR_EXIT:done;
}
static void check(int status,const char* label){if(status<0){emit_event("{\"event\":\"remux_error\",\"stage\":\"%s\",\"code\":%d}",label,status);throw status;}}
static void learn_aac(AVCodecParameters* par,const AVPacket* packet){
 if(par->codec_id!=AV_CODEC_ID_AAC||par->sample_rate>0)return;
 static const int rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
 for(int j=0;j+7<=packet->size&&j<64;j++){
  auto* b=packet->data+j;if(b[0]!=0xff||(b[1]&0xf6)!=0xf0)continue;
  int frequency=(b[2]>>2)&15,channels=((b[2]&1)<<2)|(b[3]>>6);if(frequency>=13||channels==0)continue;
  par->sample_rate=rates[frequency];par->profile=(b[2]>>6)&3;par->frame_size=1024;av_channel_layout_default(&par->ch_layout,channels==7?8:channels);break;
 }
}

static int normalise(const char *source,BobTVRemux *session){
 remuxSession=session;AVFormatContext *in=nullptr,*out=nullptr;AVIOContext *io=nullptr;AVPacket *packet=nullptr;AVDictionary *opts=nullptr;std::vector<AVPacket*> queued;int status=0;
 try {
 in=avformat_alloc_context();check(in?0:AVERROR(ENOMEM),"allocate_input");in->io_open=open_resource;in->interrupt_callback={interrupt,remuxSession};
 av_dict_set(&opts,"analyzeduration","1000000",0);av_dict_set(&opts,"probesize","524288",0);av_dict_set(&opts,"allowed_extensions","ALL",0);av_dict_set(&opts,"prefer_x_start","1",0);av_dict_set(&opts,"seg_max_retry","5",0);av_dict_set(&opts,"rw_timeout","8000000",0);
 check(avformat_open_input(&in,source,nullptr,&opts),"open_input");av_dict_free(&opts);check(avformat_find_stream_info(in,nullptr),"stream_info");

 auto missing_audio=[&](){for(unsigned i=0;i<in->nb_streams;i++)if(in->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO&&in->streams[i]->codecpar->sample_rate<=0)return true;return false;};
 while(missing_audio()&&queued.size()<512){auto* p=av_packet_alloc();check(p?0:AVERROR(ENOMEM),"allocate_packet");queued.push_back(p);check(av_read_frame(in,p),"audio_header_packet");learn_aac(in->streams[p->stream_index]->codecpar,p);}
 if(missing_audio())check(AVERROR_INVALIDDATA,"audio_header_missing");
 check(avformat_alloc_output_context2(&out,nullptr,"mpegts",nullptr),"allocate_output");
 std::vector<int> map(in->nb_streams,-1);int video=-1,audio=-1;
 for(unsigned i=0;i<in->nb_streams;i++){
  auto* src=in->streams[i];int* chosen=src->codecpar->codec_type==AVMEDIA_TYPE_VIDEO?&video:src->codecpar->codec_type==AVMEDIA_TYPE_AUDIO?&audio:nullptr;
  if(!chosen||*chosen>=0)continue;auto* dst=avformat_new_stream(out,nullptr);if(!dst)check(AVERROR(ENOMEM),"allocate_stream");*chosen=dst->index;map[i]=dst->index;
  check(avcodec_parameters_copy(dst->codecpar,src->codecpar),"copy_codec");dst->codecpar->codec_tag=0;dst->time_base=src->time_base;
 }
 auto* buffer=(unsigned char*)av_malloc(32768);check(buffer?0:AVERROR(ENOMEM),"allocate_buffer");io=avio_alloc_context(buffer,32768,1,remuxSession,nullptr,output,nullptr);if(!io){av_free(buffer);check(AVERROR(ENOMEM),"allocate_io");}
 out->pb=io;out->flags|=AVFMT_FLAG_CUSTOM_IO;out->flush_packets=1;out->max_delay=100000;
 av_dict_set(&opts,"mpegts_flags","+resend_headers",0);check(avformat_write_header(out,&opts),"write_header");av_dict_free(&opts);
 double origin=in->start_time!=AV_NOPTS_VALUE?-in->start_time/(double)AV_TIME_BASE:NAN;
 std::vector<double> shifts(in->nb_streams,origin),last(out->nb_streams,NAN),duration(out->nb_streams,0);
 std::vector<int64_t> ticks(out->nb_streams,AV_NOPTS_VALUE);packet=av_packet_alloc();check(packet?0:AVERROR(ENOMEM),"allocate_packet");long count=0;size_t queued_index=0;
 while(!stopped){
  int status=0;if(queued_index<queued.size()){av_packet_move_ref(packet,queued[queued_index]);av_packet_free(&queued[queued_index++]);}else status=av_read_frame(in,packet);
  if(status==AVERROR_EOF||stopped)break;check(status,"read_frame");
  // A new movie can introduce new TS PIDs. Map them onto the same output AV
  // streams, with independent input clock offsets and monotonic output DTS.
  while(map.size()<in->nb_streams){unsigned i=map.size();auto* par=in->streams[i]->codecpar;int target=par->codec_type==AVMEDIA_TYPE_VIDEO?video:par->codec_type==AVMEDIA_TYPE_AUDIO?audio:-1;
   if(target>=0&&par->codec_id!=out->streams[target]->codecpar->codec_id)check(AVERROR_INVALIDDATA,"codec_changed");
   map.push_back(target);shifts.push_back(NAN);emit_event("{\"event\":\"remux_stream_changed\",\"input\":%u,\"output\":%d,\"pid\":%d}\n",i,target,in->streams[i]->id);
  }
  int index=packet->stream_index;if(index<0||index>=(int)map.size()||map[index]<0){av_packet_unref(packet);continue;}int target=map[index];auto* src=in->streams[index];auto* dst=out->streams[target];learn_aac(src->codecpar,packet);double unit=av_q2d(src->time_base);
  int64_t stamp=packet->dts!=AV_NOPTS_VALUE?packet->dts:packet->pts;
  if(stamp==AV_NOPTS_VALUE){av_packet_unref(packet);continue;}
  double original=stamp*unit;if(!std::isfinite(shifts[index]))shifts[index]=std::isfinite(last[target])?last[target]+duration[target]-original:-original;
  double current=original+shifts[index];double step=packet->duration>0?packet->duration*unit:src->codecpar->codec_type==AVMEDIA_TYPE_AUDIO?1024./std::max(1,src->codecpar->sample_rate):.04;
  if(std::isfinite(last[target])){double delta=current-last[target]-duration[target];if(delta>10||delta< -1){shifts[index]-=delta;current-=delta;emit_event("{\"event\":\"remux_discontinuity\",\"stream\":%d,\"removedSeconds\":%.9f,\"outputDts\":%.9f,\"packets\":%ld}\n",target,delta,current,count);}}
  // Unwrap PTS relative to DTS before applying the common packet shift.
  if(packet->pts!=AV_NOPTS_VALUE&&packet->dts!=AV_NOPTS_VALUE){double relative=(packet->pts-packet->dts)*unit;double wrap=(1LL<<33)/90000.;if(std::abs(relative)>wrap/2)packet->pts=packet->dts+llround(std::remainder(relative,wrap)/unit);}
  int64_t offset=llround(shifts[index]/unit);if(packet->pts!=AV_NOPTS_VALUE)packet->pts+=offset;if(packet->dts!=AV_NOPTS_VALUE)packet->dts+=offset;
  av_packet_rescale_ts(packet,src->time_base,dst->time_base);packet->stream_index=target;packet->pos=-1;
  if(packet->dts==AV_NOPTS_VALUE)packet->dts=packet->pts;
  if(ticks[target]!=AV_NOPTS_VALUE&&packet->dts<=ticks[target]){
   int64_t adjustment=ticks[target]+std::max<int64_t>(1,llround(step/av_q2d(dst->time_base)))-packet->dts;
   shifts[index]+=adjustment*av_q2d(dst->time_base);packet->dts+=adjustment;if(packet->pts!=AV_NOPTS_VALUE)packet->pts+=adjustment;
   emit_event("{\"event\":\"remux_packet_adjusted\",\"stream\":%d,\"seconds\":%.9f}\n",target,adjustment*av_q2d(dst->time_base));
  }
  if(packet->pts==AV_NOPTS_VALUE||packet->pts<packet->dts)packet->pts=packet->dts;
  int64_t next=packet->dts;double position=next*av_q2d(dst->time_base);
  status=av_interleaved_write_frame(out,packet);av_packet_unref(packet);if(stopped)break;check(status,"write_frame");ticks[target]=next;last[target]=position;duration[target]=step;count++;
 }

 if(out)av_write_trailer(out);if(io)avio_flush(io);
 }catch(int error){status=error;}catch(...){status=AVERROR_UNKNOWN;}
 av_dict_free(&opts);for(auto *p:queued)av_packet_free(&p);av_packet_free(&packet);
 if(io){av_freep(&io->buffer);avio_context_free(&io);}if(out)avformat_free_context(out);if(in)avformat_close_input(&in);
 remuxSession=nullptr;return status;
}
extern "C" int bobtv_has_pcm_filter(){return avfilter_get_by_name("bobtv_pcm")!=nullptr;}
extern "C" BobTVRemux *bobtv_remux_start(const char *source,const char *token){
 if(!source||!token||std::string(source).rfind("http://127.0.0.1:",0)!=0||strlen(token)>64)return nullptr;
 auto *session=new BobTVRemux;
 session->server=socket(AF_INET,SOCK_STREAM,0);if(session->server<0){delete session;return nullptr;}
 sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=0;
 if(bind(session->server,reinterpret_cast<sockaddr*>(&address),sizeof(address))||listen(session->server,4)){close(session->server);delete session;return nullptr;}
 socklen_t length=sizeof(address);getsockname(session->server,reinterpret_cast<sockaddr*>(&address),&length);session->port=ntohs(address.sin_port);
 std::string input(source),path="/"+std::string(token)+"/playback.ts";
 session->worker=std::thread([session,input,path](){
  while(!session->cancelled){
   pollfd wait{session->server,POLLIN,0};if(poll(&wait,1,100)<=0)continue;
   int client=accept(session->server,nullptr,nullptr);if(client<0)continue;session->client=client;
   int yes=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));timeval timeout{3,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
   std::string request;char buffer[1024];while(request.find("\r\n\r\n")==std::string::npos&&request.size()<8192&&!session->cancelled){auto n=recv(client,buffer,sizeof(buffer),0);if(n<=0)break;request.append(buffer,n);}
   bool head=request.rfind("HEAD "+path+" HTTP/",0)==0,get=request.rfind("GET "+path+" HTTP/",0)==0;
   const char *response=(get||head)?"HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n":"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
   send(client,response,strlen(response),0);
   if(get&&!session->cancelled)normalise(input.c_str(),session);
   {std::lock_guard<std::mutex> lock(session->mutex);session->client=-1;close(client);}if(get)break;
  }
  {std::lock_guard<std::mutex> lock(session->mutex);close(session->server);session->server=-1;}session->running=false;
 });
 return session;
}
extern "C" int bobtv_remux_port(BobTVRemux *session){return session?session->port:0;}
extern "C" int bobtv_remux_running(BobTVRemux *session){return session&&session->running;}
extern "C" char *bobtv_remux_events(BobTVRemux *session){
 if(!session)return strdup("[]");std::lock_guard<std::mutex> lock(session->mutex);std::string output="[";
 while(!session->events.empty()){if(output.size()>1)output+=",";output+=session->events.front();session->events.pop_front();}output+="]";return strdup(output.c_str());
}
extern "C" void bobtv_remux_free_string(char *value){free(value);}
extern "C" void bobtv_remux_destroy(BobTVRemux *session){
 if(!session)return;session->cancelled=true;{std::lock_guard<std::mutex> lock(session->mutex);if(session->server>=0)shutdown(session->server,SHUT_RDWR);int client=session->client.load();if(client>=0)shutdown(client,SHUT_RDWR);}
 if(session->worker.joinable())session->worker.join();delete session;
}
