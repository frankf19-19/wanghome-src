# 送審新版本（用 App Store Connect API；金鑰來自 GitHub Secrets）
#   VERSION=1.1.0 BUILD=2181 WHATS_NEW="..."  建立（或沿用）版本 → 等建置處理完 → 掛上建置、填「此版本新功能」→ 送交審查
#   SUBMIT=0 只準備不送審
import os, time, jwt, requests
KID=os.environ['ASC_KEY_ID']; ISS=os.environ['ASC_ISSUER']; KEY=os.environ['ASC_KEY']
APP=os.environ.get('APP_ID','6827632980'); LOC=os.environ.get('LOCALE','zh-Hant')
VER=os.environ['VERSION']; BUILD=os.environ['BUILD']; NEW=os.environ.get('WHATS_NEW',''); SUBMIT=os.environ.get('SUBMIT','1')=='1'
def tok(): return jwt.encode({'iss':ISS,'iat':int(time.time()),'exp':int(time.time())+1100,'aud':'appstoreconnect-v1'},KEY,algorithm='ES256',headers={'kid':KID,'typ':'JWT'})
B='https://api.appstoreconnect.apple.com/v1'
def api(m,p,ok404=False,**k):
    r=requests.request(m,p if p.startswith('http') else B+p,headers={'Authorization':'Bearer '+tok(),'Content-Type':'application/json'},**k)
    if r.status_code>=400:
        print(m,p,r.status_code,r.text[:1500])
        if ok404: return None
        r.raise_for_status()
    return r.json() if r.text else {}
# 1. 等建置處理完
for i in range(60):
    bs=api('GET',f'/builds?filter[app]={APP}&filter[version]={BUILD}&limit=5')['data']
    st=bs[0]['attributes']['processingState'] if bs else 'NOT_FOUND'
    print('build',BUILD,st)
    if st=='VALID': break
    if st in ('FAILED','INVALID'): raise SystemExit('build '+st)
    time.sleep(30)
else: raise SystemExit('build not ready')
bid=bs[0]['id']
# 2. 版本：沒有就建立（會沿用上一版的說明和截圖）
vs=api('GET',f'/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=10')['data']
print('versions',[(v['attributes']['versionString'],v['attributes']['appStoreState']) for v in vs])
v=[x for x in vs if x['attributes']['versionString']==VER]
if v: v=v[0]
else:
    v=api('POST','/appStoreVersions',json={'data':{'type':'appStoreVersions','attributes':{'platform':'IOS','versionString':VER,'releaseType':'AFTER_APPROVAL'},
        'relationships':{'app':{'data':{'type':'apps','id':APP}}}}})['data']
    print('created version',VER)
vid=v['id']
# 3. 掛上建置
api('PATCH',f'/appStoreVersions/{vid}/relationships/build',json={'data':{'type':'builds','id':bid}}); print('build attached')
# 出口合規（沒用到特殊加密）
api('PATCH',f'/builds/{bid}',ok404=True,json={'data':{'type':'builds','id':bid,'attributes':{'usesNonExemptEncryption':False}}})
# 4. 此版本新功能
locs=api('GET',f'/appStoreVersions/{vid}/appStoreVersionLocalizations')['data']
print('locales',[l['attributes']['locale'] for l in locs])
for l in locs:
    if l['attributes']['locale']==LOC and NEW:
        api('PATCH',f"/appStoreVersionLocalizations/{l['id']}",json={'data':{'type':'appStoreVersionLocalizations','id':l['id'],'attributes':{'whatsNew':NEW}}}); print('whatsNew set')
if not SUBMIT: raise SystemExit('prepared, not submitted')
# 5. 送審
subs=api('GET',f'/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW&limit=5')['data']
sid=subs[0]['id'] if subs else api('POST','/reviewSubmissions',json={'data':{'type':'reviewSubmissions','attributes':{'platform':'IOS'},'relationships':{'app':{'data':{'type':'apps','id':APP}}}}})['data']['id']
api('POST','/reviewSubmissionItems',ok404=True,json={'data':{'type':'reviewSubmissionItems','relationships':{'reviewSubmission':{'data':{'type':'reviewSubmissions','id':sid}},'appStoreVersion':{'data':{'type':'appStoreVersions','id':vid}}}}})
r=api('PATCH',f'/reviewSubmissions/{sid}',json={'data':{'type':'reviewSubmissions','id':sid,'attributes':{'submitted':True}}})
print('submitted',r['data']['attributes'].get('state'))
