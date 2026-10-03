#!/usr/bin/env python3
"""Derive the new packages from src/komira_core using split_map.tsv, rewriting imports. Usage:
  split.py --core <dir holding komira_core/ (and komira_core_ffi/ for --ffi-map)> --map split_map.tsv --out <dir>
           [--pkg NAME] [--ffi-map libc_rename_map.tsv]
`check.py copy` regenerates a package and compares it with a tree (copy_exact).
Pure python3 stdlib; no git; deterministic."""
import os,re,sys,json,collections,argparse
def load_core(root):
    files=[]
    for d,_,fs in os.walk(root):
        for f in fs: files.append(os.path.relpath(os.path.join(d,f),root))
    return sorted(files)
def key(p):
    p=p[:-5]
    if p=='__init__': return '__init__'
    return p[:-9] if p.endswith('/__init__') else p
class Core:
    def __init__(s,root):
        s.root=root; s.files=[f for f in load_core(root) if f.endswith('.mojo') and not f.startswith('tests/')]
        s.keys={key(f):f for f in s.files}; s.dirs={k for k,f in s.keys.items() if f.endswith('__init__.mojo')}
        s.cache={}
    def text(s,f): return open(os.path.join(s.root,f),errors='replace').read()
    def resolve_mod(s,f,mod):
        if mod.startswith('.'):
            n=len(mod)-len(mod.lstrip('.')); rest=mod.lstrip('.'); base=os.path.dirname(f)
            for _ in range(n-1): base=os.path.dirname(base)
            parts=[p for p in base.split('/') if p]+[p for p in rest.split('.') if p]
            return '/'.join(parts) if parts else '__init__'
        if mod=='komira_core': return '__init__'
        if mod.startswith('komira_core.'): return mod[len('komira_core.'):].replace('.','/')
        return None
    def reexports(s,k):
        if k in s.cache: return s.cache[k]
        t={}; s.cache[k]=t; f=s.keys[k]
        for m in STMT.finditer(masked(s.text(f))):
            mod=modname_of(m); r=s.resolve_mod(f,mod)
            if r is None: continue
            for n in names_of(m): t[n]=r
        return t
    def symbol(s,r,n,d=0):
        if r in s.dirs and d<6:
            t=s.reexports(r)
            if n in t: return s.symbol(t[n],n,d+1)
            sub=(r+'/'+n) if r!='__init__' else n
            if sub in s.keys: return sub
        return r
# The module may have blanks after its leading dots: Mojo reads `from .. arrow.x` as `from ..arrow.x` (modname_of() drops them).
STMT=re.compile(r'^([ \t]*)from[ \t]+(\.+[ \t]*[^\s(]+|\S+)[ \t]+import[ \t]*(\([^)]*\)|[^\n]*)',re.M)
def modname_of(m): return re.sub(r'[ \t]','',m.group(2))
def names_of(m):
    body=m.group(3)
    body=re.sub(r'#[^\n]*','',body).strip('() \t\n')
    return [x.strip() for x in body.replace('\n',' ').split(',') if x.strip()]
def masked(t):
    # blank out triple-quoted regions (keeps offsets)
    return re.sub(r'"""(.*?)"""',lambda m:' '*len(m.group(0)) if False else re.sub(r'[^\n]',' ',m.group(0)),t,flags=re.S)
# STMT groups: 1 indent, 2 module, 3 names.
def load_map(path):
    rows=[l.rstrip('\n').split('\t') for l in open(path) if l.strip() and not l.startswith('#')]
    hdr=rows[0]; return [dict(zip(hdr,r)) for r in rows[1:]]
def modname(dest,new_path):
    p=new_path[len('src/'+dest+'/'):-5]
    return dest+'.'+p.replace('/','.')
FFI_WORD=re.compile(r'(?<![A-Za-z0-9_])komira_core_ffi(?![A-Za-z0-9_])')
def derive(core_root,rows,pkg=None,ffi_rows=None):
    core=Core(os.path.join(core_root,'komira_core'))
    core.dirs|={key(r['file']) for r in rows if r['kind']=='src' and r['disposition']=='facade'}
    dest={}
    for r in rows:
        if r['kind']=='src' and r['disposition'] in('copy','moves-with-consumer'): dest[key(r['file'])]=(r['dest'],r['new_path'])
    unresolved=collections.Counter(); out={}
    def rewrite(f,text):
        mt=masked(text); res=[]; last=0
        for m in STMT.finditer(mt):
            r=core.resolve_mod(f,modname_of(m))
            if r is None: continue
            groups=collections.OrderedDict()
            for n in names_of(m):
                nm=n.split(' as ')[0].strip(); t=core.symbol(r,nm)
                if t not in dest: unresolved[(f,modname_of(m),nm,t)]+=1; groups.setdefault('?',[]).append(n); continue
                groups.setdefault(modname(*dest[t]),[]).append(n)
            res.append(text[last:m.start()]); last=m.end(); ind=m.group(1); orig=text[m.start():m.end()]
            if len(groups)==1:
                (tm,_),=groups.items()
                res.append(orig if tm=='?' else ind+'from '+tm+text[m.end(2):m.end()])
            else:
                res.append('\n'.join('%sfrom %s import %s'%(ind,tm,', '.join(ns)) for tm,ns in groups.items()))
        res.append(text[last:]); return textual(''.join(res))
    testdest={r['file']:r['new_path'] for r in rows if r['kind']=='test' and r['disposition'] in('copy','moves-with-consumer')}
    fixdest={r['file']:r['new_path'] for r in rows if r['kind']=='fixture'}
    def textual(t):
        t=FFI_WORD.sub('komira_libc',t)   # komira_core_ffi is renamed komira_libc (word-bounded, so komira_core_posix etc. are untouched)
        def slash(m):
            p=m.group(1)
            if p.startswith('tests/'):
                q=p if p.endswith('.mojo') else p+'.mojo'
                if q in testdest: return testdest[q][len('src/'):]
                if p in fixdest: return fixdest[p][len('src/'):]
                return m.group(0)
            k=p[:-5] if p.endswith('.mojo') else p
            if k in dest: return dest[k][1][len('src/'):]
            return m.group(0)
        t=re.sub(r'komira_core/((?:[a-z0-9_]+/)*[a-z0-9_]+(?:\.(?:mojo|arrow|tensor))?)',lambda m: (lambda r: r if r!=m.group(0) else r)(slash(m)),t)
        def dot(m):
            parts=m.group(1).split('.')
            for n in range(len(parts),0,-1):
                k='/'.join(parts[:n])
                if k in dest: return modname(*dest[k])+''.join('.'+x for x in parts[n:])
            return m.group(0)
        return re.sub(r'komira_core\.((?:[a-z0-9_]+\.)*[a-z0-9_]+)(?![a-z0-9_])',dot,t)
    for r in rows:
        if r['disposition'] not in('copy','moves-with-consumer') or r['kind'] not in('src','test'): continue
        if pkg and r['dest']!=pkg: continue
        f=r['file']
        text=open(os.path.join(core_root,'komira_core',f),errors='replace').read()
        out[r['new_path']]=rewrite(f,text)
    # The 20th package. komira_libc is komira_core_ffi under a new name: the same files, the word renamed.
    # core_root must hold komira_core_ffi/ beside komira_core/ (it is a separate package on main, not part of komira_core).
    for r in (ffi_rows or []):
        if r['disposition']!='copy' or (pkg and r['dest']!=pkg): continue
        out[r['new_path']]=textual(open(os.path.join(core_root,'komira_core_ffi',r['file']),errors='replace').read())
    return out,unresolved
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--core',required=True); ap.add_argument('--map',required=True)
    ap.add_argument('--out',required=True); ap.add_argument('--pkg'); ap.add_argument('--ffi-map')
    a=ap.parse_args()
    out,unres=derive(a.core,load_map(a.map),a.pkg,load_map(a.ffi_map) if a.ffi_map else None)
    for p,t in out.items():
        fp=os.path.join(a.out,p); os.makedirs(os.path.dirname(fp),exist_ok=True); open(fp,'w').write(t)
    print('wrote',len(out),'files; unresolved import names:',sum(unres.values()))
    for k in list(unres)[:10]: print(' unresolved',k)
if __name__=='__main__': main()
