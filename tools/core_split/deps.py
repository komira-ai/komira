"""What repoint.py reads to derive a package's BUCK deps from its own files: the first-party packages a module imports,
the owner (c_symbols.tsv) of every `external_call["komira_*"]` symbol it calls, and the third-party target of an
`external_call["snappy_*"]`. Comments and triple-quoted strings are masked first."""
import os,re
IMPORT=re.compile(r'^[ \t]*(?:from|import)[ \t]+(komira_[a-z0-9_]+)(?![A-Za-z0-9_])',re.M)
CALL=re.compile(r'external_call\[\s*"([A-Za-z0-9_]+)"')
# c_symbols.tsv names the package that owned a symbol when it was split; renames.tsv says which name it has now
RENAMED=dict(tuple(l.rstrip('\n').split('\t')) for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'renames.tsv')) if l.strip() and not l.startswith('#'))
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
        else: own[a]=RENAMED.get(b,b)
    return own,third
