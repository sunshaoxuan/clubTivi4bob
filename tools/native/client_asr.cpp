// SPDX-License-Identifier: MIT
// Offline worker. Reads only bounded local PCM files; never opens a network URL.
#include "whisper.h"
#include "json.hpp"
#include <fstream>
#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
using json=nlohmann::json;
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 whisper_log_set([](ggml_log_level,const char*,void*){},nullptr);
 auto cp=whisper_context_default_params();cp.use_gpu=false;
 auto *ctx=whisper_init_from_file_with_params(argv[1],cp);if(!ctx)return 3;
 std::cout<<"{\"ready\":true,\"engine\":\"whisper.cpp-v1.8.2\"}"<<std::endl;
 std::string line;
 while(std::getline(std::cin,line)) {
  try {
   auto request=json::parse(line);std::string path=request.at("path");
   std::ifstream input(path,std::ios::binary|std::ios::ate);auto size=input.tellg();
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
    auto p=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);p.n_threads=3;p.language="en";
    p.translate=false;p.no_context=true;p.print_progress=false;p.print_realtime=false;p.print_timestamps=false;
    p.token_timestamps=true;p.split_on_word=true;p.max_len=1;p.suppress_blank=true;p.suppress_nst=true;
    if(whisper_full(ctx,p,pcm.data(),int(pcm.size()))!=0)throw std::runtime_error("recognition_failed");
    for(int s=0;s<whisper_full_n_segments(ctx);s++) {
     std::string text=whisper_full_get_segment_text(ctx,s);float probability=1;
     for(int t=0;t<whisper_full_n_tokens(ctx,s);t++) {
      auto data=whisper_full_get_token_data(ctx,s,t);
      if(data.id<whisper_token_eot(ctx))probability=std::min(probability,data.p);
     }
     double t0=whisper_full_get_segment_t0(ctx,s)/100.0+shift;
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
