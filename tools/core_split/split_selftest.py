#!/usr/bin/env python3
"""Self-test of split.py's import rewriting: a seeded komira_core, each statement with the line split.py must write.
  split_selftest.py [--tool DIR]    # DIR holds the split.py under test (default: this directory)
Mojo reads `from .. arrow.column import X` (a space after the dots) as `from ..arrow.column import X`, and two files of
the frozen src/komira_core use that spelling. A rewriter that does not see it leaves the relative import in place,
which the compiler rejects in the new package ("attempted relative import with no known parent package"); it is not
counted as unresolved either, so nothing reports it before a build. Exit 1 if any statement is rewritten wrongly."""
import os,sys,tempfile,argparse
MAP='file\tkind\tlines\tdisposition\tdest\tnew_path\tnote\n'+''.join(
    '%s\tsrc\t1\tcopy\t%s\tsrc/%s/%s\t-\n'%(f,p,p,os.path.basename(f)) for f,p in
    [('arrow/column.mojo','pkg_arrow'),('io/heap.mojo','pkg_buffer'),('eval/kern.mojo','pkg_kern'),('eval/other.mojo','pkg_kern')])
# statement in eval/kern.mojo, the line split.py must write for it
CASES=[
 ('from ..arrow.column import Column','from pkg_arrow.column import Column'),
 ('from .. arrow.column import Column','from pkg_arrow.column import Column'),
 ('from ..\tarrow.column import (\n    Column,\n)','from pkg_arrow.column import (\n    Column,\n)'),
 ('from .. io.heap import Heap','from pkg_buffer.heap import Heap'),
 ('from .other import f','from pkg_kern.other import f'),
 ('from . other import f','from pkg_kern.other import f'),
 ('from komira_core.arrow.column import Column','from pkg_arrow.column import Column'),
 ('from std.memory import memcpy','from std.memory import memcpy'),
]
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--tool',default=os.path.dirname(os.path.abspath(__file__))); a=ap.parse_args()
    sys.path.insert(0,a.tool); import split as S
    bad=0
    for stmt,want in CASES:
        root=tempfile.mkdtemp(prefix='split_selftest.'); core=os.path.join(root,'komira_core')
        for f,t in [('arrow/column.mojo','struct Column:\n    pass\n'),('io/heap.mojo','struct Heap:\n    pass\n'),
                    ('eval/kern.mojo',stmt+'\n'),('eval/other.mojo','fn f():\n    pass\n')]:
            os.makedirs(os.path.dirname(os.path.join(core,f)),exist_ok=True); open(os.path.join(core,f),'w').write(t)
        mp=os.path.join(root,'map.tsv'); open(mp,'w').write(MAP)
        out,unres=S.derive(root,S.load_map(mp),'pkg_kern')
        have=out['src/pkg_kern/kern.mojo'].rstrip('\n')
        ok=have==want and not unres
        print('%s  %r -> %r%s'%('ok  ' if ok else 'FAIL',stmt,have,'' if ok else ' (want %r, unresolved %s)'%(want,dict(unres))))
        bad+=not ok
    if bad: print('split_selftest RED:',bad,'of',len(CASES),'statements rewritten wrongly'); return 1
    print('split_selftest GREEN:',len(CASES),'statements'); return 0
sys.exit(main())
