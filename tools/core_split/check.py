#!/usr/bin/env python3
"""The checks of the komira_core split. Each subcommand exits 0 (green) or 1 (red) and says why.
  check.py digest   --core DIR [--record FILE | --expect FILE]
  check.py map      --core DIR --map TSV            # map_total: every tracked file has exactly one row
  check.py copy     --core DIR --map TSV --pkg P --tree DIR   # copy_exact for one package
  check.py copy_range --repo DIR [--base SHA] [--head REF] --map TSV --ffi-map TSV   # copy_exact over a commit range
  check.py deps --tree DIR [--pkg P] [--map TSV] [--core DIR]   # deps_derived: BUCK deps == deps derived from the package's files
  check.py importers --root DIR [--word W] [--exclude PREFIX]...   # no_core_importers / no_komira_core_ffi_importers (word-bounded)
  check.py digest|map take --pkg-dir komira_core_ffi for the rename source; copy takes --ffi-map libc_rename_map.tsv for komira_libc
"""
import os,sys,hashlib,re,argparse,subprocess,tempfile
sys.path.insert(0,os.path.dirname(__file__))
import split as S
def tree_digest(root):
    """sha256 of the listing `<sha256 of the file>  <path>` of every file under root, one per line, paths
    sorted bytewise. The Buck test targets (defs.bzl) compute the same digest with sha256sum and sort."""
    paths=sorted(os.path.relpath(os.path.join(d,f),root) for d,_,fs in os.walk(root) for f in fs)
    listing=''.join('%s  %s\n'%(hashlib.sha256(open(os.path.join(root,p),'rb').read()).hexdigest(),p) for p in paths)
    return hashlib.sha256(listing.encode()).hexdigest(),len(paths)
def git(repo,*args): return subprocess.run(['git','-C',repo]+list(args),capture_output=True,text=True,check=True).stdout
def copy_range(a):
    """copy_exact over a commit range: every commit whose message has a `Core-Split-Copy: <package>` trailer must hold
    what split.py generates from the src/komira_core of that same commit. --base empty = the whole history of --head
    (the push and manual-run case). Zero trailered commits is reported as NOT CHECKED, never as GREEN: a check that
    compared nothing has not passed. Exit 0 green or not-checked, 1 red."""
    rng=(a.base+'..'+a.head) if a.base else a.head
    shas=git(a.repo,'rev-list','--reverse',rng).split(); checked=[]; red=[]
    here=os.path.dirname(os.path.abspath(__file__))
    for sha in shas:
        pkg=git(a.repo,'log','-n','1','--format=%(trailers:key=Core-Split-Copy,valueonly)',sha).strip()
        if not pkg: continue
        tmp=tempfile.mkdtemp(prefix='copy_exact.'); wt=os.path.join(tmp,'wt')
        git(a.repo,'worktree','add','--detach',wt,sha)
        try:
            r=subprocess.run([sys.executable,os.path.join(here,'check.py'),'copy','--core',os.path.join(wt,'src'),'--map',a.map,'--ffi-map',a.ffi_map,'--pkg',pkg,'--tree',wt],capture_output=True,text=True)
            print('  %s %s: %s'%(sha[:10],pkg,(r.stdout+r.stderr).strip())); checked.append(sha)
            if r.returncode: red.append(sha)
        finally:
            git(a.repo,'worktree','remove','--force',wt); os.rmdir(tmp)
    if red: print('copy_exact RED:',len(red),'of',len(checked),'trailered commits differ from what split.py generates'); return 1
    if not checked: print('copy_exact NOT CHECKED: no commit in %s has a Core-Split-Copy trailer, so nothing was compared (this is a report, not a pass)'%rng); return 0
    print('copy_exact GREEN:',len(checked),'trailered commits equal what split.py generates'); return 0
def deps_check(a):
    """The deps of each package's BUCK equal the deps derived from its own files (deps.py). Also, with --core, every
    komira_ symbol of the C shim has an owner in c_symbols.tsv and no row names a symbol the shim lacks."""
    import deps as D
    here=os.path.dirname(os.path.abspath(__file__)); desc=[l.split('\t')[0] for l in open(os.path.join(here,'packages.tsv')) if l.strip() and not l.startswith('#') and not l.startswith('package\t')]
    maps=[S.load_map(a.map)] if a.map else []; known=D.first_party(a.tree,*maps)|set(desc); bad=[]; n=0
    for pkg in ([a.pkg] if a.pkg else desc):
        b=os.path.join(a.tree,'src',pkg,'BUCK')
        if not os.path.isdir(os.path.join(a.tree,'src',pkg)):
            if a.pkg: print('deps_derived RED:',pkg,'has no directory in',a.tree); return 1
            continue
        n+=1
        if not os.path.exists(b): bad.append('%s: no BUCK file'%pkg); continue
        want,problems=D.derive_deps(a.tree,pkg,known,a.symbols); have=D.buck_deps(b)
        for p in problems: bad.append(p)
        if want!=have: bad.append('%s: BUCK deps %s != derived %s (missing %s, extra %s)'%(pkg,have,want,sorted(set(want)-set(have)),sorted(set(have)-set(want))))
    if a.core:
        c=open(os.path.join(a.core,'komira_core','native','komira_core_posix.c')).read()
        defined=set(re.findall(r'(?m)^[A-Za-z_].*?\b(komira_[a-z0-9_]+)\(',c)); own,_=D.load_symbols(a.symbols)
        if defined!=set(own): bad.append('c_symbols.tsv vs the shim: only in the shim %s, only in the table %s'%(sorted(defined-set(own)),sorted(set(own)-defined)))
    if bad: print('deps_derived RED:',*bad,sep='\n  '); return 1
    if n==0: print('deps_derived NOT CHECKED: no derived package exists in the tree yet, so no BUCK was compared (the C symbol table was%s)'%(' checked' if a.core else ' not checked')); return 0
    print('deps_derived GREEN',n,'packages'); return 0
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('cmd'); ap.add_argument('--core'); ap.add_argument('--map'); ap.add_argument('--pkg')
    ap.add_argument('--tree'); ap.add_argument('--record'); ap.add_argument('--expect'); ap.add_argument('--root'); ap.add_argument('--ffi-map'); ap.add_argument('--pkg-dir',default='komira_core'); ap.add_argument('--word',default='komira_core'); ap.add_argument('--exclude',action='append',default=[]); ap.add_argument('--base',default=''); ap.add_argument('--head',default='HEAD'); ap.add_argument('--repo',default='.'); ap.add_argument('--symbols',default=os.path.join(os.path.dirname(os.path.abspath(__file__)),'c_symbols.tsv'))
    a=ap.parse_args()
    if a.cmd=='digest':
        d,n=tree_digest(os.path.join(a.core,a.pkg_dir))
        if a.record: open(a.record,'w').write(d+'\n'); print('recorded',d,n,'files'); return 0
        want=open(a.expect).read().strip()
        if d==want: print('core_frozen GREEN',a.pkg_dir,n,'files'); return 0
        print('core_frozen RED: src/%s differs from the recorded freeze digest\n  want'%a.pkg_dir,want,'\n  have',d); return 1
    if a.cmd=='map':
        rows=S.load_map(a.map); listed=[r['file'] for r in rows]
        have=sorted(os.path.relpath(os.path.join(d,f),os.path.join(a.core,a.pkg_dir)) for d,_,fs in os.walk(os.path.join(a.core,a.pkg_dir)) for f in fs)
        dup={x for x in listed if listed.count(x)>1}; miss=sorted(set(have)-set(listed)); extra=sorted(set(listed)-set(have))
        bad=[r['file'] for r in rows if r['disposition'] in('dropped',) and False]
        if dup or miss or extra: print('map_total RED: duplicate rows',sorted(dup),'missing rows',miss,'rows with no file',extra); return 1
        print('map_total GREEN',len(rows),'rows =',len(have),'files'); return 0
    if a.cmd=='copy':
        rows=S.load_map(a.map); out,_=S.derive(a.core,rows,a.pkg,S.load_map(a.ffi_map) if a.ffi_map else None); bad=[]
        if not out: print('copy_exact RED for',a.pkg,': the maps give this package no file, so there is nothing to compare (a typo in the trailer?)'); return 1
        for p,t in out.items():
            fp=os.path.join(a.tree,p)
            if not os.path.exists(fp): bad.append(('missing',p))
            elif open(fp,errors='replace').read()!=t: bad.append(('differs',p))
        have={os.path.relpath(os.path.join(d,f),a.tree) for d,_,fs in os.walk(os.path.join(a.tree,'src',a.pkg)) for f in fs}
        extra=sorted(x for x in have if x not in out and not x.endswith(('BUCK','README.md','__init__.mojo')) and '/native/' not in x)
        if bad or extra: print('copy_exact RED for',a.pkg,bad[:5],'extra',extra[:5]); return 1
        print('copy_exact GREEN',a.pkg,len(out),'files'); return 0
    if a.cmd=='copy_range':
        return copy_range(a)
    if a.cmd=='deps':
        return deps_check(a)
    if a.cmd=='importers':
        pat=re.compile(r'(?<![A-Za-z0-9_])'+re.escape(a.word)+r'(?![A-Za-z0-9_])'); hits=[]
        for d,_,fs in os.walk(a.root):
            for f in fs:
                p=os.path.join(d,f)
                if any(os.path.relpath(p,a.root).startswith(x) for x in a.exclude): continue
                for i,l in enumerate(open(p,errors='replace')):
                    if pat.search(l): hits.append((p,i+1))
        print('no_core_importers' if a.word=='komira_core' else 'no_core_ffi_importers' if a.word=='komira_core_ffi' else 'no_%s_importers'%a.word, 'RED' if hits else 'GREEN', len(hits),'hits'); return 1 if hits else 0
sys.exit(main())
