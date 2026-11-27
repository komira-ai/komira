"""komira.read_csv(path, chunksize=n) and iterator=True on the real libkomira:
the CSV file as a reader of pyarrow.Table chunks (komira/_chunks.py), each
read from the file when it is asked for, under the column names and types the
engine infers from the start of the file:

- chunk sizes: 2 over 5 rows gives 2, 2, 1 in the file's order; a chunksize
  larger than the file gives one chunk; a file of a header alone gives none;
- the chunks of a file of several read blocks, with every type the engine
  infers, NULL tokens, quoted delimiters, quotes and line breaks, laid end to
  end, equal the engine's own answer for the whole file (Session.sql over
  register_csv), and each has the type `read_csv` derives for its column;
- a later row whose cells disagree with the types of the start of the file
  reads them as NULL, as the engine does;
- the file is not read to the end before the first chunk: a file whose last
  row is malformed gives its first chunk, and the error only when the reader
  reaches that row (the engine refuses the same file whole);
- close(), leaving a `with` block and reaching the end release the file, and
  a closed reader refuses a chunk with ValueError;
- iterator=True with get_chunk(size), size 0 and size None;
- header=None and sep="|";
- a chunksize of 0, negative, fractional, a bool or a str raises pandas'
  ValueError before the file is touched; get_chunk(-1) and iterator="yes"
  are refused; a missing file raises BindError at read_csv as without
  chunksize; a pandas option komira does not take is refused by name.

The test is of the `run/` family (python/tests/BUCK): `read_csv_chunks_test`
runs on the real libkomira on each supported minor.

    test_read_csv_chunks.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import datetime
import gc
import os
import sys
import tempfile
import warnings

import pyarrow as pa

import komira
from komira import BindError, KomiraError
from komira import _native

FIVE = "id,name,score\n1,ann,10.5\n2,bo,20\n3,cy,\n4,,4.25\n5,ed,-1\n"
FIVE_ROWS = [
    {"id": 1, "name": "ann", "score": 10.5},
    {"id": 2, "name": "bo", "score": 20.0},
    {"id": 3, "name": "cy", "score": None},
    {"id": 4, "name": None, "score": 4.25},
    {"id": 5, "name": "ed", "score": -1.0},
]
CHUNKSIZE_MESSAGE = "'chunksize' must be an integer >=1"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def write(work, name, text):
    path = os.path.join(work, name)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    return path


def rows(chunks):
    return [r for c in chunks for r in c.to_pylist()]


def engine_rows(s, path, name):
    """The engine's answer for the whole file, in the order of `id`."""
    s.register_csv(name, path)
    return s.sql("SELECT * FROM {} ORDER BY id".format(name)).to_arrow().to_pylist()


def unreleased(make):
    """The ResourceWarnings of the files `make()` left open once what it made
    is collected."""
    with warnings.catch_warnings(record=True) as seen:
        warnings.simplefilter("always", ResourceWarning)
        make()
        gc.collect()
    return [w for w in seen if issubclass(w.category, ResourceWarning)]


def big_text(n):
    """A file of `n` rows over every type the engine infers, its cells in
    every form the engine reads; the first 100 rows decide the types."""
    lines = ["id,n,x,s,d,b"]
    day = datetime.date(2026, 9, 1)
    bools = ["true", "F", "yes", "N", "1", "0", "TRUE", "false", "T", "no", "Y", "FALSE"]
    for i in range(1, n + 1):
        num = "" if i % 7 == 0 else ("+{}".format(i) if i % 11 == 0 else str(i * 3 - 500))
        if i % 13 == 0:
            x = ".5"
        elif i % 17 == 0:
            x = "5."
        elif i % 19 == 0:
            x = "-1e3"
        elif i % 23 == 0:
            x = "NaN"
        else:
            x = str(i / 4)
        if i % 5 == 0:
            s = '"quoted, with a comma"'
        elif i % 9 == 0:
            s = '"two\nlines"'
        elif i % 29 == 0:
            s = '""'
        elif i % 31 == 0:
            s = "NULL"
        elif i % 37 == 0:
            s = '"say ""hi"""'
        else:
            s = "s{}".format(i)
        d = "" if i % 41 == 0 else (day + datetime.timedelta(days=i % 300)).isoformat()
        b = "" if i % 43 == 0 else bools[i % len(bools)]
        lines.append(",".join([str(i), num, x, s, d, b]))
    return "\n".join(lines) + "\n"


def test_chunks_of_two_over_five_rows(s, work):
    """chunksize=2 over 5 rows gives tables of 2, 2 and 1 rows, in the file's order."""
    path = write(work, "five.csv", FIVE)
    reader = komira.read_csv(path, chunksize=2, session=s)
    chunks = list(reader)
    assert all(type(c) is pa.Table for c in chunks), chunks
    assert [c.num_rows for c in chunks] == [2, 2, 1], [c.num_rows for c in chunks]
    assert rows(chunks) == FIVE_ROWS, rows(chunks)
    assert type(raised(reader.get_chunk)) is StopIteration


def test_chunksize_larger_than_file(s, work):
    """A chunksize larger than the file gives one chunk of all its rows."""
    path = write(work, "five.csv", FIVE)
    chunks = list(komira.read_csv(path, chunksize=100, session=s))
    assert [c.num_rows for c in chunks] == [5], [c.num_rows for c in chunks]
    assert rows(chunks) == FIVE_ROWS


def test_header_only_file_gives_no_chunk(s, work):
    """A file of a header line alone gives no chunk, and get_chunk raises StopIteration."""
    path = write(work, "header.csv", "id,name\n")
    assert list(komira.read_csv(path, chunksize=3, session=s)) == []
    reader = komira.read_csv(path, iterator=True, session=s)
    assert type(raised(reader.get_chunk)) is StopIteration


def test_chunks_concatenated_equal_whole_file(s, work):
    """Chunks of 7 over a file of several blocks are 7 rows each but the
    last, and laid end to end they are the engine's answer for the file,
    with read_csv's types."""
    n = 60000
    text = big_text(n)
    assert len(text.encode()) > 2 * (1 << 20), len(text)  # more than two read blocks
    path = write(work, "big.csv", text)
    dtypes = komira.read_csv(path, session=s).dtypes
    assert dtypes == {"id": "int64", "n": "int64", "x": "float64", "s": "string", "d": "date32", "b": "bool"}, dtypes
    chunks = list(komira.read_csv(path, chunksize=7, session=s))
    sizes = [c.num_rows for c in chunks]
    assert sizes == [7] * (n // 7) + [n % 7], sizes[-3:]
    for c in chunks:
        assert [(f.name, f.type) for f in c.schema] == [(k, pa.type_for_alias(v)) for k, v in dtypes.items()]
    got = rows(chunks)
    want = engine_rows(s, path, "big")
    assert len(got) == len(want) == n
    for g, w in zip(got, want):
        assert g == w, (g, w)


def test_later_rows_that_disagree_with_types_are_null(s, work):
    """Past the 100 rows the types come from, a cell that does not fit its
    column's type is NULL in its chunk, as the engine reads it; an integer
    outside int64 is NULL too."""
    lines = ["id,n,d,b"] + ["{},{},2026-09-0{},true".format(i, i, 1 + i % 9) for i in range(1, 151)]
    lines += ["151,abc,2026-02-30,maybe", "152,1.5,2026-9-1,True", "153, 7,x,0", "154,99999999999999999999,,1"]
    path = write(work, "later.csv", "\n".join(lines) + "\n")
    assert komira.read_csv(path, session=s).dtypes == {"id": "int64", "n": "int64", "d": "date32", "b": "bool"}
    chunks = list(komira.read_csv(path, chunksize=50, session=s))
    assert [c.num_rows for c in chunks] == [50, 50, 50, 4]
    last = chunks[-1].to_pylist()
    assert last == [
        {"id": 151, "n": None, "d": None, "b": None},
        {"id": 152, "n": None, "d": None, "b": None},
        {"id": 153, "n": None, "d": None, "b": False},
        {"id": 154, "n": None, "d": None, "b": True},
    ], last
    # The engine reads the cells it can tell apart the same way.
    want = engine_rows(s, path, "later")
    assert rows(chunks)[:153] == want[:153]


def test_first_chunk_arrives_before_bad_rows(s, work):
    """A file whose last row has a field too few gives its first chunk; the
    error comes only from the call that reaches that row, and closes the reader."""
    good = "".join("{},{}\n".format(i, i * 2) for i in range(1, 300001))
    path = write(work, "bad_end.csv", "id,v\n" + good + "300001\n")
    assert os.path.getsize(path) > 3 * (1 << 20)
    engine = raised(lambda: engine_rows(s, path, "bad_end"))
    assert isinstance(engine, KomiraError), repr(engine)
    reader = komira.read_csv(path, chunksize=10, session=s)
    first = next(reader)
    assert first.to_pylist() == [{"id": i, "v": i * 2} for i in range(1, 11)]
    e = raised(lambda: [None for _ in reader])
    assert type(e) is KomiraError, repr(e)
    assert str(e).startswith("read_csv: reading '{}' stopped: ".format(path)), str(e)
    closed = raised(reader.get_chunk)
    assert type(closed) is ValueError and str(closed) == "read_csv: the reader of '{}' is closed".format(path)


def test_close_releases_the_file(s, work):
    """close() after one chunk, a `with` block and reaching the end each
    leave no file open; a reader dropped unclosed leaves the file it opened
    to the collector, which warns."""
    path = write(work, "five.csv", FIVE)

    def closed_early():
        reader = komira.read_csv(path, chunksize=1, session=s)
        assert next(reader).num_rows == 1
        reader.close()
        reader.close()  # a second close does nothing
        e = raised(reader.get_chunk)
        assert type(e) is ValueError and str(e) == "read_csv: the reader of '{}' is closed".format(path)
        assert type(raised(lambda: reader.get_chunk(0))) is ValueError

    def with_block():
        with komira.read_csv(path, chunksize=2, session=s) as reader:
            assert next(reader).num_rows == 2
        assert type(raised(reader.get_chunk)) is ValueError

    def to_the_end():
        assert len(list(komira.read_csv(path, chunksize=2, session=s))) == 3

    def dropped():
        komira.read_csv(path, chunksize=1, session=s)

    for make in (closed_early, with_block, to_the_end):
        assert unreleased(make) == [], make.__name__
    assert len(unreleased(dropped)) == 1


def test_iterator_true_get_chunk(s, work):
    """iterator=True: get_chunk(size) takes the next size rows, 0 none, and
    with no size the chunksize, or the rest of the file without one."""
    path = write(work, "five.csv", FIVE)
    reader = komira.read_csv(path, iterator=True, session=s)
    assert reader.chunksize is None
    assert reader.get_chunk(2).to_pylist() == FIVE_ROWS[:2]
    empty = reader.get_chunk(0)
    assert empty.num_rows == 0 and empty.schema.names == ["id", "name", "score"]
    assert reader.get_chunk(2.0).to_pylist() == FIVE_ROWS[2:4]
    assert reader.get_chunk().to_pylist() == FIVE_ROWS[4:]
    assert type(raised(reader.get_chunk)) is StopIteration
    assert type(raised(reader.get_chunk)) is StopIteration  # and again
    assert reader.get_chunk(0).num_rows == 0
    reader = komira.read_csv(path, iterator=True, chunksize=3, session=s)
    assert reader.chunksize == 3
    assert reader.get_chunk().num_rows == 3
    assert reader.get_chunk(1).to_pylist() == FIVE_ROWS[3:4]
    assert rows(reader) == FIVE_ROWS[4:]
    assert [c.num_rows for c in komira.read_csv(path, iterator=True, session=s)] == [5]


def test_header_none_and_sep(s, work):
    """header=None names the columns as the engine does and reads the first
    line as a row; sep="|" splits on the bar."""
    path = write(work, "bare.csv", "1|ann\n2|bo\n3|\n")
    names = komira.read_csv(path, sep="|", header=None, session=s).columns
    chunks = list(komira.read_csv(path, sep="|", header=None, chunksize=2, session=s))
    assert [c.schema.names for c in chunks] == [names, names], names
    assert rows(chunks) == [dict(zip(names, r)) for r in [(1, "ann"), (2, "bo"), (3, None)]]


def test_refusals(s, work):
    """A chunksize that is not an integer of at least 1 raises pandas'
    ValueError before the file is touched; so do get_chunk(-1) and a size
    that is not a count; iterator must be a bool; a missing file is
    BindError; a pandas option komira does not take is refused by name."""
    missing = os.path.join(work, "missing.csv")
    for bad in (0, -1, 1.5, True, "2"):
        e = raised(lambda: komira.read_csv(missing, chunksize=bad, session=s))
        assert type(e) is ValueError and str(e) == CHUNKSIZE_MESSAGE, (bad, repr(e))
    e = raised(lambda: komira.read_csv(missing, iterator="yes", session=s))
    assert type(e) is TypeError and str(e) == "read_csv iterator must be a bool, not str", repr(e)
    e = raised(lambda: komira.read_csv(missing, chunksize=2, session=s))
    assert type(e) is BindError and missing in str(e), repr(e)
    path = write(work, "five.csv", FIVE)
    assert [c.num_rows for c in komira.read_csv(path, chunksize=2.0, session=s)] == [2, 2, 1]
    reader = komira.read_csv(path, chunksize=2, session=s)
    for bad in (-1, 0.5, "1"):
        e = raised(lambda: reader.get_chunk(bad))
        assert type(e) is ValueError and str(e) == "'size' must be an integer >=0", (bad, repr(e))
    reader.close()
    e = raised(lambda: komira.read_csv(path, chunksize=2, nrows=3, session=s))
    assert type(e) is TypeError and "'nrows'" in str(e), repr(e)


TESTS = [
    test_chunks_of_two_over_five_rows,
    test_chunksize_larger_than_file,
    test_header_only_file_gives_no_chunk,
    test_chunks_concatenated_equal_whole_file,
    test_later_rows_that_disagree_with_types_are_null,
    test_first_chunk_arrives_before_bad_rows,
    test_close_releases_the_file,
    test_iterator_true_get_chunk,
    test_header_none_and_sep,
    test_refusals,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in TESTS:
        with tempfile.TemporaryDirectory() as work, komira.Session() as s:
            test(s, work)
        print("ok", test.__name__)
    print("read_csv chunks: {} cases".format(len(TESTS)))


if __name__ == "__main__":
    main(sys.argv[1:])
