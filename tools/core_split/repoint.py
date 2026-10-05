#!/usr/bin/env python3
"""repoint.py: rewrite the importers of src/komira_core (and src/komira_core_ffi) in place, onto the packages that
replaced them. It can be run on a tree again and again, on main or on an open branch: a file with nothing left to
rewrite is not touched, and a second run changes nothing.

  repoint.py [--tree DIR] [--core-root DIR | --core-rev REV] [--only PREFIX]... [--exclude PREFIX]...
             [--dry-run] [--report FILE] [--strict] [--renames]

What it does to each file outside the frozen packages:
  * `.mojo`: every `from komira_core.<module> import <names>` is rewritten to the package that now defines the module.
    A name imported through a re-exporting `__init__.mojo` (`from komira_core.arrow import Column`) is resolved to
    the module that defines it, by symbol, so one statement can become several. Relative imports are left alone.
    Dotted and slashed mentions in comments and strings are rewritten the same way, and `komira_core_ffi` becomes
    `komira_libc`.
  * `BUCK`: the `//src/komira_core:komira_core` and `//src/komira_core_ffi:komira_core_ffi` deps are removed and the
    packages the directory's files import (and the owners of the C symbols they call) are added, sorted among the
    others. The set is derived from the files, so it is minimal and has nothing stale.
  * `.md`, `.bzl`, `.sh`, `.py`: the same dotted and slashed mentions.
  * The five modules the map marks `moves-with-consumer` are created in their consumer package (with their tests
    added to its `test_srcs`) the first time.
With --renames, the package renames of RENAMES are done too (directory, imports, BUCK labels, text); without it a
rename that the tree has already done is still honoured in what the tool writes.

The frozen komira_core is read from --core-root (a directory holding komira_core/), from the tree itself while
src/komira_core still exists, or, once it is deleted, from the parent of the commit that deleted it (--core-rev
overrides that). Exit 0 when done (or, with --dry-run, always); with --strict exit 1 if an imported name could not be
resolved or an import of komira_core is left. Pure python3 stdlib, deterministic."""
import os,re,sys,subprocess,tempfile,argparse,shutil,collections
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import split as S
import deps as D
# package renames decided after the copies were made; applied by --renames, honoured once the directory has moved
RENAMES=[('komira_scalar_arith','komira_scalar_arithmetic'),('komira_concurrency','komira_async_api'),('komira_agg_contract','komira_agg_api')]
ALWAYS_EXCLUDE=('src/komira_core/','src/komira_core_ffi/','tools/core_split/','.github/workflows/core_split.yml','.git/','buck-out/')
TEXT_EXT=('.mojo','.md','.bzl','.sh','.py','.tsv','.txt','.toml','.yml','.yaml','.textproto')
CORE=re.compile(r'(?<![A-Za-z0-9_])komira_core(?:_ffi)?(?![A-Za-z0-9_])')
HARD=re.compile(r'(?m)^[ \t]*(?:from|import)[ \t]+komira_core(?:_ffi)?(?![A-Za-z0-9_])|//src/komira_core(?:_ffi)?:')
def word(n): return re.compile(r'(?<![A-Za-z0-9_])'+re.escape(n)+r'(?![A-Za-z0-9_])')
def git(tree,*a): return subprocess.run(['git','-C',tree]+list(a),capture_output=True,text=True)
def frozen_root(a):
    """-> (directory holding komira_core/ and komira_core_ffi/, cleanup)."""
    if a.core_root: return a.core_root,None
    if os.path.isdir(os.path.join(a.tree,'src','komira_core')): return os.path.join(a.tree,'src'),None
    rev=a.core_rev
    if not rev:
        r=git(a.tree,'log','--diff-filter=D','--format=%H','-n','1','--','src/komira_core/BUCK')
        if not r.stdout.strip(): sys.exit('repoint: src/komira_core is gone and no commit that deleted it was found; pass --core-rev or --core-root')
        rev=r.stdout.strip()+'^'
    tmp=tempfile.mkdtemp(prefix='repoint_core.'); p=subprocess.run('git -C %s archive %s src/komira_core src/komira_core_ffi | tar -x -C %s'%(a.tree,rev,tmp),shell=True,capture_output=True,text=True)
    if p.returncode: sys.exit('repoint: git archive of %s failed: %s'%(rev,p.stderr.strip()))
    return os.path.join(tmp,'src'),tmp
def tracked(tree):
    r=git(tree,'ls-files','-z')
    if r.returncode: sys.exit('repoint: %s is not a git tree: %s'%(tree,r.stderr.strip()))
    return sorted(f for f in r.stdout.split('\0') if f and os.path.isfile(os.path.join(tree,f)))
def under(f,prefixes): return any(f==p.rstrip('/') or f.startswith(p.rstrip('/')+'/') for p in prefixes)
def read(p):
    try: return open(p,encoding='utf-8').read()
    except (UnicodeDecodeError,OSError): return None
def active_renames(tree,do):
    """The renames in force: done in the tree already (new directory exists, old one gone), or asked for."""
    out=[]
    for o,n in RENAMES:
        od,nd=[os.path.isdir(os.path.join(tree,'src',x)) for x in (o,n)]
        if nd and not od: out.append((o,n,'done'))
        elif od and do: out.append((o,n,'todo'))
    return out
# ---- BUCK -----------------------------------------------------------------------------------------------------
DEPS_BLOCK=re.compile(r'(?ms)^([ \t]*)deps = \[\n(.*?)^\1\]')
LABEL=re.compile(r'^\s*"([^"]+)",\s*$')
def derive_dir_deps(tree,bdir,texts,known,own,third):
    """-> (set of dep labels, problems) for the .mojo files under bdir (not under a nested BUCK), reading the new text
    of a file from `texts` when it is being rewritten."""
    deps=set(); here=os.path.basename(bdir.rstrip('/')); pkg=here
    def scan(t):
        for x in D.IMPORT.findall(t):
            if x!=pkg and x in known: deps.add('//src/%s:%s'%(x,x))
        for sy in D.CALL.findall(t):
            if sy.startswith('komira_'):
                o=own.get(sy)
                if o and o!=pkg: deps.add('//src/%s:%s'%(o,o))
            else:
                for pre,lab in third:
                    if sy.startswith(pre): deps.add(lab)
    for d,ds,fs in os.walk(os.path.join(tree,bdir)):
        rel=os.path.relpath(d,tree)
        ds[:]=[x for x in ds if not os.path.exists(os.path.join(d,x,'BUCK')) and x not in('buck-out','.git')]
        for f in fs:
            if not f.endswith('.mojo'): continue
            p=os.path.join(rel,f); t=texts.get(p)
            if t is None: t=read(os.path.join(tree,p)) or ''
            scan(D.mask(t))
    for p,t in texts.items():
        if p.startswith(bdir.rstrip('/')+'/') and p.endswith('.mojo') and not os.path.exists(os.path.join(tree,p)) and not os.path.exists(os.path.join(tree,os.path.dirname(p),'BUCK')):
            scan(D.mask(t))
    return deps
def fix_buck(tree,bpath,text,texts,known,own,third,rename_map):
    """Rewrite the deps blocks of one BUCK that name komira_core / komira_core_ffi. -> new text, notes."""
    notes=[]; bdir=os.path.dirname(bpath)
    def block(m):
        ind,body=m.group(1),m.group(2); lines=body.split('\n')[:-1] if body.endswith('\n') else body.split('\n')
        if not any(LABEL.match(l) and LABEL.match(l).group(1) in('//src/komira_core:komira_core','//src/komira_core_ffi:komira_core_ffi') for l in lines): return m.group(0)
        have={LABEL.match(l).group(1) for l in lines if LABEL.match(l)}
        want=derive_dir_deps(tree,bdir,texts,known,own,third)
        want={rename_map.get(w,w) for w in want}
        keep=[l for l in lines if not (LABEL.match(l) and LABEL.match(l).group(1) in('//src/komira_core:komira_core','//src/komira_core_ffi:komira_core_ffi'))]
        add=sorted(w for w in want if w not in have)
        for w in add:
            item='%s    "%s",'%(ind,w); pos=None
            for i,l in enumerate(keep):
                mm=LABEL.match(l)
                if mm and not mm.group(1).startswith(':') and mm.group(1)>w: pos=i; break
            if pos is None:
                last=max([i for i,l in enumerate(keep) if LABEL.match(l)] or [-1]); pos=last+1
            keep.insert(pos,item)
        notes.append('%s: -komira_core%s +%s'%(bpath,'(_ffi)' if '//src/komira_core_ffi:komira_core_ffi' in have else '',' '.join(add) or 'nothing'))
        return '%sdeps = [\n%s\n%s]'%(ind,'\n'.join(keep),ind)
    def inline(m):
        ind,body=m.group(1),m.group(2); labs=re.findall(r'"([^"]+)"',body)
        if not any(l in('//src/komira_core:komira_core','//src/komira_core_ffi:komira_core_ffi') for l in labs): return m.group(0)
        want={rename_map.get(w,w) for w in derive_dir_deps(tree,bdir,texts,known,own,third)}
        keep=[l for l in labs if l not in('//src/komira_core:komira_core','//src/komira_core_ffi:komira_core_ffi')]
        add=sorted(w for w in want if w not in keep); allv=sorted(set(keep)|set(add),key=lambda x:(not x.startswith(':'),x))
        notes.append('%s: -komira_core +%s'%(bpath,' '.join(add) or 'nothing'))
        one='%sdeps = [%s]'%(ind,', '.join('"%s"'%x for x in allv))
        return one if len(one)<=100 else '%sdeps = [\n%s\n%s]'%(ind,'\n'.join('%s    "%s",'%(ind,x) for x in allv),ind)
    text=DEPS_BLOCK.sub(block,text)
    return re.sub(r'(?m)^([ \t]*)deps = \[([^\]\n]*)\]',inline,text),notes
def add_test_srcs(text,tests):
    """Add `"tests/x.mojo",` entries to the test_srcs list of a BUCK, sorted; -> text."""
    m=re.search(r'(?ms)^([ \t]*)test_srcs = \[\n(.*?)^\1\]',text)
    if not m: return text
    ind=m.group(1); lines=m.group(2).rstrip('\n').split('\n')
    have={LABEL.match(l).group(1) for l in lines if LABEL.match(l)}
    for t in tests:
        if t in have: continue
        item='%s    "%s",'%(ind,t); pos=len(lines)
        for i,l in enumerate(lines):
            mm=LABEL.match(l)
            if mm and mm.group(1)>t: pos=i; break
        lines.insert(pos,item)
    return text[:m.start()]+'%stest_srcs = [\n%s\n%s]'%(ind,'\n'.join(lines),ind)+text[m.end():]
# ---- main -----------------------------------------------------------------------------------------------------
def run(a):
    tree=os.path.abspath(a.tree); croot,cleanup=frozen_root(a)
    rows=S.load_map(os.path.join(HERE,'split_map.tsv')) if not a.map else S.load_map(a.map)
    rw=S.Rewriter(croot,rows,external=True)
    files=[f for f in tracked(tree) if not under(f,ALWAYS_EXCLUDE) and not under(f,a.exclude) and (not a.only or under(f,a.only))]
    rens=active_renames(tree,a.renames); rename_re=[(word(o),n) for o,n,_ in rens]; rename_map={'//src/%s:%s'%(o,o):'//src/%s:%s'%(n,n) for o,n,_ in rens}
    own,third=D.load_symbols(os.path.join(HERE,'c_symbols.tsv'))
    known=({d for d in os.listdir(os.path.join(tree,'src'))} if os.path.isdir(os.path.join(tree,'src')) else set())
    known|={n for _,n,_ in rens}; known-={o for o,_,st in rens if st=='todo'}; known-={'komira_core','komira_core_ffi'}
    def rn(t):
        for r,n in rename_re: t=r.sub(n,t)
        return t
    new={}; stats=collections.Counter(); notes=[]
    # the modules that move with their consumer are created first (they are new files)
    created={}
    inner=S.Rewriter(croot,rows,external=False)
    for r in rows:
        if r['disposition']!='moves-with-consumer' or r['kind'] not in('src','test'): continue
        np=r['new_path']
        if os.path.exists(os.path.join(tree,np)) or not os.path.exists(os.path.join(croot,'komira_core',r['file'])): continue
        if a.only and not under(np,a.only): continue
        created[np]=rn(inner.rewrite(r['file'],open(os.path.join(croot,'komira_core',r['file']),errors='replace').read()))
        stats['created']+=1
    for np,t in created.items(): new[np]=t
    for f in files:
        if not f.endswith(TEXT_EXT) and os.path.basename(f) not in('BUCK','BUCK.v2'): continue
        t=read(os.path.join(tree,f))
        if t is None: continue
        if not (CORE.search(t) or any(r.search(t) for r,_ in rename_re)): continue
        if os.path.basename(f) in('BUCK','BUCK.v2'): continue
        u=rw.rewrite(f,t) if f.endswith('.mojo') else rw.textual(t)
        u=rn(u)
        if u!=t: new[f]=u; stats['files_'+('mojo' if f.endswith('.mojo') else 'text')]+=1
    # created files may belong to a package whose BUCK needs the tests
    texts=dict(new)
    for f in files:
        if os.path.basename(f) not in('BUCK','BUCK.v2'): continue
        t=read(os.path.join(tree,f))
        if t is None: continue
        u=t
        if CORE.search(t) or any(r.search(t) for r,_ in rename_re):
            u,n=fix_buck(tree,f,t,texts,known,own,third,rename_map); notes+=n; u=rn(u)
        pk=os.path.dirname(f)
        added=[np[len(pk)+1:] for np in created if np.startswith(pk+'/tests/') and np.endswith('.mojo') and os.path.dirname(os.path.dirname(np))==pk]
        if added: u=add_test_srcs(u,added)
        if u!=t: new[f]=u; stats['buck']+=1
    # renames: directories
    moves=[]
    for o,n,st in rens:
        if st=='todo': moves.append((os.path.join('src',o),os.path.join('src',n)))
    # report
    left=[]; unresolved=dict(rw.unresolved)
    for f in files:
        t=new.get(f) if f in new else read(os.path.join(tree,f))
        if t is None: continue
        for i,l in enumerate(t.split('\n')):
            if CORE.search(l): left.append((f,i+1,'IMPORT/DEP' if HARD.search(l) else 'prose',l.strip()[:140]))
    lines=['repoint report for %s'%tree,'files rewritten: %d (mojo %d, text %d, BUCK %d), created %d, directory moves %d'%(len(new),stats['files_mojo'],stats['files_text'],stats['buck'],stats['created'],len(moves)),
           'unresolved imported names: %d'%sum(unresolved.values())]
    lines+=['  unresolved %s'%(k,) for k in sorted(unresolved)][:40]
    lines+=['BUCK: '+n for n in notes]
    hard=[x for x in left if x[2]=='IMPORT/DEP']; prose=[x for x in left if x[2]=='prose']
    lines.append('left after the rewrite: %d import/dep lines, %d prose mentions'%(len(hard),len(prose)))
    lines+=['  HARD %s:%d %s'%(f,n,l) for f,n,k,l in hard]+['  prose %s:%d %s'%(f,n,l) for f,n,k,l in prose]
    rep='\n'.join(lines)+'\n'
    if a.report: open(a.report,'w').write(rep)
    else: print(rep[:6000])
    if not a.dry_run:
        for f,t in new.items():
            p=os.path.join(tree,f); os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'w').write(t)
        for o,n in moves:
            r=git(tree,'mv',o,n)
            if r.returncode: os.rename(os.path.join(tree,o),os.path.join(tree,n))
    if cleanup: shutil.rmtree(cleanup,ignore_errors=True)
    print('repoint: %s %d files, %d unresolved names, %d import/dep lines left'%('would rewrite' if a.dry_run else 'rewrote',len(new),sum(unresolved.values()),len(hard)))
    if a.strict and (unresolved or hard): return 1
    return 0
def main():
    ap=argparse.ArgumentParser(description=__doc__.split('\n')[0]); ap.add_argument('--tree',default='.'); ap.add_argument('--core-root'); ap.add_argument('--core-rev')
    ap.add_argument('--map'); ap.add_argument('--only',action='append',default=[]); ap.add_argument('--exclude',action='append',default=[])
    ap.add_argument('--dry-run',action='store_true'); ap.add_argument('--report'); ap.add_argument('--strict',action='store_true'); ap.add_argument('--renames',action='store_true')
    return run(ap.parse_args())
if __name__=='__main__': sys.exit(main())
