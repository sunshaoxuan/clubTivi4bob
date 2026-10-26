/* Android executable probe of the exact packaged libmpv and FFT metadata. */
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void *(*create)(void);
static int (*init)(void *), (*option)(void *,const char *,const char *), (*command)(void *,const char **);
static char *(*get)(void *,const char *);
static void (*release)(void *), (*destroy)(void *);
#define CHECK(x) do { if(!(x)){fprintf(stderr,"Failed line %d: %s\n",__LINE__,#x);exit(1);} }while(0)
static double measure(double frequency,int amplitude,int opposite,int muted){
 const char *path="/data/local/tmp/bobtv-fft/input.wav";
 FILE *f=fopen(path,"wb"); CHECK(f);
 uint32_t header[]={0x46464952,192036,0x45564157,0x20746d66,16,0x00020001,48000,192000,0x00100004,0x61746164,192000};
 fwrite(header,1,sizeof(header),f);
 for(int i=0;i<48000;i++){int16_t a=amplitude*sin(2*M_PI*frequency*i/48000),b=opposite?-a:a;fwrite(&a,2,1,f);fwrite(&b,2,1,f);} fclose(f);
 void *h=create();CHECK(h);
 CHECK(option(h,"vo","null")>=0);CHECK(option(h,"ao","null")>=0);
 CHECK(option(h,"msg-level","all=no")>=0);
 CHECK(option(h,"af","@bobtv_radio_spectrum:lavfi=[bobtv_spectrum]:o=[threads=1]")>=0);
 CHECK(init(h)>=0);
 if(muted){const char *args[]={"set","mute","yes",NULL};CHECK(command(h,args)>=0);const char *vol[]={"set","volume","0",NULL};CHECK(command(h,vol)>=0);}
 const char *load[]={"loadfile",path,NULL};CHECK(command(h,load)>=0);
 char *metadata=NULL;
 for(int i=0;i<50;i++){usleep(20000);metadata=get(h,"af-metadata/bobtv_radio_spectrum");if(metadata && strstr(metadata,"lavfi.bobtv_spectrum.127")&&strstr(metadata,"ready"))break;if(metadata)release(metadata);metadata=NULL;}
 CHECK(metadata);
 int peak=-1;double top=-INFINITY;
 for(int i=0;i<128;i++){char key[80];snprintf(key,sizeof(key),"\"lavfi.bobtv_spectrum.%d\"",i);char *p=strstr(metadata,key);CHECK(p);p=strchr(p,':')+1;while(*p==' '||*p=='\"')p++;double value=strtod(p,NULL);if(value>top){top=value;peak=i;}}
 int expected=lround(log(frequency/40)/log(400)*127);
 if(amplitude){CHECK(abs(peak-expected)<=1);CHECK(top>-30);}else{CHECK(isinf(top)&&top<0);}
 printf("frequency=%.2f amplitude=%d opposite=%d muted=%d peak=%d dB=%.4f\n",frequency,amplitude,opposite,muted,peak,top);
 release(metadata);destroy(h);return top;
}
int main(int argc,char **argv){
 CHECK(argc==2);void *lib=dlopen(argv[1],RTLD_NOW|RTLD_GLOBAL);if(!lib)fprintf(stderr,"%s\n",dlerror());CHECK(lib);
 #define LOAD(name,symbol) name=dlsym(lib,symbol);CHECK(name)
 LOAD(create,"mpv_create");LOAD(init,"mpv_initialize");LOAD(option,"mpv_set_option_string");LOAD(command,"mpv_command");LOAD(get,"mpv_get_property_string");LOAD(release,"mpv_free");LOAD(destroy,"mpv_terminate_destroy");
 measure(40*pow(400,20./127),16000,0,0);measure(40*pow(400,110./127),16000,0,0);
 double a=measure(1000,16000,0,0),b=measure(1000,16000,1,0),c=measure(1000,8000,0,0),d=measure(1000,16000,0,1);
 CHECK(fabs(a-b)<.01);CHECK(fabs(a-d)<.01);CHECK(a-c>5.9&&a-c<6.1);measure(1000,0,0,0);
 puts("PASS: Android packaged runtime, 128 real FFT bands, frequencies, amplitude, stereo, muted preview and silence");return 0;
}
