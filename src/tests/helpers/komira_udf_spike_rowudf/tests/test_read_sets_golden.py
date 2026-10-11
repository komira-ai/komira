"""The committed read sets (golden/read_sets.tsv), which the Mojo tests read
as their UDF references, against the producer's capture run now
(producer/capture_main.table()).

What it proves: the file the runtime tests take their read sets from is
exactly what the capture computes, byte for byte. The defect it catches: a
change to the capture (komira_udf_readset.py) or to a row function
(pyrt/udf_rows.py) that alters a read set, a source, a recording or a note
while the Mojo tests keep running on the old table. Mutant planted: scan()
dropping the subscript arm (`row["qty"]` no longer a field read): red here,
price_qty_keys came out every_column.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PKG, "producer"))

import capture_main  # noqa: E402

with open(os.path.join(PKG, "golden", "read_sets.tsv")) as f:
    golden = f.read()
now = capture_main.table()
if now != golden:
    g = golden.splitlines()
    n = now.splitlines()
    diff = [(a, b) for a, b in zip(g, n) if a != b]
    raise AssertionError(
        "golden/read_sets.tsv differs from the capture ({} vs {} lines); first differing pair: {!r}".format(
            len(g), len(n), diff[:1]
        )
    )
assert len(golden.splitlines()) == 9, golden
print("test_read_sets_golden: ok")
