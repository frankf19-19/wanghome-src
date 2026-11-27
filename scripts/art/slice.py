import sys,numpy as np
from PIL import Image
from scipy import ndimage as ndi
def slice_sheet(path,names,rows=3,cols=3,out='out',size=320):
    im=Image.open(path).convert('RGB');a=np.asarray(im).astype(np.int16);H,W=a.shape[:2]
    white=(a.min(axis=2)>=238)&((a.max(axis=2)-a.min(axis=2))<14)
    # 背景＝從邊緣連通的白色區域（圖裡面的白色不會被挖掉）
    lab,n=ndi.label(white);edge=set(np.unique(np.concatenate([lab[0],lab[-1],lab[:,0],lab[:,-1]])))-{0}
    bg=np.isin(lab,list(edge));fg=~bg
    fg=ndi.binary_opening(fg,iterations=1)
    lab2,n2=ndi.label(fg);objs=ndi.find_objects(lab2);sizes=ndi.sum(fg,lab2,range(1,n2+1))
    cells={}
    for i,sl in enumerate(objs):
        if sizes[i]<60:continue
        cy=(sl[0].start+sl[0].stop)/2;cx=(sl[1].start+sl[1].stop)/2
        k=(min(rows-1,int(cy/H*rows)),min(cols-1,int(cx/W*cols)))
        b=cells.get(k);box=[sl[0].start,sl[0].stop,sl[1].start,sl[1].stop]
        cells[k]=box if b is None else [min(b[0],box[0]),max(b[1],box[1]),min(b[2],box[2]),max(b[3],box[3])]
    alpha=(~bg).astype(np.float32);alpha=ndi.gaussian_filter(alpha,0.7);alpha=np.clip((alpha-0.5)/0.42,0,1)
    rgba=np.dstack([np.asarray(im),(alpha*255).astype(np.uint8)])
    import os;os.makedirs(out,exist_ok=True);res=[]
    for r in range(rows):
        for c in range(cols):
            nm=names[r*cols+c]
            if not nm or (r,c) not in cells:res.append((nm,None));continue
            y0,y1,x0,x1=cells[(r,c)];p=3;y0=max(0,y0-p);x0=max(0,x0-p);y1=min(H,y1+p);x1=min(W,x1+p)
            crop=Image.fromarray(rgba[y0:y1,x0:x1],'RGBA');s=max(crop.size);sq=Image.new('RGBA',(s,s),(0,0,0,0));sq.paste(crop,((s-crop.width)//2,(s-crop.height)//2))
            sq=sq.resize((size,size),Image.LANCZOS);sq.save(f'{out}/{nm}.webp',quality=90,method=6);res.append((nm,(x1-x0,y1-y0)))
    return res
if __name__=='__main__':
    print(slice_sheet(sys.argv[1],sys.argv[2].split(','),int(sys.argv[3]) if len(sys.argv)>3 else 3,int(sys.argv[4]) if len(sys.argv)>4 else 3))
