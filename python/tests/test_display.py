"""The notebook display of a frame and of a result (komira/_display.py,
`DataFrame._repr_html_` and `Result._repr_html_`), with no libkomira: a frame
over a Parquet scan whose schema is made here, on a session stand-in that
records every call, and results over pyarrow readers made here. Checked, each
HTML by equality with the whole text:

- a frame shows its names over their types and the line that it has not run,
  equal to fixtures/display/frame.html; it calls nothing on its session and
  imports no pyarrow; the types after a verb are the derived ones; one column
  is "1 column"; a Series has no HTML display;
- a result of six types shows its rows, equal to fixtures/display/result.html:
  Arrow's text of integers, floats, booleans and dates, null in italics, an
  escaped string, and Python's `str` of bytes that are not UTF-8;
- the row limit: ten rows at most, the line saying there are more, and the
  stream read only to one batch past the tenth row; exactly ten rows, eleven
  in one batch, ten then an empty batch then one, no rows, one row;
- a value's text of 100 characters is shown whole, one of 101 is cut to 100
  and ends with "…", and a cut text is escaped after the cut;
- the result stays unread: after a display (and after two) each terminal
  reads every row, once; a result already read shows nothing (None);
- a stream that fails while the rows are read (an Arrow error or an OSError,
  at the first batch or a later one) raises KomiraError with the stream's own
  text from the display, and the same from the terminal after it; a stream
  that fails past the shown rows displays, and fails at the terminal;
- a KeyboardInterrupt while the rows are read propagates and leaves the
  result read;
- a terminal called on another thread while a display reads waits for it and
  then reads every row.

    test_display.py
"""

import os
import sys
import tempfile
import threading

import komira
from komira import KomiraError, Result
from komira import _ops
from komira._frame import DataFrame
from komira._ops import Field
from komira._plan import parquet_source
from komira._plan._wire import arrow_id, field, pb

HERE = os.path.dirname(os.path.abspath(__file__))
ALREADY_READ = "the result was already read: run the query again to read it again"

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "display_test_input.parquet")
FIELDS = (("a", "int64"), ("x", "float64"), ("s", "string"), ("ok", "bool"), ('<b>&"', "int32"))
NOT_RUN = "a plan that has not run; .materialize() runs it and returns its rows"


class Stub:
    """A session that records every call a frame makes on it."""

    def __init__(self):
        self.calls = []

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))

    def _plan_render(self, plan):
        self.calls.append(("plan_render", plan))


def frame(fields=FIELDS):
    stub = Stub()
    schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in fields])
    sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
    scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
    return DataFrame._new(stub, scan, sources), stub


def fixture(name):
    with open(os.path.join(HERE, "fixtures", "display", name), encoding="utf-8") as f:
        return f.read().removesuffix("\n")


# The frame's display, before pyarrow is imported by this file.
_DF, _STUB = frame()
FRAME_HTML = _DF._repr_html_()
assert "pyarrow" not in sys.modules, "the display of a frame imported pyarrow"

import pyarrow as pa  # noqa: E402


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def table_html(names, types, rows, note):
    head = "".join(f"<th>{n}</th>" for n in names)
    kinds = "".join(f"<th>{t}</th>" for t in types)
    body = "".join("<tr>" + "".join(f"<td>{v}</td>" for v in row) + "</tr>" for row in rows)
    return (
        '<div class="komira"><table class="dataframe">'
        f"<thead><tr>{head}</tr><tr>{kinds}</tr></thead><tbody>{body}</tbody></table><p>{note}</p></div>"
    )


class Counted:
    """A result over `batches`, yielded one at a time; `pulled` counts the
    batches the result asked for, and `fail` (index, exception) raises the
    exception in place of the batch at that index."""

    def __init__(self, schema, batches, fail=None):
        self.pulled = 0
        self.schema = schema
        self.batches = batches
        self.fail = fail
        self.result = Result(pa.RecordBatchReader.from_batches(schema, self._gen()))

    def _gen(self):
        for i, batch in enumerate(self.batches):
            self.pulled += 1
            if self.fail is not None and self.fail[0] == i:
                raise self.fail[1]
            yield batch


INTS = pa.schema([pa.field("v", pa.int64())])


def ints(*sizes):
    """Batches of `v` with the given row counts, numbering the rows from 0."""
    out, start = [], 0
    for n in sizes:
        out.append(pa.record_batch([pa.array(range(start, start + n), pa.int64())], schema=INTS))
        start += n
    return out


def int_rows(n):
    return [[str(i)] for i in range(n)]


def read_all_ways(make, expected):
    """Each terminal reads `expected` from a result `make()` displayed first."""
    for terminal in (
        lambda r: r.to_arrow(),
        lambda r: r.to_reader().read_all(),
        lambda r: pa.table(r),
    ):
        r = make()
        assert r._repr_html_() is not None
        t = terminal(r)
        assert t.equals(expected), t
        e = raised(r.to_arrow)
        assert type(e) is KomiraError and str(e) == ALREADY_READ, repr(e)
        assert r._repr_html_() is None


# --- the frame ------------------------------------------------------------------


def test_a_frame_shows_its_names_over_their_types_and_runs_nothing():
    assert FRAME_HTML == fixture("frame.html"), FRAME_HTML
    assert _STUB.calls == []
    df, stub = frame()
    assert df._repr_html_() == FRAME_HTML
    assert stub.calls == []


def test_a_frame_after_verbs_shows_the_derived_types():
    df, stub = frame()
    small = df[["x", "a"]]
    out = small.assign(h=small["a"] / 2, c=small["a"] > 1)
    assert out._repr_html_() == table_html(
        ["x", "a", "h", "c"], ["float64", "int64", "float64", "bool"], [],
        f"komira.DataFrame of 4 columns: {NOT_RUN}",
    )
    one = df[["s"]]
    assert one._repr_html_() == table_html(["s"], ["string"], [], f"komira.DataFrame of 1 column: {NOT_RUN}")
    assert stub.calls == []


def test_a_series_has_no_html_display():
    df, _ = frame()
    assert hasattr(df, "_repr_html_")
    assert not hasattr(df["a"], "_repr_html_")


# --- the result -----------------------------------------------------------------

RESULT = pa.table(
    {
        "id": pa.array([1, 2, 3], pa.int64()),
        "score": pa.array([2.5, None, -0.25], pa.float64()),
        "name": pa.array(["ann", None, '<b>&"x"</b>'], pa.string()),
        "ok": pa.array([True, False, None], pa.bool_()),
        "day": pa.array([20697, 20818, None], pa.date32()),  # 2026-09-01, 2026-12-31
        "raw": pa.array([b"\xff", b"ok", None], pa.binary()),
    }
)


def test_a_result_shows_its_rows():
    r = Result(RESULT.to_reader())
    assert r._repr_html_() == fixture("result.html"), r._repr_html_()


def test_a_result_shown_still_reads_every_row_once():
    read_all_ways(lambda: Result(RESULT.to_reader(max_chunksize=1)), RESULT)
    # Shown twice, it shows the same rows and still reads whole.
    r = Result(RESULT.to_reader(max_chunksize=2))
    first = r._repr_html_()
    assert r._repr_html_() == first == fixture("result.html")
    assert r.to_arrow().equals(RESULT)


def test_a_result_already_read_shows_nothing():
    r = Result(RESULT.to_reader())
    r.to_arrow()
    assert r._repr_html_() is None


def test_ten_rows_at_most_and_one_batch_past_them():
    c = Counted(INTS, ints(4, 4, 4, 4, 4, 4, 1))
    assert c.result._repr_html_() == table_html(["v"], ["int64"], int_rows(10), "the first 10 rows of more, 1 column")
    assert c.pulled == 3
    t = c.result.to_arrow()
    assert t.column("v").to_pylist() == list(range(25))
    assert c.pulled == 7
    read_all_ways(lambda: Counted(INTS, ints(4, 4, 4, 4, 4, 4, 1)).result, pa.Table.from_batches(ints(25)))


def test_the_row_limit_at_its_edges():
    cases = (
        (ints(10), int_rows(10), "10 rows, 1 column"),
        (ints(11), int_rows(10), "the first 10 rows of more, 1 column"),
        (ints(5, 5), int_rows(10), "10 rows, 1 column"),
        (ints(10, 0, 1), int_rows(10), "the first 10 rows of more, 1 column"),
        (ints(0, 1), int_rows(1), "1 row, 1 column"),
        (ints(), [], "0 rows, 1 column"),
    )
    for batches, rows, note in cases:
        r = Result(pa.RecordBatchReader.from_batches(INTS, iter(batches)))
        assert r._repr_html_() == table_html(["v"], ["int64"], rows, note), (note, r)
        assert r.to_arrow().num_rows == sum(b.num_rows for b in batches)
    two = pa.schema([pa.field("a", pa.int64()), pa.field("b", pa.string())])
    r = Result(pa.RecordBatchReader.from_batches(two, iter(())))
    assert r._repr_html_() == table_html(["a", "b"], ["int64", "string"], [], "0 rows, 2 columns")


def test_a_long_value_is_cut_at_100_characters_then_escaped():
    texts = ["a" * 100, "b" * 101, "c" * 99 + "&" + "d", "&" * 101]
    r = Result(pa.table({"t": pa.array(texts, pa.string())}).to_reader())
    assert r._repr_html_() == table_html(
        ["t"], ["string"],
        [["a" * 100], ["b" * 100 + "…"], ["c" * 99 + "&amp;…"], ["&amp;" * 100 + "…"]],
        "4 rows, 1 column",
    )


def test_a_stream_that_fails_while_the_rows_are_read():
    for at in (0, 1):
        for error in (pa.ArrowInvalid("execute: the stand-in fails"), OSError(5, "the stand-in fails")):
            c = Counted(INTS, ints(4, 4, 4), fail=(at, error))
            e = raised(c.result._repr_html_)
            assert type(e) is KomiraError and str(e) == str(error) and e.__cause__ is error, repr(e)
            # The terminal raises the same failure, and the result is then read.
            e = raised(c.result.to_arrow)
            assert type(e) is KomiraError and str(e) == str(error), repr(e)
            assert c.result._repr_html_() is None
            e = raised(c.result.to_arrow)
            assert type(e) is KomiraError and str(e) == ALREADY_READ, repr(e)


def test_a_stream_that_fails_past_the_shown_rows():
    error = pa.ArrowInvalid("execute: the stand-in fails")
    c = Counted(INTS, ints(4, 4, 4, 4), fail=(3, error))
    assert c.result._repr_html_() == table_html(["v"], ["int64"], int_rows(10), "the first 10 rows of more, 1 column")
    e = raised(c.result.to_arrow)
    assert type(e) is KomiraError and str(e) == str(error), repr(e)


def test_a_keyboard_interrupt_while_the_rows_are_read_leaves_the_result_read():
    c = Counted(INTS, ints(4, 4, 4), fail=(1, KeyboardInterrupt()))
    e = raised(c.result._repr_html_)
    assert type(e) is KeyboardInterrupt, repr(e)
    assert c.result._repr_html_() is None
    e = raised(c.result.to_arrow)
    assert type(e) is KomiraError and str(e) == ALREADY_READ, repr(e)


def test_a_terminal_on_another_thread_waits_for_a_display():
    reading, go = threading.Event(), threading.Event()
    batches = ints(4, 4, 4, 4)

    def gen():
        yield batches[0]
        reading.set()  # the display has taken the stream and is reading it
        go.wait()
        yield from batches[1:]

    r = Result(pa.RecordBatchReader.from_batches(INTS, gen()))
    out = {}

    def display():
        out["html"] = r._repr_html_()

    def terminal():
        try:
            out["table"] = r.to_arrow()
        except KomiraError as e:
            out["error"] = e

    shower = threading.Thread(target=display)
    shower.start()
    reading.wait()
    reader = threading.Thread(target=terminal)
    reader.start()
    go.set()
    shower.join()
    reader.join()
    assert "error" not in out, out
    assert out["html"] == table_html(["v"], ["int64"], int_rows(10), "the first 10 rows of more, 1 column")
    assert out["table"].column("v").to_pylist() == list(range(16))


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("display: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
