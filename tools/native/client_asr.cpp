// SPDX-License-Identifier: MIT
// Offline worker. Reads only bounded local PCM files; never opens a network URL.
#include "whisper.h"
#include "json.hpp"
#include <fstream>
#include <filesystem>
#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <thread>
#ifdef __ANDROID__
#include <unistd.h>
#endif
#if (defined(_WIN32) || defined(__ANDROID__)) && defined(__x86_64__)
#include <cpuid.h>
static bool fast_cpu(){
 unsigned a,b,c,d;if(!__get_cpuid(1,&a,&b,&c,&d))return false;
 const unsigned required=(1u<<27)|(1u<<28)|(1u<<12)|(1u<<29)|(1u<<20);
 if((c&required)!=required)return false;
 unsigned low,high;__asm__ volatile("xgetbv":"=a"(low),"=d"(high):"c"(0));
 if((low&6)!=6)return false;
 if(!__get_cpuid_count(7,0,&a,&b,&c,&d))return false;
 return (b&((1u<<5)|(1u<<8)))==((1u<<5)|(1u<<8));
}
#endif
using json=nlohmann::json;
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 if(std::string(argv[1])=="--capabilities"){
#if (defined(_WIN32) || defined(__ANDROID__)) && defined(__x86_64__)
  std::cout<<json({{"avx2",fast_cpu()}}).dump()<<std::endl;
#else
  std::cout<<"{\"avx2\":false}"<<std::endl;
#endif
  return 0;
 }
 const bool tiny=std::filesystem::u8path(argv[1]).filename()=="ggml-tiny.en-q5_1.bin";
#ifdef __ANDROID__
 nice(5);
#endif
 whisper_log_set([](ggml_log_level,const char*,void*){},nullptr);
 auto cp=whisper_context_default_params();cp.use_gpu=false;cp.flash_attn=false;cp.dtw_token_timestamps=true;cp.dtw_aheads_preset=tiny?WHISPER_AHEADS_TINY_EN:WHISPER_AHEADS_BASE_EN;
 std::ifstream model(std::filesystem::u8path(argv[1]),std::ios::binary);if(!model)return 3;
 whisper_model_loader loader{};loader.context=&model;
 loader.read=[](void* p,void* out,size_t count)->size_t{auto* in=static_cast<std::ifstream*>(p);in->read(static_cast<char*>(out),count);return size_t(in->gcount());};
 loader.eof=[](void* p)->bool{return static_cast<std::ifstream*>(p)->eof();};
 loader.close=[](void*){};
 auto *ctx=whisper_init_with_params(&loader,cp);model.close();if(!ctx)return 3;
 std::cout<<json({{"ready",true},{"engine","whisper.cpp-v1.8.2"},{"model",tiny?"tiny.en":"base.en"}}).dump()<<std::endl;
 std::string line;
 while(std::getline(std::cin,line)) {
  try {
   auto request=json::parse(line);std::string path=request.at("path");
   std::ifstream input(std::filesystem::u8path(path),std::ios::binary|std::ios::ate);auto size=input.tellg();
   if(size<3200||size>16000*2*40||size%2)throw std::runtime_error("pcm_limit");
   input.seekg(0);std::vector<int16_t> raw(size_t(size)/2);input.read((char*)raw.data(),size);
   std::vector<float> pcm(raw.size());double energy=0;for(size_t i=0;i<raw.size();i++){pcm[i]=raw[i]/32768.f;energy+=pcm[i]*pcm[i];}
   const double duration=pcm.size()/16000.;
   size_t lead=0;
   // Trim only near-silent leading PCM, retaining 80 ms pre-roll. Whisper can
   // otherwise stamp the first word at the start of a silent input window.
   for(size_t i=0;i+640<pcm.size();i+=320) {
    double e=0;for(size_t j=i;j<i+640;j++)e+=pcm[j]*pcm[j];
    if(e/640>1e-5) {lead=i>1280?i-1280:0;break;}
   }
   double shift=lead/16000.;
   if(lead)pcm.erase(pcm.begin(),pcm.begin()+lead);
   json words=json::array();auto start=std::chrono::steady_clock::now();
   if(energy/pcm.size()>1e-7) {
    auto p=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);p.n_threads=tiny?2:3;p.language="en";
    p.translate=false;p.no_context=true;p.print_progress=false;p.print_realtime=false;p.print_timestamps=false;
#if defined(__ANDROID__)
    // Live playback cannot wait for repeated temperature fallback on music.
    // A single greedy pass leaves weak speech unmatched instead of resampling.
    p.temperature_inc=0.f;p.greedy.best_of=1;
#endif
    p.token_timestamps=true;p.split_on_word=true;p.max_len=1;p.suppress_blank=true;p.suppress_nst=true;
    if(whisper_full(ctx,p,pcm.data(),int(pcm.size()))!=0)throw std::runtime_error("recognition_failed");
    for(int s=0;s<whisper_full_n_segments(ctx);s++) {
     std::string text=whisper_full_get_segment_text(ctx,s);float probability=1;double dtw_start=1e30;
     for(int t=0;t<whisper_full_n_tokens(ctx,s);t++) {
      auto data=whisper_full_get_token_data(ctx,s,t);
      if(data.id<whisper_token_eot(ctx)){probability=std::min(probability,data.p);if(data.t_dtw>=0)dtw_start=std::min(dtw_start,data.t_dtw/100.0+shift);}
     }
     double t0=dtw_start<1e20?dtw_start:whisper_full_get_segment_t0(ctx,s)/100.0+shift;
     double t1=whisper_full_get_segment_t1(ctx,s)/100.0+shift;
     // Refine a token onset that falls inside a real PCM silence gap. Keep
     // consonant pre-roll and never invent an onset when no energy is present.
     size_t begin=std::min(pcm.size(),size_t(std::max(0.,t0-shift)*16000));
     size_t finish=std::min(pcm.size(),size_t(std::max(0.,t1-shift)*16000));
     for(size_t i=begin;i+160<finish;i+=80) {
      double e=0;for(size_t j=i;j<i+160;j++)e+=pcm[j]*pcm[j];
      if(e/160>1e-5) {if(i>begin+1280)t0=std::min(t1,std::max(t0,shift+i/16000.-.03));break;}
     }
     if(!text.empty() && t0<=duration+.05)words.push_back({{"word",text},{"start",std::min(duration,t0)},{"end",std::min(duration,std::max(t0,t1))},{"probability",probability}});
    }
   }
   double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
   std::cout<<json({{"id",request.at("id")},{"words",words},{"processSeconds",seconds}}).dump()<<std::endl;
  } catch(const std::exception &e){std::cout<<json({{"error",e.what()}}).dump()<<std::endl;}
 }
 whisper_free(ctx);return 0;
}
