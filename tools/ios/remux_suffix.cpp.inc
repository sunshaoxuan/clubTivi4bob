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
