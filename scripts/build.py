# Turns catalog.json + items.json (from parse.py) into data.json.
# Business-specific settings (supplier aliases, MOQs, cut-offs, extra items) live in
# scripts/config.local.json, which is git-ignored. Falls back to config.example.json.
import json,re,pathlib
here=pathlib.Path(__file__).resolve().parent
cfg_path=here/'config.local.json'
if not cfg_path.exists(): cfg_path=here/'config.example.json'
cfg=json.load(open(cfg_path,encoding='utf-8'))
print('Using',cfg_path.name)

items=json.load(open('items.json')); cat=json.load(open('catalog.json'))
ALIAS=cfg.get('alias',{})
def norm(s): return ALIAS.get(s.strip().lower(), s.strip())
ONLINE=set(cfg.get('online',[]))
INTERNAL=cfg.get('internal','Office')
junk=re.compile(cfg.get('junk_supplier_regex','^\\d'),re.I)
SKIP=set(cfg.get('skip_suppliers',[]))
COCK_EX=re.compile(cfg.get('cocktail_exclude_regex','$^'))
MOQ=cfg.get('moq',{})
MOQN={k:float(re.match(r'\$(\d+)',v).group(1)) for k,v in MOQ.items()}
CUT=cfg.get('cut',{})
out={}
def add(name,sup,price=None,cat_=None,promo=None,cocktails=None,pack=None):
  sup=norm(sup)
  if junk.match(sup) or sup in SKIP: return
  name=' '.join(str(name).split())
  k=(name.lower(),sup)
  e=out.setdefault(k,{'n':name,'s':sup})
  if price is not None and 'p' not in e:
    try: e['p']=float(price)
    except: e['pt']=str(price)
  if cat_ and cat_!='-': e['c']=cat_
  if promo: e['pr']=str(promo).strip()
  if pack: e['pk']=pack
  if cocktails: e.setdefault('k',[]); [e['k'].append(c) for c in cocktails if c not in e['k']]
for s,l in cat.items():
  for d in l:
    pr=d.get('Pricing'); promo=d.get('Trade / Promotions') or d.get('Trade / Promostions') or d.get('Notes')
    if norm(s)==INTERNAL: pr=None
    add(d['Product'],s,pr,d.get('Category'),promo)
for e in items:
  ks=[c for c in e['cocktails'] if not COCK_EX.search(c)]
  if not ks: continue
  add(e['item'],e['supplier'],cocktails=ks)
# items that aren't in the sheet (e.g. packaging, pastry)
for x in cfg.get('extra_items',[]):
  add(x['n'],x['s'],x.get('p'),x.get('c'),pack=x.get('pk'))
L=sorted(out.values(),key=lambda e:(e['s'],e['n'].lower()))
for i,e in enumerate(L): e['id']=i
sups=sorted({e['s'] for e in L})
S=[{'n':s,'t':'online' if s in ONLINE else 'internal' if s==INTERNAL else 'none' if s=='Unassigned' else 'chat','m':MOQ.get(s),'mn':MOQN.get(s),'cut':CUT.get(s)} for s in sups]
head={k:cfg[k] for k in ('billing','addresses','deliveryTime') if k in cfg}
json.dump({'business':cfg.get('business',''),'outlets':cfg.get('outlets',[]),**head,'items':L,'suppliers':S},open('data.json','w'),ensure_ascii=False,separators=(',',':'))
print(len(L),[ (s['n'],sum(1 for e in L if e['s']==s['n'])) for s in S])
