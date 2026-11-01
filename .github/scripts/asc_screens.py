# 上傳 App Store 截圖（用 App Store Connect API；金鑰來自 GitHub Secrets）
import os, time, json, hashlib, glob, jwt, requests
KID=os.environ['ASC_KEY_ID']; ISS=os.environ['ASC_ISSUER']; KEY=os.environ['ASC_KEY']
APP=os.environ.get('APP_ID','6827632980'); LOC=os.environ.get('LOCALE','zh-Hant')
def tok(): return jwt.encode({'iss':ISS,'iat':int(time.time()),'exp':int(time.time())+1100,'aud':'appstoreconnect-v1'},KEY,algorithm='ES256',headers={'kid':KID,'typ':'JWT'})
B='https://api.appstoreconnect.apple.com/v1'
def api(m,p,**k):
    r=requests.request(m,p if p.startswith('http') else B+p,headers={'Authorization':'Bearer '+tok(),'Content-Type':'application/json'},**k)
    if r.status_code>=400: print(m,p,r.status_code,r.text[:800]); r.raise_for_status()
    return r.json() if r.text else {}
vs=api('GET',f'/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=5')['data']
print('versions',[(v['attributes']['versionString'],v['attributes']['appStoreState']) for v in vs])
v=[x for x in vs if x['attributes']['appStoreState'] not in ('READY_FOR_SALE','REPLACED_WITH_NEW_VERSION')][0]
locs=api('GET',f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")['data']
print('locales',[l['attributes']['locale'] for l in locs])
loc=[l for l in locs if l['attributes']['locale']==LOC][0]
sets=api('GET',f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?include=appScreenshots&limit=50")
print('sets',[(s['attributes']['screenshotDisplayType'],len(s['relationships']['appScreenshots']['data'])) for s in sets['data']])
PLAN={'APP_IPHONE_67':'iphone69_','APP_IPHONE_61':'iphone63_'}
if os.environ.get('STATUS'):
    for s0 in sets['data']:
        st=api('GET',f"/appScreenshotSets/{s0['id']}/appScreenshots")['data']
        print(s0['attributes']['screenshotDisplayType'],[(x['attributes']['fileName'],x['attributes'].get('assetDeliveryState')) for x in st])
    raise SystemExit
for dt,pre in PLAN.items():
    s=[x for x in sets['data'] if x['attributes']['screenshotDisplayType']==dt]
    if s: sid=s[0]['id']
    else: sid=api('POST','/appScreenshotSets',json={'data':{'type':'appScreenshotSets','attributes':{'screenshotDisplayType':dt},'relationships':{'appStoreVersionLocalization':{'data':{'type':'appStoreVersionLocalizations','id':loc['id']}}}}})['data']['id']
    old=api('GET',f'/appScreenshotSets/{sid}/appScreenshots')['data']
    for o in old: api('DELETE',f"/appScreenshots/{o['id']}")
    print(dt,'removed',len(old))
    ids=[]
    for f in sorted(glob.glob(f'app/store-assets/{pre}0*.png')):
        b=open(f,'rb').read(); n=os.path.basename(f)
        sc=api('POST','/appScreenshots',json={'data':{'type':'appScreenshots','attributes':{'fileName':n,'fileSize':len(b)},'relationships':{'appScreenshotSet':{'data':{'type':'appScreenshotSets','id':sid}}}}})['data']
        for op in sc['attributes']['uploadOperations']:
            part=b[op['offset']:op['offset']+op['length']]
            requests.request(op['method'],op['url'],headers={h['name']:h['value'] for h in op['requestHeaders']},data=part).raise_for_status()
        api('PATCH',f"/appScreenshots/{sc['id']}",json={'data':{'type':'appScreenshots','id':sc['id'],'attributes':{'uploaded':True,'sourceFileChecksum':hashlib.md5(b).hexdigest()}}})
        ids.append(sc['id']); print('uploaded',n)
    api('PATCH',f'/appScreenshotSets/{sid}/relationships/appScreenshots',json={'data':[{'type':'appScreenshots','id':i} for i in ids]})
time.sleep(20)
for dt in PLAN:
    s=[x for x in api('GET',f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")['data'] if x['attributes']['screenshotDisplayType']==dt][0]
    st=api('GET',f"/appScreenshotSets/{s['id']}/appScreenshots")['data']
    print(dt,[(x['attributes']['fileName'],(x['attributes'].get('assetDeliveryState') or {}).get('state')) for x in st])
