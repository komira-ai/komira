#!/usr/bin/env python3
"""Self-test of `check.py deps` on package-local C libraries: seeded trees, each with the verdict the check must give.
  deps_selftest.py [--tool DIR]    # DIR holds the check.py and deps.py under test (default: this directory)
A package that owns C symbols (c_symbols.tsv) carries a hand-added `cxx_library` in its own BUCK, and its mojo_library
depends on it as `:name`. That edge cannot be derived from files, so the check accepts exactly: a `:name` that is a
cxx_library of the same BUCK, whose srcs are C files under native/ (direct, or staged by a staged_files of that BUCK),
and every komira_ symbol of which c_symbols.tsv gives to this package. Every other extra dep stays RED. Exit 1 if any
case gets the wrong verdict."""
import os,sys,subprocess,tempfile,argparse
SYMS='symbol\towner\nkomira_write_bytes\tkomira_libc\nkomira_fsync\tkomira_libc\nkomira_on_pool_depth\tkomira_concurrency\n'
C_OK='long long komira_write_bytes(int fd, const void *b, unsigned long n) { return 0; }\nint komira_fsync(int fd) { return 0; }\n'
C_FOREIGN=C_OK+'int komira_on_pool_depth(void) { return 0; }\n'
C_UNOWNED=C_OK+'int komira_unowned(void) { return 0; }\n'
MOJO='from komira_atomic_alias.x import Y\nfn f():\n    _ = external_call["komira_write_bytes", Int]()\n'
STAGED='staged_files(\n    name = "files",\n    srcs = ["native/p.c"],\n)\n\n'
def lib(srcs='[":files[native/p.c]"]',kind='cxx_library',name='komira_libc_c'):
    return '%s(\n    name = "%s",\n    srcs = %s,\n    visibility = ["PUBLIC"],\n)\n\n'%(kind,name,srcs)
def buck(deps,pre):
    return pre+'mojo_library(\n    name = "komira_libc",\n    srcs = glob(["**/*.mojo"]),\n    deps = [\n'+''.join('        "%s",\n'%d for d in deps)+'    ],\n    visibility = ["PUBLIC"],\n)\n'
OK=['//src/komira_atomic_alias:komira_atomic_alias']
# name, BUCK deps, BUCK text before the mojo_library, C file, mojo file, expected exit (0 green, 1 red); a RED case's report must
# also contain the text MUST gives it, so it cannot be red for another reason
CASES=[
 ('local cxx_library staged from native/ is accepted',[':komira_libc_c']+OK,STAGED+lib(),C_OK,MOJO,0),
 ('local cxx_library with a direct native/ src is accepted',[':komira_libc_c']+OK,lib('["native/p.c"]'),C_OK,MOJO,0),
 ('a comment mentioning an extra dep does not matter',[':komira_libc_c']+OK,'# deps = ["//src/komira_core:komira_core"]\n'+STAGED+lib(),C_OK,MOJO,0),
 ('RED: an extra //src dep next to the local library',[':komira_libc_c','//src/komira_json:komira_json']+OK,STAGED+lib(),C_OK,MOJO,1),
 ('RED: an extra //src dep, no local library at all',['//src/komira_json:komira_json']+OK,'',C_OK,'from komira_atomic_alias.x import Y\n',1),
 ('RED: a :local dep that is a filegroup, not a cxx_library',[':komira_libc_c']+OK,STAGED+lib(kind='filegroup'),C_OK,MOJO,1),
 ('RED: a :local dep naming no target of the BUCK',[':nothing']+OK,'',C_OK,'from komira_atomic_alias.x import Y\n',1),
 ('RED: a local cxx_library defining another package\'s symbol',[':komira_libc_c']+OK,STAGED+lib(),C_FOREIGN,MOJO,1),
 ('RED: a local cxx_library defining a symbol no row owns',[':komira_libc_c']+OK,STAGED+lib(),C_UNOWNED,MOJO,1),
 ('RED: a local cxx_library whose src is not under native/',[':komira_libc_c']+OK,lib('["p.c"]'),C_OK,MOJO,1),
 ('RED: a local cxx_library staging a file its staged_files does not name',[':komira_libc_c']+OK,'staged_files(\n    name = "files",\n    srcs = ["native/q.c"],\n)\n\n'+lib(),C_OK,MOJO,1),
 ('RED: the package calls its own symbol and no local library defines it',OK,'',C_OK,MOJO,1),
 ('RED: the local library is there but does not define the called symbol',[':komira_libc_c']+OK,STAGED+lib(),'int komira_fsync(int fd) { return 0; }\n',MOJO,1),
]
MUST={  # the text of the report, by the number of the case in CASES
 3:"extra ['//src/komira_json:komira_json']",4:"extra ['//src/komira_json:komira_json']",5:"extra [':komira_libc_c']",6:"extra [':nothing']",
 7:"komira_on_pool_depth",8:"komira_unowned",9:"not a C file under native/",10:"not staged by staged_files",
 11:"call its own C symbol komira_write_bytes",12:"call its own C symbol komira_write_bytes",
}
def run(tool,i,case):
    name,deps,pre,c,mojo,want=case
    with tempfile.TemporaryDirectory(prefix='deps_selftest.') as t:
        d=os.path.join(t,'src','komira_libc'); os.makedirs(os.path.join(d,'native'))
        os.makedirs(os.path.join(t,'src','komira_atomic_alias')); os.makedirs(os.path.join(t,'src','komira_json'))
        open(os.path.join(d,'BUCK'),'w').write(buck(deps,pre)); open(os.path.join(d,'native','p.c'),'w').write(c); open(os.path.join(d,'a.mojo'),'w').write(mojo)
        open(os.path.join(t,'syms.tsv'),'w').write(SYMS)
        r=subprocess.run([sys.executable,os.path.join(tool,'check.py'),'deps','--tree',t,'--pkg','komira_libc','--symbols',os.path.join(t,'syms.tsv')],capture_output=True,text=True)
    ok=r.returncode==want and (want==0 or MUST[i] in r.stdout+r.stderr)
    print('%s  %s'%('ok  ' if ok else 'FAIL',name))
    if not ok: print('      wanted exit %d%s, got %d: %s'%(want,' with '+repr(MUST[i]) if want else '',r.returncode,(r.stdout+r.stderr).strip().replace('\n','\n      ')))
    return ok
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--tool',default=os.path.dirname(os.path.abspath(__file__))); a=ap.parse_args()
    bad=[c[0] for i,c in enumerate(CASES) if not run(a.tool,i,c)]
    if bad: print('deps_selftest RED: %d of %d cases wrong'%(len(bad),len(CASES))); return 1
    print('deps_selftest GREEN: %d cases'%len(CASES)); return 0
sys.exit(main())
