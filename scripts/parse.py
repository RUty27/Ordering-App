import openpyxl,json,re
wb=openpyxl.load_workbook('hops.xlsx',data_only=True)
ws=wb['Supplier List']
rows=[list(r) for r in ws.iter_rows(values_only=True)]
W=max(len(r) for r in rows)
def g(r,c): return rows[r][c] if r<len(rows) and c<len(rows[r]) else None
cat={}
for c0 in range(0,W,5):
  sup=None; hdr=None
  for r in range(len(rows)):
    v=g(r,c0)
    if isinstance(v,str) and g(r+1,c0) in ('Category',) :
      sup=v.strip(); hdr=[str(g(r+1,c0+k) or '').strip() for k in range(4)]; continue
    if v=='Category': continue
    if sup and g(r,c0+2):
      d=dict(zip(hdr,[g(r,c0+k) for k in range(4)]))
      cat.setdefault(sup,[]).append(d)
for s,l in cat.items(): print(s,len(l),l[:2])
json.dump(cat,open('catalog.json','w'),default=str)
