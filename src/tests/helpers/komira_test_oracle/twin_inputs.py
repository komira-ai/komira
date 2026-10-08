"""The inputs of the HAND cases that have an ORACLE twin, as pyarrow tables.

A HAND case of komira_plan_conformance scans a hand-written JSON Lines file
(`datasets/<name>.jsonl` there, its schema in `datasets.mojo`). Its ORACLE
twin must run on the same rows, and the oracle reads tables built in Python,
never a file read back, so each input is written out again here, row by
row, with the schema `datasets.mojo` declares (names, types, nullability).
`test_expected.py` holds each table to a copy of the JSON Lines file
(`twins/inputs/<name>.jsonl`, the same bytes as the corpus's file), so this
module cannot drift from the input the HAND case derives its answer from.
"""

import pyarrow as pa


def _table(fields, rows):
    schema = pa.schema([pa.field(n, t, nullable=nl) for n, t, nl in fields])
    cols = [[r[i] for r in rows] for i in range(len(fields))]
    return pa.table([pa.array(c, f.type) for c, f in zip(cols, schema)], schema=schema)


_I64 = pa.int64()
_BOOL = pa.bool_()
_F64 = pa.float64()

TABLES = {
    # Every pair of TRUE, FALSE, NULL.
    "bool_pairs": (
        [("id", _I64, False), ("a", _BOOL, True), ("b", _BOOL, True)],
        [
            (1, True, True),
            (2, True, False),
            (3, True, None),
            (4, False, True),
            (5, False, False),
            (6, False, None),
            (7, None, True),
            (8, None, False),
            (9, None, None),
        ],
    ),
    "ints_nullable": (
        [("id", _I64, False), ("x", _I64, True)],
        [(1, 1), (2, 2), (3, None), (4, 5)],
    ),
    # k groups 1, NULL and 2; the NULL group holds three rows, k = 2 only
    # NULL values.
    "groups": (
        [("id", _I64, False), ("k", _I64, True), ("v", _I64, True)],
        [
            (1, 1, 10),
            (2, 1, None),
            (3, None, 5),
            (4, None, 7),
            (5, 2, None),
            (6, 2, None),
            (7, None, None),
        ],
    ),
    # a with ties and two NULLs; f holds 0.0 twice and -0.0 once.
    "sort_rows": (
        [("id", _I64, False), ("a", _I64, True), ("b", _I64, True), ("f", _F64, True)],
        [
            (1, 3, 1, 1.5),
            (2, None, 2, 0.0),
            (3, 1, 2, -0.0),
            (4, 3, None, -2.5),
            (5, None, 1, None),
            (6, 2, 1, 0.0),
            (7, 3, 1, 0.5),
        ],
    ),
}

NAMES = sorted(TABLES)


def build(name):
    fields, rows = TABLES[name]
    return _table(fields, rows)
