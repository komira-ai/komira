#!/usr/bin/env python3
"""Self-test of repoint.py over a seeded tree: each case is a file the tool must rewrite to exactly the text given,
a second run must change nothing, and a file that is already repointed must not be touched. Exit 1 on any miss.
  repoint_selftest.py [--tool DIR]"""
import os,sys,subprocess,tempfile,argparse,shutil
CORE={
 'arrow/__init__.mojo':'from .column import Column\nfrom .schema import Schema\n',
 'arrow/column.mojo':'struct Column:\n    pass\n',
 'arrow/schema.mojo':'struct Schema:\n    pass\n',
 'collections/__init__.mojo':'from .slab import Slab\n',
 'collections/slab.mojo':'struct Slab:\n    pass\n',
 'cancellation/token.mojo':'struct CancellationToken:\n    pass\n',
}
MAP='file\tkind\tlines\tdisposition\tdest\tnew_path\tnote\n'+''.join(
 '%s\t%s\t1\t%s\t%s\t%s\t-\n'%r for r in [
 ('arrow/__init__.mojo','src','facade','-','-'),
 ('arrow/column.mojo','src','copy','komira_parrow','src/komira_parrow/column.mojo'),
 ('arrow/schema.mojo','src','copy','komira_parrow','src/komira_parrow/schema.mojo'),
 ('collections/__init__.mojo','src','facade','-','-'),
 ('collections/slab.mojo','src','copy','komira_pcoll','src/komira_pcoll/slab.mojo'),
 ('cancellation/token.mojo','src','copy','komira_concurrency','src/komira_concurrency/token.mojo'),
 ('parsers/numeric.mojo','src','moves-with-consumer','imp','src/imp/numeric.mojo'),
 ('tests/test_numeric.mojo','test','moves-with-consumer','imp','src/imp/tests/test_numeric.mojo')])
CORE['parsers/numeric.mojo']='from komira_core.collections.slab import Slab\nfn num(s: Slab): pass\n'
CORE['tests/test_numeric.mojo']='from imp.numeric import num\n'
BUCK_BEFORE='''mojo_library(
    name = "imp",
    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),
    deps = [
        "//src/aaa:aaa",
        "//src/komira_core:komira_core",
        "//src/zzz:zzz",
    ],
    test_srcs = [
        "tests/test_b.mojo",
    ],
)
'''
BUCK_AFTER='''mojo_library(
    name = "imp",
    srcs = glob(["**/*.mojo"], exclude = ["tests/**/*.mojo"]),
    deps = [
        "//src/aaa:aaa",
        "//src/komira_concurrency:komira_concurrency",
        "//src/komira_parrow:komira_parrow",
        "//src/komira_pcoll:komira_pcoll",
        "//src/zzz:zzz",
    ],
    test_srcs = [
        "tests/test_b.mojo",
        "tests/test_numeric.mojo",
    ],
)
'''
FILES={
 'src/imp/a.mojo':('from komira_core.arrow import Column, Schema as S\nfrom komira_core.collections.slab import Slab\nfrom .local import x\nfrom komira_core.cancellation.token import CancellationToken\n# see komira_core.arrow.column and src/komira_core/collections/slab.mojo\n',
   'from komira_parrow.column import Column\nfrom komira_parrow.schema import Schema as S\nfrom komira_pcoll.slab import Slab\nfrom .local import x\nfrom komira_concurrency.token import CancellationToken\n# see komira_parrow.column and src/komira_pcoll/slab.mojo\n'),
 'src/imp/tests/test_b.mojo':('from komira_core.arrow.column import Column\n','from komira_parrow.column import Column\n'),
 'src/imp/BUCK':(BUCK_BEFORE,BUCK_AFTER),
 'src/imp/README.md':('Built on `komira_core.arrow.schema`.\n','Built on `komira_parrow.schema`.\n'),
 'src/inl/BUCK':('mojo_library(\n    name = "inl",\n    deps = ["//src/komira_core:komira_core"],\n)\n','mojo_library(\n    name = "inl",\n    deps = ["//src/komira_pcoll:komira_pcoll"],\n)\n'),
 'src/inl/x.mojo':('from komira_core.collections import Slab\n','from komira_pcoll.slab import Slab\n'),
 'src/done/x.mojo':('from komira_parrow.column import Column\n','from komira_parrow.column import Column\n'),
 'src/ffi/BUCK':('mojo_library(\n    name = "ffi",\n    deps = ["//src/komira_core_ffi:komira_core_ffi"],\n)\n','mojo_library(\n    name = "ffi",\n    deps = ["//src/komira_libc:komira_libc"],\n)\n'),
 'src/ffi/x.mojo':('from komira_core_ffi.posix import _read_env\n','from komira_libc.posix import _read_env\n'),
}
NEWDIRS=['src/komira_parrow','src/komira_pcoll','src/komira_libc','src/komira_concurrency']
def sh(*a,cwd=None): return subprocess.run(list(a),cwd=cwd,capture_output=True,text=True)
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--tool',default=os.path.dirname(os.path.abspath(__file__))); a=ap.parse_args()
    root=tempfile.mkdtemp(prefix='repoint_selftest.'); tree=os.path.join(root,'tree'); core=os.path.join(root,'core','komira_core')
    for f,t in CORE.items():
        os.makedirs(os.path.dirname(os.path.join(core,f)),exist_ok=True); open(os.path.join(core,f),'w').write(t)
    mp=os.path.join(root,'map.tsv'); open(mp,'w').write(MAP)
    for f,(b,_) in FILES.items():
        os.makedirs(os.path.dirname(os.path.join(tree,f)),exist_ok=True); open(os.path.join(tree,f),'w').write(b)
    for d in NEWDIRS: os.makedirs(os.path.join(tree,d),exist_ok=True); open(os.path.join(tree,d,'x.mojo'),'w').write('')
    for d,x in (('aaa',''),('zzz','')): os.makedirs(os.path.join(tree,'src',d),exist_ok=True); open(os.path.join(tree,'src',d,'x.mojo'),'w').write(x)
    sh('git','init','-q',cwd=tree); sh('git','add','.',cwd=tree)
    cmd=[sys.executable,os.path.join(a.tool,'repoint.py'),'--tree',tree,'--core-root',os.path.join(root,'core'),'--map',mp]
    bad=0
    def check(name,ok,why=''):
        nonlocal bad
        print('%s  %s%s'%('ok  ' if ok else 'FAIL',name,'' if ok else '  '+why)); bad+=not ok
    r=sh(*cmd,'--strict'); check('first run exits 0 under --strict',r.returncode==0,r.stdout+r.stderr)
    for f,(_,want) in FILES.items():
        have=open(os.path.join(tree,f)).read(); check('rewrite '+f,have==want,'\n--- have\n%s--- want\n%s'%(have,want))
    for f,want in (('src/imp/numeric.mojo','from komira_pcoll.slab import Slab\nfn num(s: Slab): pass\n'),('src/imp/tests/test_numeric.mojo','from imp.numeric import num\n')):
        p=os.path.join(tree,f); check('moves-with-consumer created '+f,os.path.exists(p) and open(p).read()==want,'missing or different')
    sh('git','add','.',cwd=tree); before=sh('git','diff','--stat',cwd=tree).stdout
    snap={f:open(os.path.join(tree,f)).read() for f in FILES}
    r=sh(*cmd,'--strict'); same=all(open(os.path.join(tree,f)).read()==snap[f] for f in FILES)
    check('second run changes nothing',r.returncode==0 and same and 'rewrote 0 files' in r.stdout,r.stdout)
    # a stale import that the map cannot resolve must make --strict red
    open(os.path.join(tree,'src/imp/bad.mojo'),'w').write('from komira_core.nowhere import Gone\n'); sh('git','add','.',cwd=tree)
    r=sh(*cmd,'--strict'); check('an import the map does not resolve is red under --strict',r.returncode==1,r.stdout)
    # --dry-run writes nothing
    open(os.path.join(tree,'src/imp/dry.mojo'),'w').write('from komira_core.collections.slab import Slab\n'); sh('git','add','.',cwd=tree)
    r=sh(*cmd,'--dry-run'); check('--dry-run writes nothing',open(os.path.join(tree,'src/imp/dry.mojo')).read().startswith('from komira_core'),r.stdout)
    # --renames: directory, import, label, and a second run is a no-op
    shutil.rmtree(os.path.join(tree,'src/imp/bad.mojo'),ignore_errors=True); os.remove(os.path.join(tree,'src/imp/bad.mojo')); os.remove(os.path.join(tree,'src/imp/dry.mojo'))
    os.makedirs(os.path.join(tree,'src/komira_scalar_arith')); open(os.path.join(tree,'src/komira_scalar_arith/BUCK'),'w').write('mojo_library(name = "komira_scalar_arith")\n')
    open(os.path.join(tree,'src/imp/r.mojo'),'w').write('from komira_scalar_arith.dec import D\n'); open(os.path.join(tree,'src/imp/BUCK'),'a').write('# deps //src/komira_scalar_arith:komira_scalar_arith\n')
    sh('git','add','.',cwd=tree)
    r=sh(*cmd,'--renames'); ok=os.path.isdir(os.path.join(tree,'src/komira_scalar_arithmetic')) and not os.path.isdir(os.path.join(tree,'src/komira_scalar_arith')) and open(os.path.join(tree,'src/imp/r.mojo')).read()=='from komira_scalar_arithmetic.dec import D\n'
    check('--renames moves the directory and the import',ok,r.stdout+r.stderr)
    r=sh(*cmd,'--renames'); check('--renames is idempotent',r.returncode==0 and 'rewrote 0 files' in r.stdout,r.stdout)
    # --check: red while a file names komira_core, green when none does
    open(os.path.join(tree,'src/imp/leftover.mojo'),'w').write('# lives in komira_core\n'); sh('git','add','.',cwd=tree)
    r=sh(sys.executable,os.path.join(a.tool,'repoint.py'),'--tree',tree,'--check'); check('--check is red for a file that names komira_core',r.returncode==1 and 'leftover.mojo' in r.stdout,r.stdout)
    os.remove(os.path.join(tree,'src/imp/leftover.mojo')); sh('git','rm','-q','-f','--cached','src/imp/leftover.mojo',cwd=tree)
    r=sh(sys.executable,os.path.join(a.tool,'repoint.py'),'--tree',tree,'--check'); check('--check is green when none does',r.returncode==0,r.stdout)
    # after src/komira_core is deleted the tool reads it from the parent of the commit that deleted it
    h=os.path.join(root,'hist'); os.makedirs(h); env=dict(os.environ,GIT_AUTHOR_NAME='t',GIT_AUTHOR_EMAIL='t@t',GIT_COMMITTER_NAME='t',GIT_COMMITTER_EMAIL='t@t')
    for f,t in CORE.items():
        os.makedirs(os.path.dirname(os.path.join(h,'src/komira_core',f)),exist_ok=True); open(os.path.join(h,'src/komira_core',f),'w').write(t)
    open(os.path.join(h,'src/komira_core/BUCK'),'w').write('x\n')
    for d in ('komira_parrow','komira_pcoll'): os.makedirs(os.path.join(h,'src',d),exist_ok=True); open(os.path.join(h,'src',d,'x.mojo'),'w').write('')
    def g(*c): return subprocess.run(['git']+list(c),cwd=h,capture_output=True,text=True,env=env)
    g('init','-q'); g('add','.'); g('commit','-q','-m','with core'); g('rm','-r','-q','src/komira_core'); g('commit','-q','-m','delete core')
    os.makedirs(os.path.join(h,'src/late'),exist_ok=True); open(os.path.join(h,'src/late/a.mojo'),'w').write('from komira_core.arrow import Column\n'); g('add','.'); g('commit','-q','-m','late importer')
    r=subprocess.run([sys.executable,os.path.join(a.tool,'repoint.py'),'--tree',h,'--map',mp,'--strict'],capture_output=True,text=True)
    check('after the delete the tool reads komira_core from history',r.returncode==0 and open(os.path.join(h,'src/late/a.mojo')).read()=='from komira_parrow.column import Column\n',r.stdout+r.stderr)
    shutil.rmtree(root,ignore_errors=True)
    if bad: print('repoint_selftest RED:',bad,'checks failed'); return 1
    print('repoint_selftest GREEN'); return 0
sys.exit(main())
