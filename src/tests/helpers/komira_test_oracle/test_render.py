"""render.py writes komira_plan_harness's canonical text, and canon.py reads it.

What each part proves, and the defect it catches:

- floats: the decimal half is what Mojo's float writer prints. float64 is
  held to CPython's `repr` (shortest round trip, the same layout as Mojo's
  writer: `_format_float.mojo` "writing the decimal following python
  behavior") over 3000 seeded bit patterns and the layout edges, and to
  every vector of Mojo's own float64 formatting test; float32 to the
  vectors of its float32 test; float16 is widened to
  float32 as the harness does. Catches a non-shortest or misrounded digit
  string, a wrong switch to scientific notation, a missing `.0`.
- every flat type: one table, each column a value, a NULL and a value,
  spelt cell by cell by hand (from render.mojo's and test_render.mojo's
  rules). Catches a NULL written as anything but `\\N` (the empty string is
  a value of `ls`, `bin`), a float without its bits, NaN not bare, a wrong
  escape, a decimal with the wrong scale, a temporal value converted.
- header and nullability: the policy lines and escaped names; a column
  declared not nullable that holds a NULL, a key or override naming no
  column, a nested or dictionary type are refused.
- the parser: the grammar refusals of parse.mojo plus the typed cell checks,
  and the normalization of hand-file floats; a hand form is not a fixed
  point, render's output is.
- compare: total, none and keys order; -0.0 against 0.0; bare NaN.
- the datasets: every dataset of datasets.py renders, parses, is a fixed
  point, and its schema line is its `.schema` sidecar's.
"""

import decimal
import random
import struct

import pyarrow as pa

import canon
import datasets
import render
import schema_text

FAILURES = []


def check(cond, what):
    if not cond:
        FAILURES.append(what)


def eq(got, want, what):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (what, got, want))


def refused(fn, needle, what):
    try:
        fn()
    except ValueError as e:
        if needle not in str(e):
            FAILURES.append("%s: refused with %r, which does not say %r" % (what, str(e), needle))
        return
    FAILURES.append("%s: not refused" % what)


# ---------------------------------------------------------------------------
# Floats
# ---------------------------------------------------------------------------


def _bits64(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def _bits32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def test_float64_is_repr():
    rng = random.Random(4242)
    patterns = [rng.getrandbits(64) for _ in range(3000)]
    edges = [5e-324, -5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 0.1, 1 / 3,
             1e15, 1e16, 9999999999999998.0, 1.23e15, 0.0001, 0.00009999, 1e-05, 123.456,
             2.0**53 + 2, 1e22, 1e23, 2.0**-1074 * 3, 1.5, 100.0]
    patterns += [_bits64(x) for x in edges]
    for bits in patterns:
        x = struct.unpack("<d", struct.pack("<Q", bits))[0]
        if x != x or x in (float("inf"), float("-inf")):
            continue
        want = repr(x)
        eq(render.float_decimal_text(bits, 64), want, "float64 decimal of 0x%016X" % bits)


# From Mojo's stdlib test of its float32 formatting (test_format_float.mojo,
# test_float32): the text it prints for Float32(<literal>).
_MOJO_F32 = [
    ("0.5", "0.5"), ("1.23", "1.23"), ("-1.23", "-1.23"), ("42.0", "42.0"),
    ("1.18e-38", "1.18e-38"), ("1e-35", "1e-35"), ("1e35", "1e+35"),
    ("3.4e38", "3.4e+38"), ("1.23e-35", "1.23e-35"), ("1.23e35", "1.23e+35"),
    ("9.9999e14", "999990000000000.0"), ("1e15", "1000000000000000.0"),
    ("0.3333", "0.3333"), ("3.141593", "3.141593"), ("1.9999999", "1.9999999"),
    ("2.0000002", "2.0000002"), ("3.4028234e38", "3.4028235e+38"),
    ("1.1754944e-38", "1.1754944e-38"), ("100000.0", "100000.0"), ("0.000001", "1e-06"),
    ("1.001", "1.001"), ("99999.99", "99999.99"), ("0.0000999", "9.99e-05"),
    ("16777216.0", "16777216.0"),
]


def test_float32_is_mojo():
    for lit, want in _MOJO_F32:
        eq(render.float_decimal_text(_bits32(float(lit)), 32), want, "float32 decimal of %s" % lit)


# From the same file's test_float64, every vector (its two duplicate
# entries once): the text Mojo prints for Float64(<literal>). The seeded
# patterns above hold float64 to CPython's repr; these hold it to Mojo.
_MOJO_F64 = [
    ("0.0", "0.0"), ("-0.0", "-0.0"), ("1.0", "1.0"), ("-1.0", "-1.0"),
    ("42.0", "42.0"), ("0.5", "0.5"), ("-0.5", "-0.5"), ("1.23", "1.23"),
    ("-1.23", "-1.23"), ("1.18e-38", "1.18e-38"), ("-1.18e-38", "-1.18e-38"),
    ("1e-35", "1e-35"), ("-1e-35", "-1e-35"), ("1e35", "1e+35"), ("-1e35", "-1e+35"),
    ("1.23e15", "1230000000000000.0"), ("-1.23e15", "-1230000000000000.0"),
    ("1.23e-15", "1.23e-15"), ("-1.23e-15", "-1.23e-15"), ("1.23e20", "1.23e+20"),
    ("-1.23e20", "-1.23e+20"), ("9.9999e14", "999990000000000.0"),
    ("-9.9999e14", "-999990000000000.0"), ("1e15", "1000000000000000.0"),
    ("-1e15", "-1000000000000000.0"), ("0.3333", "0.3333"), ("-0.3333", "-0.3333"),
    ("0.6666", "0.6666"), ("3.141592653589793", "3.141592653589793"),
    ("-3.141592653589793", "-3.141592653589793"),
    ("1.999999999999999", "1.999999999999999"),
    ("-1.999999999999999", "-1.999999999999999"),
    ("2.0000000000000004", "2.0000000000000004"),
    ("-2.0000000000000004", "-2.0000000000000004"),
    ("2.2250738585072014e-308", "2.2250738585072014e-308"),
    ("-2.2250738585072014e-308", "-2.2250738585072014e-308"),
    ("1.7976931348623157e308", "1.7976931348623157e+308"),
    ("-1.7976931348623157e308", "-1.7976931348623157e+308"), ("1000000.0", "1000000.0"),
    ("0.000001", "1e-06"), ("1.100", "1.1"), ("-1.100", "-1.1"), ("1.0010", "1.001"),
    ("-1.0010", "-1.001"), ("999999.999999", "999999.999999"),
    ("-999999.999999", "-999999.999999"), ("0.000000999999", "9.99999e-07"),
    ("-0.000000999999", "-9.99999e-07"),
]


def test_float64_is_mojo():
    for lit, want in _MOJO_F64:
        eq(render.float_decimal_text(_bits64(float(lit)), 64), want, "float64 decimal of %s" % lit)


def test_float16_widens_to_float32():
    for bits, want in [(0x3C00, "1.0"), (0xC000, "-2.0"), (0x7BFF, "65504.0"), (0x2E66, "0.099975586")]:
        eq(render.float_decimal_text(bits, 16), want, "float16 decimal of 0x%04X" % bits)


def test_float_cells():
    eq(render.float_cell(_bits64(1.5), 64), "1.5|0x3FF8000000000000", "1.5")
    eq(render.float_cell(_bits64(-0.0), 64), "-0.0|0x8000000000000000", "-0.0")
    eq(render.float_cell(0, 64), "0.0|0x0000000000000000", "0.0")
    eq(render.float_cell(0x7FF0000000000000, 64), "inf|0x7FF0000000000000", "inf")
    eq(render.float_cell(0xFFF0000000000000, 64), "-inf|0xFFF0000000000000", "-inf")
    eq(render.float_cell(0x7FF8000000000001, 64), "NaN", "a NaN is bare")
    eq(render.float_cell(0xFFC00000, 32), "NaN", "a float32 NaN is bare")
    eq(render.float_cell(0x3DCCCCCD, 32), "0.1|0x3DCCCCCD", "float32 0.1")
    eq(render.float_cell(0x3C00, 16), "1.0|0x3C00", "float16 1.0")


# ---------------------------------------------------------------------------
# Every flat type
# ---------------------------------------------------------------------------


def _validity_101():
    return pa.py_buffer(bytes([0b101]))


def _from_values(typ, fmt, values):
    """A 3-row array of fixed-width `typ` whose middle row is NULL (its slot
    holds `values[1]`, never rendered)."""
    return pa.Array.from_buffers(typ, 3, [_validity_101(), pa.py_buffer(struct.pack("<" + fmt * 3, *values))])


def _strings(typ, raw):
    """A 3-row string array of raw bytes (not validated: invalid UTF-8
    allowed), the middle row NULL."""
    offsets = [0, len(raw[0]), len(raw[0]), len(raw[0]) + len(raw[2])]
    data = raw[0] + raw[2]
    return pa.Array.from_buffers(typ, 3, [_validity_101(), pa.py_buffer(struct.pack("<4i", *offsets)), pa.py_buffer(data)])


def _every_type_table():
    D = decimal.Decimal
    cols = [
        ("#a[b]", pa.array([True, None, False], pa.bool_())),
        ("i8", pa.array([-128, None, 127], pa.int8())),
        ("i64", pa.array([-(2**63), None, 2**63 - 1], pa.int64())),
        ("u64", pa.array([0, None, 2**64 - 1], pa.uint64())),
        ("f16", _from_values(pa.float16(), "H", [0x3C00, 0x4000, 0xFC00])),
        ("f32", _from_values(pa.float32(), "I", [0x3DCCCCCD, 0x40000000, 0x7FC00000])),
        ("f64", _from_values(pa.float64(), "d", [1.5, 2.0, -0.0])),
        ("d32", pa.array([-1, None, 19000], pa.int32()).view(pa.date32())),
        ("d64", pa.array([86400000, None, -1], pa.int64()).view(pa.date64())),
        ("t32s", pa.array([0, None, 86399], pa.int32()).view(pa.time32("s"))),
        ("t64ns", pa.array([5, None, 6], pa.int64()).view(pa.time64("ns"))),
        ("ts_s", pa.array([-1, None, 1700000000], pa.int64()).view(pa.timestamp("s"))),
        ("ts_ns_tz", pa.array([11, None, 12], pa.int64()).view(pa.timestamp("ns", tz="+05:30"))),
        ("dur_ms", pa.array([-15, None, 16], pa.int64()).view(pa.duration("ms"))),
        ("dec", pa.array([D("123.45"), None, D("-0.05")], pa.decimal128(5, 2))),
        ("dec_big", pa.array([D(2**64), None, D(-(10**38 - 1))], pa.decimal128(38, 0))),
        ("dec256", pa.array([D("1.000"), None, D("-1234567890123456789012345678901234567.890")], pa.decimal256(40, 3))),
        ("s", pa.array(["\\N", None, "a\tb\nc\\d\re"], pa.string())),
        ("s_ctl", pa.array(["x\x01\x7f\u00e9\u4e16\U0001F600", None, "NaN"], pa.string())),
        ("s_raw", _strings(pa.string(), [b"\xff\xc0\xaf", b"", b"\xed\xa0\x80ok"])),
        ("ls", pa.array(["q", None, ""], pa.large_string())),
        ("bin", pa.array([b"", None, b"\x00\xffA"], pa.binary())),
        ("lbin", pa.array([b"\x10", None, b""], pa.large_binary())),
        ("fsb", pa.array([b"\x01\x02", None, b"\xab\xcd"], pa.binary(2))),
        ("nul", pa.array([None, None, None], pa.null())),
    ]
    return pa.table([c for _, c in cols], names=[n for n, _ in cols])


_SCHEMA = "\t".join([
    "\\#a\\[b\\]:bool?", "i8:int8?", "i64:int64?", "u64:uint64?", "f16:float16?", "f32:float32?",
    "f64:float64?", "d32:date32?", "d64:date64?", "t32s:time32_s?", "t64ns:time64_ns?",
    "ts_s:timestamp_s?", "ts_ns_tz:timestamp_ns(+05\\:30)?", "dur_ms:duration_ms?",
    "dec:decimal128(5,2)?", "dec_big:decimal128(38,0)?", "dec256:decimal256(40,3)?",
    "s:string?", "s_ctl:string?", "s_raw:string?", "ls:large_string?", "bin:binary?",
    "lbin:large_binary?", "fsb:fixed_size_binary(2)?", "nul:null?",
])

_ROWS = [
    ["true", "-128", "-9223372036854775808", "0", "1.0|0x3C00", "0.1|0x3DCCCCCD",
     "1.5|0x3FF8000000000000", "-1", "86400000", "0", "5", "-1", "11", "-15", "12345e-2",
     "18446744073709551616e0", "1000e-3", "\\\\N", "x\\x01\\x7f\u00e9\u4e16\U0001F600",
     "\\xff\\xc0\\xaf", "q", "", "10", "0102", "\\N"],
    ["\\N"] * 25,
    ["false", "127", "9223372036854775807", "18446744073709551615", "-inf|0xFC00", "NaN",
     "-0.0|0x8000000000000000", "19000", "-1", "86399", "6", "1700000000", "12", "16", "-5e-2",
     "-99999999999999999999999999999999999999e0", "-1234567890123456789012345678901234567890e-3",
     "a\\tb\\nc\\\\d\\re", "NaN", "\\xed\\xa0\\x80ok", "", "00ff41", "", "abcd", "\\N"],
]

_HEAD = "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"


def test_every_flat_type():
    text = render.render_table(_every_type_table(), render.Policy("total"))
    want = _HEAD + _SCHEMA + "\n" + "".join("\t".join(r) + "\n" for r in _ROWS)
    got_lines, want_lines = text.split("\n"), want.split("\n")
    eq(len(got_lines), len(want_lines), "every-type line count")
    for i, (g, w) in enumerate(zip(got_lines, want_lines)):
        if g != w:
            gc, wc = g.split("\t"), w.split("\t")
            for c, (a, b) in enumerate(zip(gc, wc)):
                eq(a, b, "every-type line %d cell %d" % (i + 1, c + 1))
            eq(len(gc), len(wc), "every-type line %d cell count" % (i + 1))
    parsed = canon.parse(text)
    eq(canon.emit(parsed), text, "render's text is a fixed point of parse and emit")


def test_slices_and_chunks():
    # A sliced array (non-zero offset) and a table of two chunks.
    arr = pa.array([7, None, 8, 9], pa.int64()).slice(1, 3)
    dec = pa.array([decimal.Decimal("1.5"), None, decimal.Decimal("-2.5"), decimal.Decimal("3.0")], pa.decimal128(4, 1)).slice(1, 3)
    t = pa.table({"x": arr, "d": dec})
    t = pa.concat_tables([t.slice(0, 1), t.slice(1, 2)])
    eq(t.column("x").num_chunks, 2, "two chunks")
    want = _HEAD + "x:int64?\td:decimal128(4,1)?\n\\N\t\\N\n8\t-25e-1\n9\t30e-1\n"
    eq(render.render_table(t, render.Policy("total")), want, "slices and chunks")


def test_header_and_nullability():
    t = pa.table({"a:b": pa.array([1, 2], pa.int64()), "f": pa.array([0.5, None], pa.float64())})
    text = render.render_table(t, render.Policy("keys", ["a:b"], "rel=1e-9", {"f": "ulps=2"}), ["derivation: none"], {"a:b"})
    eq(text, "#! komira-plan-conformance v1\n#  order: keys=a\\:b\n#  float: rel=1e-9\n#  float[f]: ulps=2\n"
             "# derivation: none\na\\:b:int64\tf:float64?\n1\t0.5|0x3FE0000000000000\n2\t\\N\n", "header")
    eq(canon.emit(canon.parse(text)), text, "header text is a fixed point")
    refused(lambda: render.render_table(t, render.Policy("none"), (), {"f"}), "declared not nullable and holds 1 NULLs", "not-null with a NULL")
    refused(lambda: render.render_table(t, render.Policy("none"), (), {"g"}), "names no column", "not-null naming no column")
    refused(lambda: render.render_table(t, render.Policy("keys", ["g"])), "names no column", "a key naming no column")
    refused(lambda: render.render_table(t, render.Policy("none", (), "ulps=0", {"a:b": "ulps=1"})), "names a column of type", "override on an int")
    refused(lambda: render.render_table(pa.table({"l": pa.array([[1]])}), render.Policy("none")), "flat", "a list column")
    refused(lambda: render.render_table(pa.table({"d": pa.array(["a"]).dictionary_encode()}), render.Policy("none")), "flat", "a dictionary column")
    refused(lambda: render.render_table(t, render.Policy("none"), ["two\nlines"]), "line end", "a comment with a line end")


# ---------------------------------------------------------------------------
# The parser
# ---------------------------------------------------------------------------


def test_parser_refuses():
    good_schema = "i:int64\tb:bool?\ts:string?\tf:float64?\td:decimal128(5,2)?\tx:binary?\n"
    good_row = "1\ttrue\tabc\t1.5|0x3FF8000000000000\t12345e-2\t00ff\n"
    base = _HEAD + good_schema + good_row
    canon.parse(base)
    cases = [
        ("#! komira-plan-conformance v2\n#  order: total\n#  float: ulps=0\n" + good_schema, "first line"),
        ("#! komira-plan-conformance v1\n#  float: ulps=0\n" + good_schema, "both an order line"),
        (_HEAD + "#  float: ulps=1\n" + good_schema, "a second float line"),
        (_HEAD + "#! other\n" + good_schema, "unknown directive"),
        (_HEAD + "#  orderly\n" + good_schema, "malformed directive"),
        ("#! komira-plan-conformance v1\n#  order: keys=z\n#  float: ulps=0\n" + good_schema, "names 0 columns"),
        (_HEAD + "#  float[i]: ulps=1\n" + good_schema, "names no float column"),
        (base + "1\ttrue\n", "has 2 cells"),
        (base.replace("abc", "a\rc"), "raw CR"),
        (base.replace("abc", "a\\Nc"), "\\N inside a value"),
        (base.replace("abc", "a\\qc"), "unknown escape"),
        (base.replace("abc", "\\x41"), "\\x escape canon does not write"),
        (base.replace("\ttrue\t", "\t\t"), "not true or false"),
        (base.replace("1\ttrue", "01\ttrue"), "canonical form"),
        (base.replace("1\ttrue", "\\N\ttrue"), "not nullable"),
        (base.replace("12345e-2", "12345e-3"), "<unscaled>e-2"),
        (base.replace("12345e-2", "123456e-2"), "outside"),
        (base.replace("00ff", "00FF"), "lower-case hex"),
        (base.replace("1.5|0x3FF8000000000000", "0.1"), "not exactly a float64"),
        (base.replace("1.5|0x3FF8000000000000", "1.5|0x3FF0000000000000"), "does not round"),
        (base.replace("1.5|0x3FF8000000000000", "NaN|0x3FF0000000000000"), "not a NaN"),
        (base.replace("1.5|0x3FF8000000000000", "1.5|0x3FF8"), "hex digits"),
        (base.replace("1.5|0x3FF8000000000000", ""), "not a decimal number"),
        (_HEAD + "l:list<item:int64>?\n[1]\n", "not a flat type"),
        (base[:-1], "line end"),
    ]
    for text, needle in cases:
        refused(lambda text=text: canon.parse(text), needle, "parse refuses (%s)" % needle)


def test_parser_normalizes_hand_floats():
    hand = _HEAD + "f:float64?\n0.0\n-0.0\n1.5\n-2.5\ninf\nNaN\n\\N\n0.1|0x3FB999999999999A\n"
    p = canon.parse(hand)
    eq([r[0] for r in p.rows], ["0.0|0x0000000000000000", "-0.0|0x8000000000000000", "1.5|0x3FF8000000000000",
                                "-2.5|0xC004000000000000", "inf|0x7FF0000000000000", "NaN", "\\N",
                                "0.1|0x3FB999999999999A"], "hand floats normalized")
    check(canon.emit(p) != hand, "a hand file's decimal-only floats are not in canonical form")


# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------


def _text(order, rows, schema="k:int64?\tv:float64?"):
    return canon.parse("#! komira-plan-conformance v1\n#  order: %s\n#  float: ulps=0\n%s\n%s" % (
        order, schema, "".join(r + "\n" for r in rows)))


def test_compare():
    rows = ["1\t0.5", "1\t1.5", "2\t-0.0", "\\N\tNaN"]
    swapped = ["1\t1.5", "1\t0.5", "2\t-0.0", "\\N\tNaN|0x7FF8000000000001"]
    eq(canon.compare(_text("none", rows), _text("none", list(reversed(rows)))), [], "none: any order")
    eq(canon.compare(_text("keys=k", rows), _text("keys=k", swapped)), [], "keys: ties as a multiset, bare NaN any NaN")
    check(canon.compare(_text("keys=k", rows), _text("keys=k", [rows[2], rows[0], rows[1], rows[3]])), "keys: key order out of place")
    check(canon.compare(_text("total", rows), _text("total", swapped)), "total: a swapped tie")
    check(canon.compare(_text("none", rows), _text("none", rows[:3] + ["\\N\t\\N"])), "none: NaN against NULL")
    check(canon.compare(_text("none", rows), _text("none", ["1\t0.5", "1\t1.5", "2\t0.0", "\\N\tNaN"])), "-0.0 against 0.0")
    check(canon.compare(_text("none", rows), _text("none", rows + ["1\t0.5"])), "an extra row")
    check(canon.compare(_text("none", rows), _text("total", rows)), "the policy differs")
    check(canon.compare(_text("none", rows[:3]), _text("none", rows[:3], "k:int64\tv:float64?")), "nullability differs")


# ---------------------------------------------------------------------------
# The datasets
# ---------------------------------------------------------------------------


def test_datasets_render():
    for name in datasets.NAMES:
        ds = datasets.build(name)
        text = render.render_table(ds.table, render.Policy("total"))
        p = canon.parse(text)
        eq(canon.emit(p), text, "dataset %s: fixed point" % name)
        eq(len(p.rows), ds.rows, "dataset %s: rows" % name)
        eq("\t".join(p.schema) + "\n", schema_text.schema_line(ds.schema), "dataset %s: the schema line is the sidecar's" % name)


for name, fn in sorted(globals().items()):
    if name.startswith("test_") and callable(fn):
        fn()

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_render: %d failures" % len(FAILURES))
print("test_render: all passed")
