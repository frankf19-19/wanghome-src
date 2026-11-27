import numpy as np,os,sys
from PIL import Image
from scipy import ndimage as ndi
def slice_grid(path,names,rows,cols,out='out',size=256,pad=6):
    im=Image.open(path).convert('RGB');A=np.asarray(im);H,W=A.shape[:2];os.makedirs(out,exist_ok=True);res=[]
    a=A.astype(np.int16);white=(a.min(axis=2)>=236)&((a.max(axis=2)-a.min(axis=2))<16)
    for r in range(rows):
        for c in range(cols):
            nm=names[r*cols+c]
            y0,y1=int(r*H/rows),int((r+1)*H/rows);x0,x1=int(c*W/cols),int((c+1)*W/cols)
            w=white[y0:y1,x0:x1];nw=ndi.binary_opening(~w,iterations=1)
            fg=ndi.binary_erosion(ndi.binary_fill_holes(ndi.binary_dilation(nw,iterations=4)),iterations=4)|nw
            # 只留跟最大塊相連或靠近的部分（去掉鄰格伸過來的小碎片）
            l2,n2=ndi.label(ndi.binary_dilation(fg,iterations=6))
            if n2==0:res.append((nm,None));continue
            sz=ndi.sum(fg,l2,range(1,n2+1));keep=[i+1 for i,s in enumerate(sz) if s>=0.04*sz.max()]
            m=fg&np.isin(l2,keep)
            # 碰到格子邊的碎塊（鄰居的耳朵）去掉
            l3,n3=ndi.label(m)
            for i in range(1,n3+1):
                comp=l3==i;ys,xs=np.where(comp)
                touch=(ys.min()==0 or xs.min()==0 or ys.max()==m.shape[0]-1 or xs.max()==m.shape[1]-1)
                if touch and comp.sum()<0.15*m.sum():m[comp]=False
            alpha=ndi.gaussian_filter(m.astype(np.float32),0.7);alpha=np.clip((alpha-0.5)/0.42,0,1)
            ys,xs=np.where(m);by0,by1,bx0,bx1=max(0,ys.min()-pad),min(m.shape[0],ys.max()+pad),max(0,xs.min()-pad),min(m.shape[1],xs.max()+pad)
            rgba=np.dstack([A[y0:y1,x0:x1],(alpha*255).astype(np.uint8)])[by0:by1,bx0:bx1]
            crop=Image.fromarray(rgba,'RGBA');s=max(crop.size);sq=Image.new('RGBA',(s,s),(0,0,0,0));sq.paste(crop,((s-crop.width)//2,(s-crop.height)//2))
            sq.resize((size,size),Image.LANCZOS).save(f'{out}/{nm}.webp',quality=88,method=4);res.append((nm,crop.size))
    return res
