import numpy as np, onnxruntime as ort
from PIL import Image
_S={}
def detect(im, model, size=416):
    """YOLOX：回傳 [(score, cls, x0,y0,x1,y1)]（原圖座標），只留貓(15)狗(16)，另外也回傳其他動物類別當備援"""
    if model not in _S: _S[model]=ort.InferenceSession(model,providers=['CPUExecutionProvider'])
    w,h=im.size; r=min(size/w,size/h); nw,nh=int(w*r),int(h*r)
    canvas=np.full((size,size,3),114,dtype=np.float32); canvas[:nh,:nw]=np.asarray(im.resize((nw,nh),Image.BILINEAR),dtype=np.float32)[:,:,::-1]
    out=_S[model].run(None,{'images':canvas.transpose(2,0,1)[None]})[0][0]
    grids=[];strides=[]
    for s in (8,16,32):
        n=size//s; yy,xx=np.mgrid[0:n,0:n]; grids.append(np.stack([xx,yy],-1).reshape(-1,2)); strides.append(np.full((n*n,1),s))
    g=np.concatenate(grids); st=np.concatenate(strides)
    xy=(out[:,:2]+g)*st; wh=np.exp(out[:,2:4])*st
    sc=out[:,4:5]*out[:,5:]
    res=[]
    for c in (15,16,17,18,19,21):   # cat dog horse sheep cow bear（狗貓常被認成這些）
        i=int(sc[:,c].argmax()); s=float(sc[i,c])
        if s>0.15:
            x,y=xy[i]/r; bw,bh=wh[i]/r
            res.append((s*(1 if c in(15,16) else .6),c,max(0,x-bw/2),max(0,y-bh/2),min(w,x+bw/2),min(h,y+bh/2)))
    return sorted(res,reverse=True)

def detect_multi(im, model, size=416, k=4):
    """同一張照片裡最多找出 k 隻狗／貓（海報常把同一隻的好幾張照片排在一起）。
    回傳 [(score, cls, x0,y0,x1,y1)]，第一個和 detect() 的第一個相同；太小的框（小於整張 2%）和重疊的框不要。"""
    if model not in _S: _S[model]=ort.InferenceSession(model,providers=['CPUExecutionProvider'])
    w,h=im.size; r=min(size/w,size/h); nw,nh=int(w*r),int(h*r)
    canvas=np.full((size,size,3),114,dtype=np.float32); canvas[:nh,:nw]=np.asarray(im.resize((nw,nh),Image.BILINEAR),dtype=np.float32)[:,:,::-1]
    out=_S[model].run(None,{'images':canvas.transpose(2,0,1)[None]})[0][0]
    grids=[];strides=[]
    for s in (8,16,32):
        n=size//s; yy,xx=np.mgrid[0:n,0:n]; grids.append(np.stack([xx,yy],-1).reshape(-1,2)); strides.append(np.full((n*n,1),s))
    g=np.concatenate(grids); st=np.concatenate(strides)
    xy=(out[:,:2]+g)*st; wh=np.exp(out[:,2:4])*st
    sc=out[:,4:5]*out[:,5:]
    first=detect(im,model,size)
    cand=[]
    for c in (15,16,17,18,19,21):
        s=sc[:,c]*(1 if c in(15,16) else .6)
        for i in np.where(s>0.3)[0]:
            x,y=xy[i]/r; bw,bh=wh[i]/r
            cand.append((float(s[i]),c,max(0,x-bw/2),max(0,y-bh/2),min(w,x+bw/2),min(h,y+bh/2)))
    cand.sort(reverse=True)
    def iou(a,b):
        ix=max(0,min(a[4],b[4])-max(a[2],b[2])); iy=max(0,min(a[5],b[5])-max(a[3],b[3])); inter=ix*iy
        return inter/((a[4]-a[2])*(a[5]-a[3])+(b[4]-b[2])*(b[5]-b[3])-inter+1e-9)
    keep=[first[0]] if first and first[0][0]>=0.3 else []
    for c_ in cand:
        if (c_[4]-c_[2])*(c_[5]-c_[3])<0.02*w*h: continue
        if all(iou(c_,kk)<0.45 for kk in keep): keep.append(c_)
        if len(keep)>=k: break
    return keep
