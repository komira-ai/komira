"""Derive a package's deps from the package's own files, never from :komira_core's BUCK.
A dep is added for (a) every first-party package a module or test of it imports (`from komira_x.y import ..`,
`import komira_x`), (b) the owner (c_symbols.tsv) of every `external_call["komira_*"]` symbol it uses, and
(c) the third-party target of an `external_call["snappy_*"]`. Comments and triple-quoted strings are masked first.
Used by gen_build.py (writes the BUCK) and check.py deps (compares it with the BUCK on disk)."""
import os,re
IMPORT=re.compile(r'^[ \t]*(?:from|import)[ \t]+(komira_[a-z0-9_]+)(?![A-Za-z0-9_])',re.M)
CALL=re.compile(r'external_call\[\s*"([A-Za-z0-9_]+)"')
def mask(t):
    t=re.sub(r'"""(.*?)"""',lambda m:re.sub(r'[^\n]',' ',m.group(0)),t,flags=re.S)
    return re.sub(r'#[^\n]*','',t)
def load_symbols(path):
    """-> ({symbol: owner package}, [(prefix, third-party label)])."""
    own={}; third=[]
    for l in open(path):
        if l.startswith('#') or not l.strip(): continue
        a,b=l.rstrip('\n').split('\t')
        if a=='symbol': continue
        if a.endswith('*'): third.append((a[:-1],b))
        else: own[a]=b
    return own,third
def first_party(tree,*maps):
    src=os.path.join(tree,'src')
    k={d for d in os.listdir(src) if d.startswith('komira_')} if os.path.isdir(src) else set()
    for rows in maps:
        for r in rows or []:
            if r.get('dest','-').startswith('komira_'): k.add(r['dest'])
    return k
def derive_deps(tree,pkg,known,symbols_tsv):
    """-> (sorted dep labels, sorted problems). problems: an import of komira_core / komira_core_ffi, an import of an
    unknown komira_ package, a komira_ C symbol that c_symbols.tsv does not own."""
    own,third=load_symbols(symbols_tsv); deps=set(); problems=[]
    root=os.path.join(tree,'src',pkg)
    for d,_,fs in os.walk(root):
        for f in fs:
            if not f.endswith('.mojo'): continue
            t=mask(open(os.path.join(d,f),errors='replace').read()); rel=os.path.relpath(os.path.join(d,f),tree)
            for x in IMPORT.findall(t):
                if x==pkg: continue
                if x in ('komira_core','komira_core_ffi'): problems.append('%s imports %s'%(rel,x))
                elif x in known: deps.add('//src/%s:%s'%(x,x))
                else: problems.append('%s imports %s, which is no package of this tree or map'%(rel,x))
            for s in CALL.findall(t):
                if s.startswith('komira_'):
                    o=own.get(s)
                    if o is None: problems.append('%s calls the C symbol %s that c_symbols.tsv does not own'%(rel,s))
                    elif o!=pkg: deps.add('//src/%s:%s'%(o,o))
                else:
                    for pre,lab in third:
                        if s.startswith(pre): deps.add(lab)
    return sorted(deps),sorted(set(problems))
def buck_deps(path):
    """The `deps = [...]` labels of a BUCK file's mojo_library (comments dropped)."""
    t=re.sub(r'#[^\n]*','',open(path).read())
    m=re.search(r'\n    deps = \[(.*?)\]',t,re.S)
    return sorted(re.findall(r'"([^"]+)"',m.group(1))) if m else []
