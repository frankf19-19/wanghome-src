// 產生 Apple 登入的 client secret（ES256 JWT，Apple 上限 6 個月），並寫進 Supabase 的 Apple 設定
// 需要環境變數：APPLE_SIGNIN_P8（.p8 內容）、SUPABASE_ACCESS_TOKEN；其餘有預設值
import crypto from 'node:crypto';
const TEAM=process.env.APPLE_TEAM_ID||'ZUM3ZK5KB3', KID=process.env.APPLE_KEY_ID||'T49UJMCZ35', SUB=process.env.APPLE_SERVICES_ID||'com.wangmiaotw.web';
const REF=process.env.SUPABASE_PROJECT_REF||'nopyhfpaykkiieudvoko';
const p8=process.env.APPLE_SIGNIN_P8, tok=process.env.SUPABASE_ACCESS_TOKEN;
if(!p8) { console.log('::error::缺少 GitHub Secret APPLE_SIGNIN_P8（名稱要一模一樣）'); process.exit(1); }
const b64u=b=>Buffer.from(b).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
const iat=Math.floor(Date.now()/1000), exp=iat+15777000-60;
const header=b64u(JSON.stringify({alg:'ES256',kid:KID,typ:'JWT'}));
const payload=b64u(JSON.stringify({iss:TEAM,iat,exp,aud:'https://appleid.apple.com',sub:SUB}));
let key;try{key=crypto.createPrivateKey(p8.includes('BEGIN')?p8:`-----BEGIN PRIVATE KEY-----\n${p8}\n-----END PRIVATE KEY-----`)}catch(e){console.log('::error::APPLE_SIGNIN_P8 內容不是有效的 .p8 私鑰：'+e.message);process.exit(1)}
const sig=crypto.sign('sha256',Buffer.from(header+'.'+payload),{key,dsaEncoding:'ieee-p1363'});
const jwt=header+'.'+payload+'.'+b64u(sig);
console.log('已產生 Apple secret，到期：'+new Date(exp*1000).toISOString().slice(0,10));
if(process.env.DRY_RUN==='1'){console.log('DRY_RUN：不寫入 Supabase');process.exit(0)}
if(!tok){console.log('::error::缺少 GitHub Secret SUPABASE_ACCESS_TOKEN（名稱要一模一樣）');process.exit(1)}
const r=await fetch(`https://api.supabase.com/v1/projects/${REF}/config/auth`,{method:'PATCH',headers:{Authorization:'Bearer '+tok,'Content-Type':'application/json'},body:JSON.stringify({external_apple_secret:jwt})});
if(!r.ok){console.log('::error::Supabase 更新失敗 HTTP '+r.status+'：'+(await r.text()).slice(0,200).replace(/\n/g,' '));process.exit(1)}
const j=await r.json();console.log('Supabase 已更新：external_apple_enabled =',j.external_apple_enabled,'client_id =',j.external_apple_client_id);
