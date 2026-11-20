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
