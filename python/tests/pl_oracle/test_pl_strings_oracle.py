"""komira.pl's `str.strip_chars`, `strip_chars_start`, `strip_chars_end`,
`replace` and `replace_all` against polars itself, on the real libkomira.

Each program is written once for both modules and runs through komira.pl
(the plan door, `komira_plan_stream`) and through the pinned polars over one
Parquet file pyarrow writes here; the two answers must be the same frame,
values and dtypes (`polars.testing.assert_frame_equal`, rows as a multiset),
and the schema komira.pl derives must be the answer's.

The file's `t` holds spaces, a tab, a newline, a vertical tab, a form feed, a
carriage return, a non-breaking space, an ideographic space, U+001C and U+001F
(whitespace to Python, not to Unicode, so polars keeps them), a zero-width
space (whitespace to neither), a string of whitespace only, an empty string,
a NULL, the set `xy` at both ends and inside, and two-byte characters beside
characters that share their first byte; `r` holds text for the patterns: digits,
dots, dollars, backslashes, repeated matches and no match. Covered:

- `strip_chars()` and each side with no argument, of `"xy"`, of `" "`, of a
  two-byte character, of `""` (nothing removed); an all-whitespace string
  becomes ''; NULL stays NULL; the inside of a string is kept;
- `replace` changes the first match only and `replace_all` every match, of a
  regular expression, with groups referred to as `$1` and `${2}`, `$0`, `$$` and
  a group the pattern does not have; a backslash in the value is itself;
- `literal=True` reads neither the pattern (`.` and `$` are themselves) nor the
  value (`$1` is itself), for the first match and for every match;
- a pattern that matches no row leaves every row as it is.

The test is of the `pl_oracle/` family (python/tests/BUCK): CPython 3.13 alone,
on the real libkomira, with the pinned polars.

    test_pl_strings_oracle.py --lib-dir <dir> --runtime-dir <dir>
"""

import argparse
import os
import sys
import tempfile

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq
from polars.testing import assert_frame_equal

import komira.pl as kpl
from komira import Session
from komira import _native

assert pl.__version__ == "1.44.2", pl.__version__

T = [
    "  pad  ",
    "\thi\n",
    "\v\f\rcr\r",
    "\xa0nbsp\xa0",
    "　ideo　",
    "\x1cfs\x1f",
    "​zw​",
    " \t\n\xa0　 ",
    "",
    None,
    "xyxhixy",
    "yx in xy side xy",
    "a b",
    "éhié",
    "èé",
    "é è",
]
R = [
    "a1b22c333",
    "a.b.c",
    "cost $5 or $6",
    "back\\slash",
    "aaaa",
    "none here",
    None,
    "",
    "ab ab ab",
    "été",
    "x",
    "a1",
    "zz",
    "1a2b",
    "..",
    "$",
]
assert len(T) == len(R)

STRIPS = []
for _verb in ("strip_chars", "strip_chars_start", "strip_chars_end"):
    STRIPS.append(
        (
            _verb,
            lambda P, lf, _verb=_verb: lf.select(
                "id",
                getattr(P.col("t").str, _verb)().alias("ws"),
                getattr(P.col("t").str, _verb)(None).alias("none"),
                getattr(P.col("t").str, _verb)("xy").alias("xy"),
                getattr(P.col("t").str, _verb)(" ").alias("space"),
                getattr(P.col("t").str, _verb)("é").alias("e_acute"),
                getattr(P.col("t").str, _verb)("").alias("nothing"),
            ),
        )
    )

REPLACES = [
    (
        "replace_first_and_every_match_of_a_pattern",
        lambda P, lf: lf.select(
            "id",
            P.col("r").str.replace("[0-9]+", "#").alias("first"),
            P.col("r").str.replace_all("[0-9]+", "#").alias("every"),
            P.col("r").str.replace("a", "A", n=1).alias("first_a"),
            P.col("r").str.replace_all("a", "A").alias("every_a"),
            P.col("r").str.replace("q+", "Q").alias("no_match"),
            P.col("r").str.replace_all("q+", "Q").alias("no_match_all"),
        ),
    ),
    (
        "replace_with_groups",
        lambda P, lf: lf.select(
            "id",
            P.col("r").str.replace("([a-z])([0-9])", "$2$1").alias("swap"),
            P.col("r").str.replace_all("([a-z])([0-9])", "${2}_$1").alias("swap_all"),
            P.col("r").str.replace_all("[0-9]", "<$0>").alias("whole"),
            P.col("r").str.replace("a", "$$").alias("dollar"),
            P.col("r").str.replace("(a)", "[$3]").alias("missing_group"),
            P.col("r").str.replace("b", "\\").alias("backslash"),
            P.col("r").str.replace_all("\\$", "USD").alias("escaped_dollar"),
        ),
    ),
    (
        "replace_literal",
        lambda P, lf: lf.select(
            "id",
            P.col("r").str.replace(".", "!", literal=True).alias("dot"),
            P.col("r").str.replace_all(".", "!", literal=True).alias("dots"),
            P.col("r").str.replace("$", "$1", literal=True).alias("dollar"),
            P.col("r").str.replace_all("$", "\\", literal=True).alias("dollars"),
            P.col("r").str.replace("\\", "/", literal=True).alias("backslash"),
            P.col("r").str.replace_all("ab", "$0", literal=True).alias("ab"),
        ),
    ),
]


def table():
    return pa.table(
        {
            "id": pa.array(range(len(T)), pa.int64()),
            "t": pa.array(T, pa.string()),
            "r": pa.array(R, pa.string()),
        }
    )


_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def _same_type(derived, answered):
    if derived in _STRING_LAYOUTS:
        return answered in _STRING_LAYOUTS
    return derived == answered


def check(name, lf_k, lf_p):
    want = lf_p.collect()
    arrow = lf_k.collect().to_arrow()
    derived = lf_k.schema
    assert list(derived) == arrow.schema.names, (name, list(derived), arrow.schema.names)
    for field in arrow.schema:
        assert _same_type(derived[field.name], field.type), (name, field.name, derived[field.name], field.type)
    got = pl.from_arrow(arrow)
    try:
        assert_frame_equal(got, want, check_row_order=False)
    except AssertionError as e:
        raise AssertionError(f"{name}: komira.pl\n{got}\npolars\n{want}\n{e}") from None


def test_the_file_holds_the_strings_the_cases_need():
    stripped = [None if v is None else v.strip() for v in T]
    assert "" in stripped and None in T and "" in T
    assert any(v and v[0] == "\xa0" for v in T) and any(v and "　" in v for v in T)
    assert any(v and v[0] == "\x1c" for v in T), "a separator Python strips and polars keeps"


def run_cases(session, path, cases):
    for name, program in cases:
        lf_k = program(kpl, kpl.scan_parquet(path, session=session))
        lf_p = program(pl, pl.scan_parquet(path))
        check(name, lf_k, lf_p)
    print("pl_strings_oracle: {} programs equal polars' answers".format(len(cases)))


def test_strip_chars_keeps_the_separators_python_strips():
    # what makes polars' whitespace differ from pandas': polars keeps U+001C
    got = pl.DataFrame({"t": ["\x1cfs\x1f", "\xa0x\xa0"]}).select(pl.col("t").str.strip_chars())["t"].to_list()
    assert got == ["\x1cfs\x1f", "x"], got


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    test_the_file_holds_the_strings_the_cases_need()
    test_strip_chars_keeps_the_separators_python_strips()
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "text.parquet")
        pq.write_table(table(), path)
        with Session() as session:
            run_cases(session, path, STRIPS + REPLACES)


if __name__ == "__main__":
    main(sys.argv[1:])
