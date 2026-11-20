"""Build a deterministic local speech/ad/speech fixture and subtitle-only API.
This is NOT a live broadcast acceptance test.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import wave
from client_clock import TextHub
from service import serve
SENTENCES=[
 'The movie starts after the advertising break.',
 'Please wait until the subtitles are synchronized.',
 'We should arrive at the railway station before midnight.',
 'Remember to bring the letter that you found yesterday.',
 'I have been waiting for you beside the old bridge.',
 'Nobody knows what happened inside the empty building.',
 'We can leave this place when the morning train arrives.',
 'Please tell your brother that the package has arrived.',
 'The police officer asked everyone to remain inside.',
 'You can find the answer on the final page of this book.',
 'There is another entrance on the other side of the garden.',
 'We will meet again tomorrow at the same time.']
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--reuse',action='store_true');a=p.parse_args();root=a.root;root.mkdir(parents=True,exist_ok=True)
 if not a.reuse:
  pieces=[];cues=[];cursor=0;movie=100;ad_start=ad_end=None
  for i,text in enumerate(SENTENCES):
   if i==4:
    ad_start=cursor;pieces.append(b'\0'*(16000*2*10));cursor+=10;ad_end=cursor
   source=root/f'phrase-{i}.aiff';wav=root/f'phrase-{i}.wav'
   subprocess.run(['say','-o',str(source),text],check=True)
   subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(source),str(wav)],check=True)
   with wave.open(str(wav)) as w:assert w.getframerate()==16000 and w.getnchannels()==1;raw=w.readframes(w.getnframes())
   seconds=len(raw)/32000
   pieces.extend([b'\0'*32000,raw]);cursor+=1
   cues.append(dict(index=i+1,start=movie+1,end=movie+1+seconds,text=text));movie+=1+seconds;cursor+=seconds
  pieces.append(b'\0'*160000);cursor+=5
  with wave.open(str(root/'fixture.wav'),'wb') as w:w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(b''.join(pieces))
  source='https://action-rakuten-tv-uk.fast.rakuten.tv/v1/master/fixture/production-LiveChannel-6065/master.m3u8'
  programme=dict(key='offline-fixture',movieId='offline-fixture',title='BobTV offline speech fixture',year=2026,stopUtc=time.time()+3600)
  segments=[dict(sequence=1,start=0,end=ad_start,asset='movie-before',movieId='offline-fixture',ad=False),dict(sequence=2,start=ad_start,end=ad_end,asset='fixture-advert',movieId=None,ad=True),dict(sequence=3,start=ad_end,end=cursor,asset='movie-after',movieId='offline-fixture',ad=False)]
  (root/'fixture.json').write_text(json.dumps(dict(source=source,programme=programme,cues=cues,segments=segments,scope='offline synthetic speech integration; not live advert proof'),indent=2))
 fixture=json.loads((root/'fixture.json').read_text());source=fixture['source'];programme=fixture['programme'];cues=fixture['cues'];programme['stopUtc']=time.time()+3600
 class Cache:
  def get_or_discover(self,*args,**kwargs):return [dict(page='local-fixture',tracks=dict(en=cues),cacheHit=True)]
 hub=TextHub(root/'server',Cache(),lambda:(source,programme));serve(hub,'127.0.0.1',18923)
