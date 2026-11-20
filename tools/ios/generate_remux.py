from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def generate():
    source=(ROOT/'tools/native/client_remux.cpp').read_text()
    learn=source[source.index('static void learn_aac'):source.index('int main(')]
    body=source[source.index(' AVFormatContext* in='):source.index(' av_packet_free(&packet);av_write_trailer')]
    body=body.replace('AVFormatContext* in=', 'in=').replace('AVDictionary* opts=nullptr;','')
    body=body.replace('{interrupt,nullptr}', '{interrupt,remuxSession}')
    body=body.replace(' std::vector<AVPacket*> queued;','')
    body=body.replace('AVFormatContext* out=nullptr;', '')
    body=body.replace('if(!dst)return 2;', 'if(!dst)check(AVERROR(ENOMEM),"allocate_stream");')
    body=body.replace('auto* io=avio_alloc_context(buffer,32768,1,nullptr,nullptr,output,nullptr);if(!io)return 2;', 'io=avio_alloc_context(buffer,32768,1,remuxSession,nullptr,output,nullptr);if(!io){av_free(buffer);check(AVERROR(ENOMEM),"allocate_io");}')
    body=body.replace('auto* packet=av_packet_alloc();','packet=av_packet_alloc();check(packet?0:AVERROR(ENOMEM),"allocate_packet");')
    body=body.replace('auto* buffer=(unsigned char*)av_malloc(32768);','auto* buffer=(unsigned char*)av_malloc(32768);check(buffer?0:AVERROR(ENOMEM),"allocate_buffer");')
    body=body.replace('auto* p=av_packet_alloc();check(av_read_frame(in,p),"audio_header_packet");queued.push_back(p);', 'auto* p=av_packet_alloc();check(p?0:AVERROR(ENOMEM),"allocate_packet");queued.push_back(p);check(av_read_frame(in,p),"audio_header_packet");')
    body=body.replace('in=avformat_alloc_context();in->', 'in=avformat_alloc_context();check(in?0:AVERROR(ENOMEM),"allocate_input");in->')
    body=body.replace('argv[1]', 'source').replace('fprintf(stderr,','emit_event(')
    output=(ROOT/'tools/ios/remux_prefix.cpp.inc').read_text()+learn+'''
static int normalise(const char *source,BobTVRemux *session){
 remuxSession=session;AVFormatContext *in=nullptr,*out=nullptr;AVIOContext *io=nullptr;AVPacket *packet=nullptr;AVDictionary *opts=nullptr;std::vector<AVPacket*> queued;int status=0;
 try {
'''+body+'''
 if(out)av_write_trailer(out);if(io)avio_flush(io);
 }catch(int error){status=error;}catch(...){status=AVERROR_UNKNOWN;}
 av_dict_free(&opts);for(auto *p:queued)av_packet_free(&p);av_packet_free(&packet);
 if(io){av_freep(&io->buffer);avio_context_free(&io);}if(out)avformat_free_context(out);if(in)avformat_close_input(&in);
 remuxSession=nullptr;return status;
}
'''+(ROOT/'tools/ios/remux_suffix.cpp.inc').read_text()
    (ROOT/'ios/Runner/BobTVRemux.cpp').write_text(output)
if __name__=='__main__':generate()
