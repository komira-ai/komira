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
RENAMED=dict(tuple(l.rstrip('\n').split('\t')) for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'renames.tsv')) if l.strip() and not l.startswith('#'))
def load_symbols(path):
    """-> ({symbol: owner package}, [(prefix, third-party label)])."""
    own={}; third=[]
    for l in open(path):
        if l.startswith('#') or not l.strip(): continue
        a,b=l.rstrip('\n').split('\t')
        if a=='symbol': continue
        if a.endswith('*'): third.append((a[:-1],b))
        else: own[a]=RENAMED.get(b,b)
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
DEFINED=re.compile(r'(?m)^[A-Za-z_].*?\b(komira_[a-z0-9_]+)\(')
def c_defined(text):
    """The komira_ functions a C file defines (one per line starting at column 0, as the shim is written)."""
    return set(DEFINED.findall(re.sub(r'/\*.*?\*/','',text,flags=re.S)))
def _calls(t,kind):
    """-> {name: body} of the top-level `kind(` ... `)` calls of a BUCK text whose closing paren is at column 0."""
    return {(re.search(r'\bname = "([^"]+)"',m.group(1)) or [0,''])[1]:m.group(1) for m in re.finditer(r'(?ms)^%s\(\n(.*?)^\)'%kind,t)}
def _srcs(body):
    m=re.search(r'\bsrcs = \[(.*?)\](?=\s*,|\s*\n)',body,re.S)
    return re.findall(r'"([^"]+)"',m.group(1)) if m else []
def local_c_libraries(tree,pkg):
    """-> ({name: sorted komira_ symbols its C files define}, {name: [why it is not a local C library]}) for the
    `cxx_library` targets of src/<pkg>/BUCK. A cxx_library is a package-local C library only if every one of its srcs is
    a C file under native/ of the package, given directly or as `:<staged_files target>[native/x.c]` of the same BUCK
    whose srcs name that file."""
    b=os.path.join(tree,'src',pkg,'BUCK')
    if not os.path.exists(b): return {},{}
    t=re.sub(r'#[^\n]*','',open(b).read()); staged=_calls(t,'staged_files'); libs={}; bad={}
    for name,body in _calls(t,'cxx_library').items():
        files=[]; why=[]
        for s in _srcs(body):
            m=re.fullmatch(r':([A-Za-z0-9_]+)\[(.+)\]',s); f=m.group(2) if m else s
            if m and f not in _srcs(staged.get(m.group(1),'')): why.append('%s is not staged by staged_files %s'%(s,m.group(1)))
            elif not (f.startswith('native/') and f.endswith('.c') and '..' not in f): why.append('%s is not a C file under native/'%s)
            elif not os.path.exists(os.path.join(tree,'src',pkg,f)): why.append('%s does not exist'%f)
            else: files.append(f)
        if why or not files: bad[name]=why or ['it has no srcs']
        else: libs[name]=sorted(set().union(*[c_defined(open(os.path.join(tree,'src',pkg,f),errors='replace').read()) for f in files]))
    return libs,bad
def local_dep_problems(have,libs,bad,pkg,own,needed):
    """Split the BUCK deps into the derivable ones and the accepted package-local C libraries.
    -> (deps without the accepted local C libraries, problems). Accepted: `:name` naming a cxx_library of the same BUCK
    (local_c_libraries) every symbol of which c_symbols.tsv gives to this package. Anything else stays in the list and
    is compared with the derived deps, so it is an extra dep. `needed` are the symbols the package's own files call and
    own: some accepted library must define each, so the library cannot be dropped."""
    rest=[]; problems=[]; defined=set()
    for d in have:
        n=d[1:]
        if d.startswith(':') and n in bad: problems.append('%s: dep %s is a cxx_library that is not a package-local C library: %s'%(pkg,d,'; '.join(bad[n])))
        elif d.startswith(':') and n in libs:
            syms=libs[n]; foreign=[s for s in syms if own.get(s)!=pkg]
            if not syms: problems.append('%s: local C library %s defines no komira_ symbol'%(pkg,d))
            elif foreign: problems.append('%s: local C library %s defines %s, which c_symbols.tsv does not give to %s'%(pkg,d,foreign,pkg))
            else: defined|=set(syms); continue
        rest.append(d)
    for s in sorted(needed-defined): problems.append('%s: its files call its own C symbol %s but no local cxx_library that its mojo_library depends on defines it'%(pkg,s))
    return rest,problems
def own_symbols_called(tree,pkg,symbols_tsv):
    own,_=load_symbols(symbols_tsv); used=set()
    for d,_,fs in os.walk(os.path.join(tree,'src',pkg)):
        for f in fs:
            if f.endswith('.mojo'): used|={s for s in CALL.findall(mask(open(os.path.join(d,f),errors='replace').read())) if own.get(s)==pkg}
    return used
def buck_deps(path):
    """The `deps = [...]` labels of a BUCK file's mojo_library (comments dropped)."""
    t=re.sub(r'#[^\n]*','',open(path).read())
    m=re.search(r'\n    deps = \[(.*?)\]',t,re.S)
    return sorted(re.findall(r'"([^"]+)"',m.group(1))) if m else []
