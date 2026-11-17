"""Optional, viewer-local source-clock evidence; no movie-duration subtraction."""
import math

def clock(value,end):
    if value is None:return None
    if not isinstance(value,dict):raise ValueError('invalid_source_clock')
    epoch=value.get('epoch')
    if not isinstance(epoch,int) or isinstance(epoch,bool) or not 0<=epoch<1e9:raise ValueError('invalid_source_clock')
    result=dict(epoch=epoch)
    for key,low,high in [('audioRemoved',-1209600,1209600),('videoRemoved',-1209600,1209600),('updatedAt',0,end+.25)]:
        v=value.get(key)
        if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not low<=v<=high:raise ValueError('invalid_source_clock')
        result[key]=float(v)
    return result

def project(model,current,*,asset,programme,epoch,start,position,ad_start,now):
    if not model or not current or model['asset']!=asset or model['programme']!=programme or now-model['verifiedAt']>1800:return None
    old=model['clock']
    if current['epoch']!=old['epoch']:return None
    a=current['audioRemoved']-old['audioRemoved'];v=current['videoRemoved']-old['videoRemoved']
    if abs(a-v)>.25:return None
    removed=(a+v)/2
    resumed=epoch!=model['epoch']
    if resumed:
        # Both streams must have fresh return-to-movie clock evidence. Reject
        # PID/timebase rebasing, missing events and implausible content jumps.
        if ad_start is None or start<=ad_start or current['updatedAt']<start-.25:return None
        advance=start-ad_start+removed
        if not -.5<=advance<=12:return None
        not_before=max(model.get('notBefore',0),current['updatedAt']+1)
    else:
        if abs(a)>.001 or abs(v)>.001:return None
        advance=0;not_before=model.get('notBefore',0)
    return dict(rate=model['rate'],intercept=model['intercept']+model['rate']*removed,
                start=max(0,position-1,not_before),notBefore=not_before,resumed=resumed,
                sourceMovieAdvanceSeconds=advance,removedSeconds=removed)
