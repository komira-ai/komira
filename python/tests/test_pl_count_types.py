"""komira.pl's count types, in the frame and in the user docs.

polars answers a count as UInt32; komira.pl answers it as Int64, the plan's own
count type (docs/design/dataframe_surface.md, section 8, ruling 14, "count
types"). For each expression of that kind:

- the type `schema` derives for it, without running, is Int64: `len()`,
  `count()`, `n_unique()` and `str.len_chars()` in `select`, `sum()` of a
  boolean and of a UInt32 column, `group_by().len()`, `n_unique()` and
  `count()` in `group_by().agg()`, a `rank()` other than "average" and
  `cum_count()`;
- the page of python/docs/pl/ that covers it names it in a backticked code
  span of a paragraph that says "UInt32", so a reader learns the type differs
  from polars'; the failure lists every name that is missing, with its page;
- on synthetic pages the finding is exactly what is missing: a name absent
  from the page, a name only in prose (not a code span), a name only in a
  paragraph that does not say "UInt32", and a name that is only part of a
  longer span are each a finding; a name in a "UInt32" paragraph whose lines
  wrap is not.

The frames are scans of a stand-in session with no library, as in
pl/test_pl_frames.py; the values beside these types are compared with polars
itself in pl_oracle/.

    test_pl_count_types.py <expressions.md> <group_by_join_unique.md> <windows.md>

The arguments are the pages of python/docs/pl/ (python/BUCK, the
`docs/pl/*.md` export_file targets).
"""

import os
import re
import sys
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "count_types.parquet")
TYPES = [("id", "int64"), ("x", "int64"), ("g", "string"), ("flag", "bool"), ("u32", "uint32")]


class StandIn(Session):
    """A session with no library: the file's schema is `TYPES`."""

    def __init__(self):
        pass

    def _parquet_schema(self, path):
        assert path == PATH, path
        fields = [field(n, arrow_id(t), True) for n, t in TYPES]
        return pb.WireSchema(fields=fields).SerializeToString()

    def close(self):
        pass


SESSION = StandIn()


def frame():
    return kpl.scan_parquet(PATH, session=SESSION)


# Each count: (the page that names it, the code span it is named by, the
# frame that computes it, the column). The page is a key of `PAGES`.
COUNTS = [
    ("expressions", "len()", lambda: frame().select(kpl.len()), "len"),
    ("expressions", "count()", lambda: frame().select(kpl.col("x").count()), "x"),
    ("expressions", "n_unique()", lambda: frame().select(kpl.col("g").n_unique()), "g"),
    ("expressions", "str.len_chars()", lambda: frame().select(kpl.col("g").str.len_chars()), "g"),
    ("expressions", "sum()", lambda: frame().select(kpl.col("flag").sum()), "flag"),
    ("expressions", "sum()", lambda: frame().select(kpl.col("u32").sum()), "u32"),
    ("group_by", "len()", lambda: frame().group_by("g").len(), "len"),
    ("group_by", "n_unique()", lambda: frame().group_by("g").agg(kpl.col("x").n_unique()), "x"),
    ("group_by", "count()", lambda: frame().group_by("g").agg(kpl.col("x").count()), "x"),
    ("windows", "rank()", lambda: frame().select(kpl.col("x").rank("min")), "x"),
    ("windows", "cum_count()", lambda: frame().sort("id").select(kpl.col("x").cum_count()), "x"),
]

PAGES = ("expressions", "group_by", "windows")

# A code span: a run of backticks, the text up to the next run of exactly as
# many, as Markdown reads it.
SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.DOTALL)


def documented(text):
    """The code spans of the paragraphs of `text` that say "UInt32", each with
    its line breaks read as spaces."""
    spans = set()
    for paragraph in re.split(r"\n\s*\n", text):
        flat = " ".join(paragraph.split())
        if "UInt32" in flat:
            spans.update(m.group(2).strip() for m in SPAN.finditer(flat))
    return spans


def missing(pages, counts):
    """The (page, span) pairs of `counts` whose page does not name the span
    as `documented` reads it, once each, in order."""
    found = []
    for page, span, _, _ in counts:
        if span not in documented(pages[page]) and (page, span) not in found:
            found.append((page, span))
    return found


def test_each_count_is_an_int64_in_the_schema():
    for page, span, build, column in COUNTS:
        got = build().schema[column]
        assert got == pa.int64(), (page, span, column, got)


def test_each_count_is_named_on_its_page_as_a_departure_from_uint32(pages):
    gaps = missing(pages, COUNTS)
    assert gaps == [], (
        "pages of python/docs/pl/ that do not name a count as Int64 where polars gives UInt32: "
        + ", ".join(f"{page}: `{span}`" for page, span in gaps)
    )


ONE = [("p", "n_unique()", None, None)]


def test_a_name_absent_from_the_page_is_the_finding():
    assert missing({"p": "A count is Int64 where polars gives UInt32: `len()`.\n"}, ONE) == [("p", "n_unique()")]


def test_a_name_only_in_prose_is_a_finding():
    assert missing({"p": "n_unique() is Int64 where polars gives UInt32.\n"}, ONE) == [("p", "n_unique()")]


def test_a_name_in_a_paragraph_without_uint32_is_a_finding():
    text = "`n_unique()` counts the distinct values.\n\nA count is Int64 where polars gives UInt32.\n"
    assert missing({"p": text}, ONE) == [("p", "n_unique()")]


def test_a_name_that_is_part_of_a_longer_span_is_a_finding():
    text = "`col.n_unique().alias()` is Int64 where polars gives UInt32.\n"
    assert missing({"p": text}, ONE) == [("p", "n_unique()")]


def test_a_name_in_a_wrapped_uint32_paragraph_is_documented():
    text = "A count is Int64,\nas is `n_unique()`,\nwhere polars gives\nUInt32.\n"
    assert missing({"p": text}, ONE) == []


def test_each_missing_name_is_listed_once_in_order():
    counts = [
        ("p", "len()", None, None),
        ("q", "rank()", None, None),
        ("p", "len()", None, None),
        ("p", "count()", None, None),
    ]
    pages = {"p": "`count()` is Int64 where polars gives UInt32.\n", "q": "`rank()` ranks.\n"}
    assert missing(pages, counts) == [("p", "len()"), ("q", "rank()")]


def main(argv):
    if len(argv) != len(PAGES):
        raise SystemExit(f"usage: test_pl_count_types.py {' '.join(f'<{p}>' for p in PAGES)}")
    pages = {}
    for name, path in zip(PAGES, argv):
        with open(path, encoding="utf-8") as f:
            pages[name] = f.read()
    tests = sorted((n, f) for n, f in globals().items() if n.startswith("test_"))
    for name, test in tests:
        if test.__code__.co_argcount:
            test(pages)
        else:
            test()
    print(f"{len(tests)} tests passed")


if __name__ == "__main__":
    main(sys.argv[1:])
