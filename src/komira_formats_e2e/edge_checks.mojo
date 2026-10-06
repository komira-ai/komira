# =============================================================================
# Collect-all-mismatches checks for the numeric edge tests.
# =============================================================================
#
# A numeric edge test compares many cells; stopping at the first difference
# hides the rest. `Mismatches` records each failed check with its label and
# `raise_if_any` raises once with all of them, so one red build shows every
# value a format got wrong. Expected bytes are built with `le_bytes` /
# `be_bytes` / `hex_bytes` from numbers spelled in the test, never from a
# komira encoder.
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch


struct Mismatches(Movable):
    var items: List[String]

    def __init__(out self):
        self.items = List[String]()

    def add(mut self, msg: String):
        self.items.append(msg)

    def check(mut self, ok: Bool, msg: String):
        if not ok:
            self.items.append(msg)

    def raise_if_any(self, test: String) raises:
        if len(self.items) == 0:
            return
        var out = test + ": " + String(len(self.items)) + " mismatch(es)"
        for i in range(len(self.items)):
            out += "\n  - " + self.items[i]
        raise Error(out)


def hex_u64(v: UInt64) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var out = List[UInt8]()
    out.append(UInt8(ord("0")))
    out.append(UInt8(ord("x")))
    for k in range(16):
        var nib = Int((v >> UInt64(60 - 4 * k)) & UInt64(0xF))
        out.append(digits[nib])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def hex_of(bs: Span[UInt8, _]) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var out = List[UInt8]()
    for i in range(len(bs)):
        if i > 0:
            out.append(UInt8(ord(" ")))
        out.append(digits[Int(bs[i]) >> 4])
        out.append(digits[Int(bs[i]) & 0xF])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def le_bytes(v: UInt64, n: Int) -> List[UInt8]:
    """The low `n` bytes of `v`, least significant first."""
    var out = List[UInt8]()
    for k in range(n):
        out.append(UInt8((v >> UInt64(8 * k)) & UInt64(0xFF)))
    return out^


def be_bytes(v: UInt64, n: Int) -> List[UInt8]:
    """The low `n` bytes of `v`, most significant first."""
    var out = List[UInt8]()
    for k in range(n):
        out.append(UInt8((v >> UInt64(8 * (n - 1 - k))) & UInt64(0xFF)))
    return out^


def hex_bytes(spec: String) raises -> List[UInt8]:
    """Bytes from a hex string with optional spaces, e.g. "FF 01"."""
    var out = List[UInt8]()
    var bs = spec.as_bytes()
    var hi = -1
    for i in range(len(bs)):
        var c = Int(bs[i])
        var v: Int
        if c >= 0x30 and c <= 0x39:
            v = c - 0x30
        elif c >= 0x41 and c <= 0x46:
            v = c - 0x41 + 10
        elif c >= 0x61 and c <= 0x66:
            v = c - 0x61 + 10
        elif c == 0x20:
            continue
        else:
            raise Error("hex_bytes: bad character in " + spec)
        if hi < 0:
            hi = v
        else:
            out.append(UInt8(hi * 16 + v))
            hi = -1
    if hi >= 0:
        raise Error("hex_bytes: odd digit count in " + spec)
    return out^


def same_bytes(got: Span[UInt8, _], want: Span[UInt8, _]) -> Bool:
    if len(got) != len(want):
        return False
    for i in range(len(got)):
        if got[i] != want[i]:
            return False
    return True


def check_bytes(
    mut m: Mismatches, got: Span[UInt8, _], want: Span[UInt8, _], label: String
):
    if not same_bytes(got, want):
        m.add(label + ": got [" + hex_of(got) + "] want [" + hex_of(want) + "]")


def is_nan_bits(b: UInt64) -> Bool:
    return (b & UInt64(0x7FF0000000000000)) == UInt64(
        0x7FF0000000000000
    ) and (b & UInt64(0x000FFFFFFFFFFFFF)) != UInt64(0)


# =============================================================================
# Read-back checks against a RecordBatch.
# =============================================================================


def column_index(batch: RecordBatch, name: String) raises -> Int:
    for c in range(batch.num_columns()):
        if batch.schema.field_name(c) == name:
            return c
    raise Error("no column " + name)


def check_int_column(
    mut m: Mismatches,
    batch: RecordBatch,
    name: String,
    want: List[Int64],
    label: String,
) raises:
    """Column `name` holds exactly `want`, no NULLs. INT64 and INT32 columns
    are both accepted (compared as Int64); any other type is a mismatch."""
    var at = label + " " + name
    if batch.num_rows() != len(want):
        m.add(at + ": " + String(batch.num_rows()) + " rows, want " + String(len(want)))
        return
    var c = column_index(batch, name)
    var t = batch.schema.field_arrow_type(c)
    if t == ArrowType.INT64:
        var a = batch.column_as_primitive_int64(c)
        for r in range(len(want)):
            if a.is_null(r):
                m.add(at + " row " + String(r) + ": NULL, want " + String(want[r]))
            elif a.get(r) != want[r]:
                m.add(
                    at + " row " + String(r) + ": got " + String(a.get(r))
                    + " want " + String(want[r])
                )
    elif t == ArrowType.INT32:
        var a = batch.column_as_primitive_int32(c)
        for r in range(len(want)):
            if a.is_null(r):
                m.add(at + " row " + String(r) + ": NULL, want " + String(want[r]))
            elif Int64(a.get(r)) != want[r]:
                m.add(
                    at + " row " + String(r) + ": got " + String(a.get(r))
                    + " want " + String(want[r])
                )
    else:
        m.add(at + ": column type " + String(t) + ", want INT64 or INT32")


def check_float_column_bits(
    mut m: Mismatches,
    batch: RecordBatch,
    name: String,
    want: List[Optional[UInt64]],
    label: String,
    skip_rows: List[Int] = List[Int](),
) raises:
    """Column `name` is FLOAT64 and row r holds exactly the bit pattern
    `want[r]`, or is NULL where `want[r]` is None. Rows in `skip_rows` are
    not compared (each caller names the defect that keeps a row out)."""
    var at = label + " " + name
    if batch.num_rows() != len(want):
        m.add(at + ": " + String(batch.num_rows()) + " rows, want " + String(len(want)))
        return
    var c = column_index(batch, name)
    var t = batch.schema.field_arrow_type(c)
    if t != ArrowType.FLOAT64:
        m.add(at + ": column type " + String(t) + ", want FLOAT64")
        return
    var a = batch.column_as_primitive_float64(c)
    for r in range(len(want)):
        if r in skip_rows:
            continue
        var row = at + " row " + String(r)
        if not want[r]:
            if not a.is_null(r):
                m.add(row + ": got " + hex_u64(bitcast[DType.uint64, 1](a.get(r))) + ", want NULL")
            continue
        var w = want[r].value()
        if a.is_null(r):
            m.add(row + ": NULL, want " + hex_u64(w))
            continue
        var g = bitcast[DType.uint64, 1](a.get(r))
        if g != w:
            m.add(
                row + ": got " + hex_u64(g) + " (" + String(a.get(r)) + ") want "
                + hex_u64(w) + " (" + String(bitcast[DType.float64, 1](w)) + ")"
            )
