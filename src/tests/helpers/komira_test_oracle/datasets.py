"""The datasets of the plan conformance oracle: seeded tables built in Python.

Each dataset is a pyarrow table built from a fixed seed (`random.Random` with
a constant integer) and constant special values, with no clock and nothing
read from disk, so every run builds the same table. `build(name)` returns it
with, per column, the formats that cannot carry it exactly (`Dataset.carried`
says which columns a format's file holds). The datasets:

- `types`: the nullable type matrix. Every integer width signed and unsigned;
  float32 and float64 finite (signed zero, subnormals, the extremes) and,
  in their own columns, NaN and the infinities; decimal128 at two precisions;
  strings (empty, Unicode, CSV and escape syntax) and binary (valid UTF-8,
  and bytes that are not UTF-8, in its own column); date32; timestamps at
  each unit with and without a time zone; boolean. Every column holds at
  least one NULL and one value.
- `nulls`: a NULL-heavy table for the three-valued logic, aggregation and
  join shards: every pair of {true, false, NULL} for two booleans, group keys
  with NULLs, strings where the empty string and NULL both occur, and a
  column that is NULL in every row.
- `join_left`, `join_right`: a small join pair whose keys include NULL,
  duplicates, and a key only one side holds.

Every dataset is at most `MAX_ROWS` rows. Timestamps and dates are held as
integers (units since the epoch, days since the epoch).
"""

import datetime
import decimal
import random
import struct

import pyarrow as pa

MAX_ROWS = 10000

# The formats whose files `gen_datasets.py` writes, by id (formats.py writes
# and reads each). A column a format cannot carry exactly is left out of that
# format's file, for the reason its column says.
FORMATS = [
    "parquet",
    "orc",
    "csv",
    "jsonl",
    "arrow_file",
    "arrow_file_lz4",
    "arrow_file_zstd",
    "arrow_stream",
    "arrow_stream_lz4",
    "arrow_stream_zstd",
]

# Why a format leaves a column out. Each was seen with the pinned pyarrow on
# the farm.
NO_UNSIGNED_ORC = "ORC has no unsigned integer type (pyarrow: Unknown or unsupported Arrow type: uint8)"
NO_UNIT_ORC = "pyarrow reads every ORC timestamp back as timestamp[ns], so a seconds, milliseconds or microseconds column comes back in another unit, and its instants before 1677 out of range"
NO_ZONE_ORC = "an ORC instant column holds no zone name; pyarrow reads a zoned column back with tz=UTC"
NO_SECONDS_PARQUET = "Parquet has no seconds unit; pyarrow writes timestamp[s] as milliseconds and reads back timestamp[ms]"
NO_NAN_JSON = "JSON has no NaN or infinity"
NO_RAW_BYTES_JSON = "a JSON string holds Unicode text, not bytes that are not UTF-8"

_SEEDS = {
    "types": 1001,
    "nulls": 1002,
    "join_left": 1003,
    "join_right": 1004,
}

_EPOCH = datetime.date(1970, 1, 1)


def _days(y, m, d):
    return (datetime.date(y, m, d) - _EPOCH).days


class Column:
    def __init__(self, name, typ, values, nullable=True, excluded=None):
        self.name = name
        self.type = typ
        self.values = values
        self.nullable = nullable
        # {format id: reason}
        self.excluded = dict(excluded or {})


class Dataset:
    def __init__(self, name, columns):
        self.name = name
        self.columns = columns
        n = {len(c.values) for c in columns}
        if len(n) != 1:
            raise ValueError("dataset %s: columns of different lengths %s" % (name, sorted(n)))
        self.rows = n.pop()
        if self.rows > MAX_ROWS:
            raise ValueError("dataset %s: %d rows, more than %d" % (name, self.rows, MAX_ROWS))
        self.schema = pa.schema([pa.field(c.name, c.type, nullable=c.nullable) for c in columns])
        self.table = pa.table([pa.array(c.values, c.type) for c in columns], schema=self.schema)

    def carried(self, fmt):
        """The columns `fmt`'s file holds, in the dataset's order."""
        if fmt not in FORMATS:
            raise ValueError("unknown format %s" % fmt)
        return [c.name for c in self.columns if fmt not in c.excluded]


def _fill(rng, specials, draw, n, null_rate):
    """`specials`, then seeded values up to `n` rows, each NULL with
    probability `null_rate`."""
    out = list(specials)
    while len(out) < n:
        out.append(None if rng.random() < null_rate else draw(rng))
    return out


def _f32(x):
    """The float32 nearest `x`, as a Python float (exactly representable)."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def _random_double(rng):
    while True:
        x = struct.unpack("<d", rng.getrandbits(64).to_bytes(8, "little"))[0]
        if x == x and x not in (float("inf"), float("-inf")):
            return x


def _random_single(rng):
    while True:
        x = struct.unpack("<f", rng.getrandbits(32).to_bytes(4, "little"))[0]
        if x == x and x not in (float("inf"), float("-inf")):
            return x


# Wide enough for decimal128's 38 digits: the default context's 28 would
# round (so would unary minus, hence copy_negate below).
_EXACT = decimal.Context(prec=40)


def _scaled(unscaled, scale):
    return decimal.Decimal(unscaled).scaleb(-scale, context=_EXACT)


def _random_decimal(rng, precision, scale):
    bound = 10**precision - 1
    return _scaled(rng.randint(-bound, bound), scale)


_TEXT = "abcxyz ABC019,\"'\n\t\\éß世界\U0001F600"


def _random_text(rng):
    return "".join(rng.choice(_TEXT) for _ in range(rng.randint(0, 12)))


_PER_SECOND = {"s": 1, "ms": 1000, "us": 10**6, "ns": 10**9}


def _timestamp_column(rng, n, unit, tz, excluded):
    per = _PER_SECOND[unit]
    lo = _days(1900, 1, 1) * 86400 * per
    hi = _days(2100, 1, 1) * 86400 * per
    if unit == "ns":
        # The int64 range, less its first 0.854775808 s: pyarrow's CSV and
        # JSON parsers refuse -2**63 ns (1677-09-21 00:12:43.145224192),
        # multiplying the whole seconds before adding the fraction, so the
        # earliest instant every format carries is the next whole second.
        first, last = -9223372036 * 10**9, 2**63 - 1
    else:
        first = _days(1, 1, 1) * 86400 * per
        last = (_days(9999, 12, 31) + 1) * 86400 * per - 1
    specials = [0, -1, 1, first, last, None]
    name = "ts_" + unit + ("_tz" if tz else "")
    return Column(name, pa.timestamp(unit, tz=tz), _fill(rng, specials, lambda r: r.randint(lo, hi), n, 0.125), excluded=excluded)


def _types():
    rng = random.Random(_SEEDS["types"])
    n = 256
    cols = []
    for bits in (8, 16, 32, 64):
        lo, hi = -(2 ** (bits - 1)), 2 ** (bits - 1) - 1
        cols.append(Column("i%d" % bits, getattr(pa, "int%d" % bits)(),
                           _fill(rng, [lo, hi, 0, -1, 1, None], lambda r, lo=lo, hi=hi: r.randint(lo, hi), n, 0.125)))
    for bits in (8, 16, 32, 64):
        hi = 2**bits - 1
        cols.append(Column("u%d" % bits, getattr(pa, "uint%d" % bits)(),
                           _fill(rng, [0, hi, 1, None], lambda r, hi=hi: r.randint(0, hi), n, 0.125),
                           excluded={"orc": NO_UNSIGNED_ORC}))
    f32_max = _f32(3.4028234663852886e38)
    cols.append(Column("f32", pa.float32(), _fill(
        rng, [-0.0, 0.0, 2.0**-149, 2.0**-126, f32_max, -f32_max, _f32(0.1), None], _random_single, n, 0.125)))
    cols.append(Column("f64", pa.float64(), _fill(
        rng, [-0.0, 0.0, 5e-324, -5e-324, 2.2250738585072014e-308, 1.7976931348623157e308,
              -1.7976931348623157e308, 0.1, 1.5, None], _random_double, n, 0.125)))
    special = [float("nan"), float("inf"), float("-inf")]
    for name, typ, draw in (("f32_special", pa.float32(), _random_single), ("f64_special", pa.float64(), _random_double)):
        cols.append(Column(name, typ, _fill(
            rng, special + [-0.0, 1.0, None], lambda r, draw=draw: r.choice(special) if r.random() < 0.5 else draw(r), n, 0.125),
            excluded={"jsonl": NO_NAN_JSON}))
    for p, s in ((9, 2), (38, 10)):
        top = _scaled(10**p - 1, s)
        tiny = _scaled(1, s)
        cols.append(Column("dec_%d_%d" % (p, s), pa.decimal128(p, s), _fill(
            rng, [top, top.copy_negate(), _scaled(0, s), tiny, tiny.copy_negate(), None],
            lambda r, p=p, s=s: _random_decimal(r, p, s), n, 0.125)))
    cols.append(Column("str", pa.string(), _fill(rng, [
        "", " ", "a", "é", "世界", "\U0001F600", "\\N", "NULL", "null", "NaN", "nan",
        "a,b", 'say "hi"', "line\nbreak", "tab\there", "back\\slash", "cr\rhere", "a\x00b",
        " lead", "trail ", None], _random_text, n, 0.125)))
    cols.append(Column("bin", pa.binary(), _fill(
        rng, [b"", b"\x00", b"abc", b'a,"\n', "é".encode("utf-8"), None],
        lambda r: _random_text(r).encode("utf-8"), n, 0.125)))
    cols.append(Column("bin_raw", pa.binary(), _fill(
        rng, [b"\xff", b"\x80\x00", b"\xc0\xaf", b"\xed\xa0\x80", b"\xfe\xff", None],
        lambda r: r.randbytes(r.randint(1, 8)), n, 0.125),
        excluded={"jsonl": NO_RAW_BYTES_JSON}))
    cols.append(Column("date32", pa.date32(), _fill(
        rng, [0, -1, _days(1, 1, 1), _days(9999, 12, 31), None],
        lambda r: r.randint(_days(1900, 1, 1), _days(2100, 1, 1)), n, 0.125)))
    for unit in ("s", "ms", "us", "ns"):
        for tz in (None, "UTC" if unit in ("s", "ms") else "+05:30"):
            excluded = {}
            if unit != "ns":
                excluded["orc"] = NO_UNIT_ORC
            elif tz:
                excluded["orc"] = NO_ZONE_ORC
            if unit == "s":
                excluded["parquet"] = NO_SECONDS_PARQUET
            cols.append(_timestamp_column(rng, n, unit, tz, excluded))
    cols.append(Column("bool", pa.bool_(), _fill(rng, [True, False, None], lambda r: r.random() < 0.5, n, 0.125)))
    return Dataset("types", cols)


_WORDS = ["apple", "Banana", "cherry", "éclair", "fig"]


def _nulls():
    rng = random.Random(_SEEDS["nulls"])
    n = 1000
    tvn = [True, False, None]
    pairs = [(a, b) for a in tvn for b in tvn]
    b1 = [a for a, _ in pairs] + [rng.choice(tvn) for _ in range(n - len(pairs))]
    b2 = [b for _, b in pairs] + [rng.choice(tvn) for _ in range(n - len(pairs))]

    def word(r):
        return "" if r.random() < 0.25 else r.choice(_WORDS)

    return Dataset("nulls", [
        Column("id", pa.int64(), list(range(n)), nullable=False),
        Column("k", pa.int64(), _fill(rng, [1, 1, 1, 2, 2, 2, None, None, None], lambda r: r.randint(1, 3), n, 0.4)),
        Column("b1", pa.bool_(), b1),
        Column("b2", pa.bool_(), b2),
        Column("i32", pa.int32(), _fill(rng, [0, None, -5, 5], lambda r: r.randint(-5, 5), n, 0.6)),
        # Quarters, so every sum is exact in binary floating point.
        Column("v", pa.float64(), _fill(rng, [None, 0.25, -0.5], lambda r: r.randint(-1000, 1000) / 4, n, 0.5)),
        Column("s", pa.string(), _fill(rng, ["", None, "apple"], word, n, 0.4)),
        Column("all_null", pa.int64(), [None] * n),
    ])


def _join(name, n, key_specials, keys, value_column):
    rng = random.Random(_SEEDS[name])
    return Dataset(name, [
        Column("id", pa.int64(), list(range(n)), nullable=False),
        Column("k", pa.int64(), _fill(rng, key_specials, lambda r: r.choice(keys), n, 0.15)),
        Column("k2", pa.string(), _fill(rng, ["", None, "x"], lambda r: r.choice(["x", "y", ""]), n, 0.15)),
        value_column(rng, n),
    ])


def _join_left():
    # 9 is a key only the left side holds; 1 is held twice by the first rows.
    return _join("join_left", 40, [None, 9, 1, 1], list(range(10)),
                 lambda rng, n: Column("lv", pa.int32(), _fill(rng, [None], lambda r: r.randint(-100, 100), n, 0.2)))


def _join_right():
    # 10 is a key only the right side holds; 1 is held twice by the first rows.
    return _join("join_right", 30, [None, 10, 1, 1], list(range(9)) + [10],
                 lambda rng, n: Column("rv", pa.string(), _fill(rng, [None, ""], lambda r: r.choice(_WORDS), n, 0.2)))


_BUILDERS = {
    "types": _types,
    "nulls": _nulls,
    "join_left": _join_left,
    "join_right": _join_right,
}

NAMES = sorted(_BUILDERS)


def build(name):
    return _BUILDERS[name]()
