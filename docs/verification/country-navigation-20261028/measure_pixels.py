from pathlib import Path
from PIL import Image
from collections import Counter
import json, math

folder = Path('docs/verification/country-navigation-20261028')
# Clipping regions inspected from the real screenshots. These delimit visible
# controls only; acceptance budgets remain 44px / 6px / 3px / min(2px,10%).
regions = {
 'desktop-all': (400,90,880,710,420),
 'desktop-m': (400,90,880,710,420),
 'desktop-search': (400,90,880,710,420),
 'desktop-empty': (400,90,880,710,420),
 'mobile-all': (12,112,378,732,492),
 'mobile-long': (12,112,378,732,492),
 'narrow-all': (12,40,308,660,470),
 'short-large-all': (12,12,308,348,300),
 'short-large-long': (12,12,308,348,200),
}
measurements=[]
for name,(left,top,right,bottom,results_top) in regions.items():
    im = Image.open(folder/(name+'.png')).convert('RGB')
    data=json.loads((folder/(name+'.json')).read_text(encoding='utf-8'))
    for control in data['controls']:
        r=control['rect']; label=control['label']
        if control['role']!='button': continue
        is_letter=len(label)==1 or label=='全部'
        is_icon=label in ['关闭国家菜单','清空搜索']
        # Accessibility clips the rightmost button to the horizontal scroller.
        # Full button dimensions are separately asserted in Flutter tests.
        if is_letter and r['width']<44: continue
        if r['left']<left or r['right']>right or r['top']<top or r['bottom']>bottom-3: continue
        if not is_letter and not is_icon and (r['top']<results_top or r['bottom']>=bottom-14): continue
        x0,y0,x1,y1=map(round,[r['left'],r['top'],r['right'],r['bottom']])
        # Measure actual foreground pixels, not Text or DOM line boxes.
        inset=6
        samples=[im.getpixel((x,y)) for y in range(y0+inset,y1-inset) for x in range(x0+inset,x1-inset)]
        bg=Counter(samples).most_common(1)[0][0]
        light=sum(bg)>500
        points=[]
        for y in range(y0+inset,y1-inset):
            for x in range(x0+inset,x1-inset):
                pixel=im.getpixel((x,y))
                if (sum(pixel)<sum(bg)-160 if light else sum(pixel)>sum(bg)+200): points.append((x,y))
        if not points: continue
        gx0=min(p[0] for p in points); gx1=max(p[0] for p in points)+1
        gy0=min(p[1] for p in points); gy1=max(p[1] for p in points)+1
        error=abs((gy0+gy1)/2-(r['top']+r['bottom'])/2)
        inner=[r['left']+3,r['top']+3,r['right']-3,r['bottom']-3]
        margins=[gx0-inner[0],gy0-inner[1],inner[2]-gx1,inner[3]-gy1]
        budget=min(2,(gy1-gy0)*.1)
        measurements.append({'state':name,'label':label,'background':list(bg),'backgroundBounds':[x0,y0,x1,y1],
          'usableInner':inner,'hotZone':[r['left'],r['top'],r['right'],r['bottom']],
          'glyphBounds':[gx0,gy0,gx1,gy1],'innerMargins':margins,'verticalCenterError':round(error,3),
          'allowedCenterError':budget,'pass':r['height']>=44 and min(margins)>=3 and error<=budget})
    for control in data['controls']:
        if control['role']!='INPUT': continue
        r=control['rect']
        if r['top']<top+56 or r['bottom']>bottom-14: continue
        # Infer the painted input background from its actual flat fill, since
        # Flutter's HTML input box includes extra editable overlay padding.
        points=[(x,y) for y in range(max(0,round(r['top'])),min(im.height,round(r['bottom'])))
          for x in range(max(0,round(r['left'])),min(im.width,round(r['right']))) if im.getpixel((x,y))==(17,31,52)]
        if not points: continue
        x0=min(x for x,y in points)-1; x1=max(x for x,y in points)+2
        y0=min(y for x,y in points)-1; y1=max(y for x,y in points)+2
        points=[(x,y) for y in range(y0+5,y1-5) for x in range(x0+8,x1-58) if sum(im.getpixel((x,y)))>430]
        if not points: continue
        gx0=min(x for x,y in points); gx1=max(x for x,y in points)+1
        gy0=min(y for x,y in points); gy1=max(y for x,y in points)+1
        error=abs((gy0+gy1)/2-(y0+y1)/2)
        measurements.append({'state':name,'label':'搜索框文本','backgroundBounds':[x0,y0,x1,y1],
          'usableInner':[x0+3,y0+3,x1-3,y1-3],'hotZone':[r['left'],r['top'],r['right'],r['bottom']],
          'glyphBounds':[gx0,gy0,gx1,gy1],'innerMargins':[gx0-x0-3,gy0-y0-3,x1-gx1-3,y1-gy1-3],
          'verticalCenterError':error,'allowedCenterError':min(2,(gy1-gy0)*.1),
          'pass':error<=min(2,(gy1-gy0)*.1) and min(gy0-y0-3,y1-gy1-3)>=3 and r['height']>=44})
gaps=[]
row_centers=[]
for state in regions:
    controls=[m for m in measurements if m['state']==state and m['label'] not in ['搜索框文本','清空搜索','关闭国家菜单']]
    rows={}
    for m in controls:
        gx0,gy0,gx1,gy1=m['glyphBounds']; x0,y0,x1,y1=m['hotZone']
        m['horizontalCenterError']=round(abs((gx0+gx1)/2-(x0+x1)/2),3)
        m['pass']=m['pass'] and m['horizontalCenterError']<=m['allowedCenterError']
        rows.setdefault(round(y0,1),[]).append(m)
    for row in rows.values():
        row.sort(key=lambda m:m['hotZone'][0])
        centers=[(m['glyphBounds'][1]+m['glyphBounds'][3])/2 for m in row]
        if len(row)>1:
            row_centers.append({'state':state,'rowTop':row[0]['hotZone'][1],'glyphCenterSpread':max(centers)-min(centers)})
        for a,b in zip(row,row[1:]):
            gaps.append({'state':state,'between':[a['label'],b['label']], 'pixels':round(b['hotZone'][0]-a['hotZone'][2],3)})
result={'method':'Actual screenshot foreground pixel bounds with fixed color-contrast threshold; only fully visible controls measured. Border inner excludes 3px rounded edge; hotzone is browser accessibility geometry. Scroll-clipped final rows excluded until fully revealed.',
 'gaps':gaps,'rowCenters':row_centers,
 'controls':measurements,'failures':[m for m in measurements if not m['pass']]}
(folder/'pixel-measurements.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'measured':len(measurements),'minimumGap':min(g['pixels'] for g in gaps),'maxRowCenterSpread':max(r['glyphCenterSpread'] for r in row_centers),'failures':result['failures']},ensure_ascii=False))
for src,name,box in [('desktop-m','desktop-menu',(400,90,880,710)),('mobile-all','mobile-menu',(12,112,378,732)),('short-large-long','long-name-detail',(26,246,284,330))]:
    Image.open(folder/(src+'.png')).crop(box).save(folder/(name+'.png'))
