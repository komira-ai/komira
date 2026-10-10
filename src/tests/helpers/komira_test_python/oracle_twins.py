"""Two python_oracle targets with the same script and inputs wrote the same tree.

    oracle_twins.py <directory> <directory>

Each directory is the output of its own action, so the comparison is between
two separate runs on the farm, not the two runs one action makes. Fails
unless both hold the same relative paths, each a file with the same bytes or
a directory, and at least one file.
"""

import os
import sys


def tree(root):
    out = {}
    for parent, dirs, files in os.walk(root):
        for name in dirs:
            out[os.path.relpath(os.path.join(parent, name), root)] = None
        for name in files:
            with open(os.path.join(parent, name), "rb") as f:
                out[os.path.relpath(os.path.join(parent, name), root)] = f.read()
    return out


a, b = tree(sys.argv[1]), tree(sys.argv[2])
assert sorted(a) == sorted(b), "paths differ: {} vs {}".format(sorted(a), sorted(b))
for rel in sorted(a):
    assert a[rel] == b[rel], "{} differs: {!r} vs {!r}".format(rel, a[rel], b[rel])
files = [rel for rel in a if a[rel] is not None]
assert files, "the oracle wrote no file"
print("identical:", ", ".join(sorted(files)))
