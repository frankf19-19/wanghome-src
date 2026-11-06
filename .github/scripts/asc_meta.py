# 讀／改 App Store 文字（關鍵字、副標題、宣傳文字）。MODE=read 只讀；MODE=write 依環境變數寫入
import os, time, json, jwt, requests
KID=os.environ['ASC_KEY_ID']; ISS=os.environ['ASC_ISSUER']; KEY=os.environ['ASC_KEY']; APP=os.environ.get('APP_ID','6827632980')
def tok(): return jwt.encode({'iss':ISS,'iat':int(time.time()),'exp':int(time.time())+1100,'aud':'appstoreconnect-v1'},KEY,algorithm='ES256',headers={'kid':KID,'typ':'JWT'})
B='https://api.appstoreconnect.apple.com/v1'
def api(m,p,**k):
    r=requests.request(m,B+p,headers={'Authorization':'Bearer '+tok(),'Content-Type':'application/json'},**k)
    if r.status_code>=400: print(m,p,r.status_code,r.text[:800]); return None
    return r.json() if r.text else {}
vs=api('GET',f'/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=5')['data']
for v in vs:
    print('VERSION',v['attributes']['versionString'],v['attributes']['appStoreState'])
    for l in api('GET',f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations")['data']:
        a=l['attributes'];print(json.dumps({k:a.get(k) for k in ('locale','keywords','promotionalText','marketingUrl','supportUrl')},ensure_ascii=False))
        if os.environ.get('MODE')=='write':
            upd={}
            if os.environ.get('PROMO'): upd['promotionalText']=os.environ['PROMO']
            if os.environ.get('KEYWORDS') and v['attributes']['appStoreState'] in ('PREPARE_FOR_SUBMISSION','DEVELOPER_REJECTED','REJECTED','METADATA_REJECTED','WAITING_FOR_REVIEW','READY_FOR_REVIEW'): upd['keywords']=os.environ['KEYWORDS']
            if upd: print('PATCH',api('PATCH',f"/appStoreVersionLocalizations/{l['id']}",json={'data':{'type':'appStoreVersionLocalizations','id':l['id'],'attributes':upd}}) is not None,list(upd))
infos=api('GET',f'/apps/{APP}/appInfos')['data']
for i in infos:
    for l in api('GET',f"/appInfos/{i['id']}/appInfoLocalizations")['data']:
        a=l['attributes'];print('INFO',json.dumps({k:a.get(k) for k in ('locale','name','subtitle')},ensure_ascii=False))
