"""Write a table in each format of the oracle's datasets, and read it back.

Parquet, ORC and Arrow IPC are written by pyarrow; CSV and JSON Lines by the
plain Python here, so their text is exactly what this file says:

- CSV: a header line of the column names, then one line per row, LF line
  ends. NULL is an empty unquoted field; every string and binary value is
  quoted (a `"` in it doubled), so the empty string is `""` and never NULL.
  Binary values are their raw bytes. Floats are Python's shortest round-trip
  text (`nan`, `inf`, `-inf`, `-0.0`); decimals fixed-point at their scale;
  booleans `true` and `false`; dates `YYYY-MM-DD`; timestamps
  `YYYY-MM-DD HH:MM:SS` with as many fraction digits as the unit has (none,
  3, 6, 9), and, for a column with a time zone, the UTC instant followed by
  `Z`.
- JSON Lines: one object per row, keys in column order, `null` for NULL,
  UTF-8 (not ASCII-escaped). Integers and floats are JSON numbers, decimals
  strings in fixed point, binary the string its UTF-8 bytes spell, dates and
  timestamps strings as in CSV.

Readers take the dataset's schema: CSV and JSON carry no types, so the
reader declares each column's type, as a scan with a declared schema does.
"""

import datetime
import json

import pyarrow as pa
import pyarrow.csv as pcsv
import pyarrow.ipc as ipc
import pyarrow.json as pjson
import pyarrow.orc as porc
import pyarrow.parquet as pq

# Format id -> file suffix (`<dataset>.<suffix>`).
SUFFIX = {
    "parquet": "parquet",
    "orc": "orc",
    "csv": "csv",
    "jsonl": "jsonl",
    "arrow_file": "arrow",
    "arrow_file_lz4": "lz4.arrow",
    "arrow_file_zstd": "zstd.arrow",
    "arrow_stream": "arrows",
    "arrow_stream_lz4": "lz4.arrows",
    "arrow_stream_zstd": "zstd.arrows",
}

# The formats whose files keep each field's nullability.
KEEPS_NULLABILITY = {f for f in SUFFIX if f == "parquet" or f.startswith("arrow_")}

# Rows per Parquet row group and per IPC record batch, so a reader of a
# dataset larger than this crosses a boundary.
CHUNK_ROWS = 100

_IPC = {
    "arrow_file": ("file", None),
    "arrow_file_lz4": ("file", "lz4"),
    "arrow_file_zstd": ("file", "zstd"),
    "arrow_stream": ("stream", None),
    "arrow_stream_lz4": ("stream", "lz4"),
    "arrow_stream_zstd": ("stream", "zstd"),
}

_EPOCH = datetime.date(1970, 1, 1)
_PER_SECOND = {"s": 1, "ms": 1000, "us": 10**6, "ns": 10**9}
_DIGITS = {"s": 0, "ms": 3, "us": 6, "ns": 9}


def date_text(days):
    return (_EPOCH + datetime.timedelta(days=days)).isoformat()


def timestamp_text(value, unit, tz):
    secs, frac = divmod(value, _PER_SECOND[unit])
    days, sod = divmod(secs, 86400)
    text = "%s %02d:%02d:%02d" % (date_text(days), sod // 3600, sod // 60 % 60, sod % 60)
    if _DIGITS[unit]:
        text += ".%0*d" % (_DIGITS[unit], frac)
    return text + ("Z" if tz else "")


def _python_values(column):
    """The column's values as Python objects; temporal values as integers
    (to_pylist would need a time-zone database for a zoned timestamp)."""
    t = column.type
    if pa.types.is_timestamp(t):
        return column.cast(pa.int64()).to_pylist()
    if pa.types.is_date32(t):
        return column.cast(pa.int32()).to_pylist()
    return column.to_pylist()


def _text(value, t):
    """The CSV and JSON text of a temporal or decimal value."""
    if pa.types.is_date32(t):
        return date_text(value)
    if pa.types.is_timestamp(t):
        return timestamp_text(value, t.unit, t.tz)
    if pa.types.is_decimal(t):
        return format(value, "f")
    raise TypeError(t)


def _csv_quote(raw):
    return b'"' + raw.replace(b'"', b'""') + b'"'


def _csv_cell(value, t):
    if value is None:
        return b""
    if pa.types.is_string(t):
        return _csv_quote(value.encode("utf-8"))
    if pa.types.is_binary(t):
        return _csv_quote(value)
    if pa.types.is_boolean(t):
        return b"true" if value else b"false"
    if pa.types.is_floating(t):
        return repr(value).encode("ascii")
    if pa.types.is_integer(t):
        return str(value).encode("ascii")
    return _text(value, t).encode("ascii")


def write_csv(table, path):
    types = [f.type for f in table.schema]
    columns = [_python_values(c) for c in table.columns]
    with open(path, "wb") as f:
        f.write(",".join(table.column_names).encode("utf-8") + b"\n")
        for row in range(table.num_rows):
            f.write(b",".join(_csv_cell(columns[c][row], types[c]) for c in range(len(types))) + b"\n")


def _json_value(value, t):
    if value is None or pa.types.is_boolean(t) or pa.types.is_integer(t) or pa.types.is_floating(t):
        return value
    if pa.types.is_string(t):
        return value
    if pa.types.is_binary(t):
        return value.decode("utf-8")
    return _text(value, t)


def write_jsonl(table, path):
    names = table.column_names
    types = [f.type for f in table.schema]
    columns = [_python_values(c) for c in table.columns]
    with open(path, "wb") as f:
        for row in range(table.num_rows):
            obj = {names[c]: _json_value(columns[c][row], types[c]) for c in range(len(names))}
            f.write(json.dumps(obj, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8") + b"\n")


def write(fmt, table, path):
    if fmt == "parquet":
        pq.write_table(table, path, row_group_size=CHUNK_ROWS, compression="snappy")
    elif fmt == "orc":
        porc.write_table(table, path)
    elif fmt == "csv":
        write_csv(table, path)
    elif fmt == "jsonl":
        write_jsonl(table, path)
    elif fmt in _IPC:
        kind, codec = _IPC[fmt]
        opts = ipc.IpcWriteOptions(compression=codec)
        new = ipc.new_file if kind == "file" else ipc.new_stream
        with new(path, table.schema, options=opts) as w:
            for batch in table.to_batches(max_chunksize=CHUNK_ROWS):
                w.write_batch(batch)
    else:
        raise ValueError("unknown format %s" % fmt)


def ipc_codec(fmt):
    """The body compression an IPC format is written with (None, lz4, zstd)."""
    return _IPC[fmt][1]


def read(fmt, path, schema):
    """The table pyarrow decodes from `path`; `schema` declares the column
    types for CSV and JSON Lines."""
    if fmt == "parquet":
        return pq.read_table(path)
    if fmt == "orc":
        return porc.read_table(path)
    if fmt == "csv":
        return pcsv.read_csv(
            path,
            parse_options=pcsv.ParseOptions(newlines_in_values=True),
            convert_options=pcsv.ConvertOptions(
                column_types={f.name: f.type for f in schema},
                null_values=[""],
                strings_can_be_null=True,
                quoted_strings_can_be_null=False,
            ),
        )
    if fmt == "jsonl":
        # pyarrow's JSON reader takes a date32 as a number of days only, so
        # dates are read as text and parsed by the cast.
        declared = pa.schema([pa.field(f.name, pa.string() if pa.types.is_date32(f.type) else f.type) for f in schema])
        got = pjson.read_json(path, parse_options=pjson.ParseOptions(explicit_schema=declared, unexpected_field_behavior="error"))
        return pa.table(
            [got.column(f.name).cast(f.type) if pa.types.is_date32(f.type) else got.column(f.name) for f in schema],
            names=[f.name for f in schema],
        )
    if fmt in _IPC:
        if _IPC[fmt][0] == "file":
            return ipc.open_file(path).read_all()
        return ipc.open_stream(path).read_all()
    raise ValueError("unknown format %s" % fmt)
