#!/usr/bin/env python3
"""Write BUCK, __init__.mojo and README.md of the derived packages (split.py writes the modules and tests).
  gen_build.py --map split_map.tsv [--ffi-map libc_rename_map.tsv] --out DIR [--pkg NAME] [--repo DIR]
Deps come from deps.py over the files under --out (split.py's output), never from src/komira_core/BUCK.
Not generated, added by hand in the commit that makes the package: the cxx_library of a C-symbol owner
(komira_libc, komira_concurrency, komira_scan_source) and the arrow_ipc extras (large_writes_check, the
arrow_types.mojo data of the census test).
Added by hand later, not from komira_core: komira_collections' hyperloglog.mojo and its test
tests/test_hyperloglog.mojo; komira_plan_stats' cardinality_estimator.mojo, its test
tests/test_cardinality_estimator.mojo and its komira_arrow and komira_collections deps. A re-run drops those
tests from the BUCK test_srcs and check.py copy reports the modules as extras; put them back."""
import os,re,sys,argparse
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
import split as S, deps as D
HERE=os.path.dirname(os.path.abspath(__file__))
def descriptions():
    return {l.split('\t')[0]:l.rstrip('\n').split('\t')[1] for l in open(os.path.join(HERE,'packages.tsv')) if l.strip() and not l.startswith('#') and not l.startswith('package\t')}
def render(tree,pkg,rows,known,desc):
    deps,problems=D.derive_deps(tree,pkg,known,os.path.join(HERE,'c_symbols.tsv'))
    tests=sorted(os.path.relpath(r['new_path'],'src/'+pkg) for r in rows if r['dest']==pkg and r['kind']=='test' and r['disposition'] in('copy','moves-with-consumer'))
    data={}
    for t in tests:
        txt=open(os.path.join(tree,'src',pkg,t),errors='replace').read()
        for m in re.finditer(r'src/%s/(tests/fixtures/[A-Za-z0-9_./-]+?\.(?:arrow|tensor))'%pkg,txt):
            if os.path.exists(os.path.join(tree,'src',pkg,m.group(1))) and m.group(1) not in data.setdefault(t,[]): data[t].append(m.group(1))
    o='load("@komira//tools/build/mojo:defs.bzl", "mojo_library")\n\n# %s\nmojo_library(\n    name = "%s",\n    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),\n'%(desc,pkg)
    if deps: o+='    deps = [\n'+''.join('        "%s",\n'%d for d in deps)+'    ],\n'
    if tests: o+='    test_srcs = [\n'+''.join('        "%s",\n'%t for t in tests)+'    ],\n'
    if data:
        o+='    test_data = {\n'+''.join('        "%s": [\n'%t+''.join('            "%s",\n'%f for f in sorted(fs))+'        ],\n' for t,fs in sorted(data.items()))+'    },\n'
    return o+'    visibility = ["PUBLIC"],\n)\n',problems
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--map',required=True); ap.add_argument('--out',required=True); ap.add_argument('--pkg'); ap.add_argument('--ffi-map'); ap.add_argument('--repo',default=os.path.join(HERE,'..','..'),help='the repository whose src/ holds the packages that already exist')
    a=ap.parse_args(); rows=S.load_map(a.map)+(S.load_map(a.ffi_map) if a.ffi_map else []); desc=descriptions(); known=D.first_party(a.out,rows)|D.first_party(a.repo)|set(desc)
    bad=0
    for pkg in sorted(desc):
        if a.pkg and pkg!=a.pkg: continue
        if not os.path.isdir(os.path.join(a.out,'src',pkg)): continue
        b,pr=render(a.out,pkg,rows,known,desc[pkg]); bad+=len(pr)
        for p in pr: print('PROBLEM',p)
        d=os.path.join(a.out,'src',pkg)
        open(os.path.join(d,'BUCK'),'w').write(b)
        open(os.path.join(d,'README.md'),'w').write('# %s\n\n%s\n'%(pkg,desc[pkg]))
        init=os.path.join(d,'__init__.mojo')
        if not os.path.exists(init): open(init,'w').write('"""%s"""\n'%desc[pkg])
        print('wrote BUCK, README.md, __init__.mojo of',pkg)
    return 1 if bad else 0
sys.exit(main())
