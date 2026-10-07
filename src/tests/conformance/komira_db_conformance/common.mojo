# =============================================================================
# komira_db_conformance/common.mojo -- the runtime, row builders and value
#   comparisons the checks share.
# =============================================================================
#
# Every check runs on a `BlockingRuntime[NoopSink]` of its own (the runtime the
# trait documents for single-shot and test use).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import DbRow, DbRows, DbValue, LOGICAL_TEXT, LOGICAL_TIMESTAMPTZ

comptime Rt = BlockingRuntime[NoopSink]


def new_rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def strs(*items: StaticString) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(String(s))
    return out^


def item_cols() -> List[String]:
    """conf_items' columns, in the order `item_row` fills them."""
    return strs(
        "id", "owner", "phase", "version", "note", "created_at", "updated_at"
    )


def item_row(
    id: String,
    owner: String,
    phase: String,
    version: Int64,
    note: Optional[String],
    created_at: Int64,
) -> List[DbValue]:
    """One conf_items row; `updated_at` is NULL."""
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(owner))
    out.append(DbValue.text(phase))
    out.append(DbValue.int8(version))
    if note:
        out.append(DbValue.text(note.value()))
    else:
        out.append(DbValue.null(LOGICAL_TEXT))
    out.append(DbValue.int8(created_at))
    out.append(DbValue.null(LOGICAL_TIMESTAMPTZ))
    return out^


def no_note() -> Optional[String]:
    return Optional[String]()


def a_note(s: StaticString) -> Optional[String]:
    return Optional[String](String(s))


def now_micros(rows: DbRows, col: String) raises -> Int64:
    """The now-stamped TIMESTAMPTZ column `col` of the first row, in µs since
    the UNIX epoch (raises when it is NULL)."""
    var ci = rows.column_index(col)
    if ci < 0:
        raise Error(String("result has no column '") + col + String("'"))
    if rows.row(0).is_null(ci):
        raise Error(col + String(" was not stamped (NULL)"))
    return rows.row(0).get_timestamptz_micros(ci)


def text_col(rows: DbRows, col: String) raises -> List[String]:
    """Column `col` of every row, in row order (a NULL reads as `<NULL>`)."""
    var out = List[String]()
    var ci = rows.column_index(col)
    if ci < 0:
        raise Error(String("result has no column '") + col + String("'"))
    for i in range(rows.__len__()):
        ref r = rows.row(i)
        if r.is_null(ci):
            out.append(String("<NULL>"))
        else:
            out.append(r.get_text(ci))
    return out^


def sorted_strs(var xs: List[String]) -> List[String]:
    """`xs` in ascending byte order (insertion sort; the lists are short)."""
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            var t = xs[j - 1]
            xs[j - 1] = xs[j]
            xs[j] = t^
            j -= 1
    return xs^


def joined(xs: List[String]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += String(",")
        out += xs[i]
    out += String("]")
    return out^


def assert_strs(got: List[String], want: List[String], what: String) raises:
    assert_equal(joined(got), joined(want), what)


def hex_of(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    var d = digits.as_bytes()
    for i in range(len(b)):
        out += chr(Int(d[Int(b[i]) >> 4]))
        out += chr(Int(d[Int(b[i]) & 15]))
    return out^


def assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(
        String(len(got)) + String(":") + hex_of(got),
        String(len(want)) + String(":") + hex_of(want),
        what,
    )


def assert_raises_with(
    err: Optional[String], fragment: String, what: String
) raises:
    """`err` is the text a call raised (empty Optional when it returned)."""
    if not err:
        raise Error(what + String(": the call returned instead of raising"))
    assert_true(
        err.value().find(fragment) >= 0,
        what
        + String(": the error does not contain '")
        + fragment
        + String("': ")
        + err.value(),
    )
