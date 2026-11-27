"""`komira.read_csv(path, chunksize=n)` and `iterator=True`: a CSV file read as
`pyarrow.Table` chunks, each read from the file when it is asked for.

pandas spells this loop `for chunk in pd.read_csv(path, chunksize=n)` (pandas
documentation, IO tools, "Iterating through files chunk by chunk"); its reader
is `TextFileReader`, and `TextFileReader` here has the same surface: iterating
yields chunks of `chunksize` rows, `get_chunk(size)` returns the next `size`
rows, both raise `StopIteration` at the end of the file, `close()` releases
the file, and the reader is a context manager.

The engine answers a plan whole (`komira_plan_stream` computes the answer
before it returns the stream, src/so/README.md), and a komira `DataFrame` is a
plan over files that holds no rows. So a chunk is neither: the reader reads
the file itself, with pyarrow's streaming CSV reader, and gives each chunk as
the `pyarrow.Table` that `Result.to_arrow()` would give for those rows.

The column names and types are the ones `read_csv` infers through the engine
from the start of the file (`komira_csv_binding`); the reader never infers
again. Every cell is read as text in the engine's dialect (src/csv: the
delimiter given, `"` quotes with a doubled quote inside, quoted line breaks,
no trimming, a UTF-8 BOM skipped, blank lines skipped when there are two or
more columns) and then converted to its column's type by the engine's rules:

- NULL is a cell, quoted or not, that is exactly one of "", NULL, NA, NaN,
  null, whatever the column's type;
- int64 is an optional sign and ASCII digits; float64 adds one `.` and an
  `e`/`E` exponent; date32 is exactly `YYYY-MM-DD` of a real day; bool is one
  of true, TRUE, T, 1, yes, Y or false, FALSE, F, 0, no, N;
- a cell that does not fit its column's type is NULL, as the engine reads it:
  a later chunk whose values disagree with the types of the start of the file
  has NULLs there, and no error. Three departures from the engine's reader:
  an integer outside int64 is NULL (the engine's wraps), a date of the year
  0000 is NULL (Python has no such date), and a float is the correctly
  rounded double (the engine's can differ in the last bit).

A row pyarrow cannot split, such as one with another number of fields than
the header has, raises `KomiraError` ("read_csv: reading '<path>' stopped: "
and pyarrow's message); it and any other exception while a block is read
close the reader, and the rows read and not handed out are dropped. The file is read in blocks of
`_BLOCK_BYTES`; a block's rows are parsed when the reader first needs one of
them, so that error comes from the call that reads the block holding the row,
and every chunk whose rows all lie before that block arrives first.

Chunk sizes: the blocks give batches of any size, and the reader re-slices
them. It keeps the rows read and not yet handed out; a chunk of `n` rows reads
blocks until it holds `n` rows or the file ends, then hands out the first `n`
(slices, no copy) and keeps the rest. Every chunk has exactly `n` rows except
the last, which has the rest (one to `n`); a file of no data row gives no
chunk.
"""

from __future__ import annotations

import collections
from typing import TYPE_CHECKING

from ._errors import KomiraError

if TYPE_CHECKING:
    import pyarrow

# The bytes the streaming reader parses at a time.
_BLOCK_BYTES = 1 << 20

_NULLS = ["", "NULL", "NA", "NaN", "null"]
_TRUE = ["true", "TRUE", "T", "1", "yes", "Y"]
_FALSE = ["false", "FALSE", "F", "0", "no", "N"]
_INT = r"^[+-]?[0-9]+$"
_FLOAT = r"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"
# YYYY-MM-DD of a year 0001 to 9999: Python's and so a chunk's dates.
_DATE = r"^(?:[0-9]{3}[1-9]|[0-9]{2}[1-9][0-9]|[0-9][1-9][0-9]{2}|[1-9][0-9]{3})-[0-9]{2}-[0-9]{2}$"


def check_size(value: object, what: str, least: int) -> int | None:
    """`value` as a row count of at least `least`, or None for None, as pandas
    checks `chunksize` (least 1) and `nrows`: an int, or a float of an
    integer value; anything else, a bool among them, raises pandas'
    `ValueError: '<what>' must be an integer >=<least>`."""
    if value is None:
        return None
    message = f"'{what}' must be an integer >={least}"
    if isinstance(value, float):
        if not value.is_integer():
            raise ValueError(message)
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or value < least:
        raise ValueError(message)
    return value


class TextFileReader:
    """The chunks of a CSV file, read as they are asked for: the reader
    `komira.read_csv(path, chunksize=n)` and `komira.read_csv(path,
    iterator=True)` return. Each chunk is a `pyarrow.Table` of the columns
    `read_csv` infers, read from the file when it is asked for.

    Iterating yields chunks of `chunksize` rows, the last one the rest of the
    file (the whole file in one chunk when `chunksize` is None), and
    `get_chunk(size)` returns the next `size` rows. Both raise
    `StopIteration` at the end of the file, and again at every later call.
    Reaching the end releases the file; `close()` and leaving a `with` block
    release it too, and a reader closed so raises `ValueError` when asked for
    a chunk."""

    __slots__ = ("chunksize", "_path", "_file", "_reader", "_schema", "_types", "_pending", "_rows", "_end", "_closed", "_open")

    def __init__(self, path: str, columns: list[tuple[str, str]], sep: str, header: bool, chunksize: int | None):
        import pyarrow as pa

        self.chunksize = chunksize
        self._path = path
        names = [name for name, _ in columns]
        self._types = [pa.type_for_alias(dtype) for _, dtype in columns]
        self._schema = pa.schema([pa.field(name, t) for name, t in zip(names, self._types)])
        self._pending: collections.deque[pyarrow.RecordBatch] = collections.deque()
        self._rows = 0
        self._end = False
        self._closed = False
        self._reader = None
        self._open = (names, sep, header)
        self._file = open(path, "rb")  # noqa: SIM115 -- held until close()

    def __iter__(self) -> TextFileReader:
        return self

    def __next__(self) -> pyarrow.Table:
        return self.get_chunk()

    def __enter__(self) -> TextFileReader:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        """Releases the file and the rows read and not handed out; the reader
        then refuses every chunk. Calling it again does nothing."""
        self._closed = True
        self._end = True
        self._pending.clear()
        self._rows = 0
        self._release()

    def _release(self) -> None:
        """Releases the file; the rows read and not handed out stay."""
        if self._reader is not None:
            self._reader.close()
            self._reader = None
        self._file.close()

    def get_chunk(self, size: int | None = None) -> pyarrow.Table:
        """The next `size` rows of the file as a `pyarrow.Table`, fewer at the
        end of the file; `size` None is `chunksize`, and the rest of the file
        when that is None too. `size` 0 is a table of no rows, also at the
        end. Raises `StopIteration` when no row is left, and `ValueError` for
        a closed reader or a `size` that is not a count of rows."""
        size = check_size(size, "size", 0)
        if size is None:
            size = self.chunksize
        if self._closed:
            raise ValueError(f"read_csv: the reader of '{self._path}' is closed")
        while (size is None or self._rows < size) and not self._end:
            self._read_block()
        if self._end:
            self._release()
        if self._rows == 0 and size != 0:
            raise StopIteration
        return self._take(self._rows if size is None else min(size, self._rows))

    def _read_block(self) -> None:
        import pyarrow as pa

        try:
            if self._reader is None:
                self._reader = _open_csv(self._file, *self._open)
            try:
                batch = self._reader.read_next_batch()
            except StopIteration:
                self._end = True
                return
            if batch.num_rows:
                self._pending.append(self._convert(batch))
                self._rows += batch.num_rows
        except pa.ArrowInvalid as e:
            self.close()
            raise self._error(e) from e
        except BaseException:
            # Any other failure, a Ctrl-C among them, releases the file too.
            self.close()
            raise

    def _take(self, n: int) -> pyarrow.Table:
        import pyarrow as pa

        out = []
        left = n
        while left:
            batch = self._pending[0]
            if batch.num_rows <= left:
                out.append(self._pending.popleft())
                left -= batch.num_rows
            else:
                out.append(batch.slice(0, left))
                self._pending[0] = batch.slice(left)
                left = 0
        self._rows -= n
        return pa.Table.from_batches(out, schema=self._schema)

    def _convert(self, batch: pyarrow.RecordBatch) -> pyarrow.RecordBatch:
        import pyarrow as pa

        columns = [_typed(batch.column(i), t) for i, t in enumerate(self._types)]
        return pa.RecordBatch.from_arrays(columns, schema=self._schema)

    def _error(self, e: Exception) -> KomiraError:
        return KomiraError(f"read_csv: reading '{self._path}' stopped: {e}")


def _open_csv(file, names: list[str], sep: str, header: bool) -> pyarrow.RecordBatchReader:
    """pyarrow's streaming reader of `file` in the engine's dialect, every
    column as text; it reads one block at a time, on the calling thread."""
    import pyarrow as pa
    import pyarrow.csv as pcsv

    return pcsv.open_csv(
        file,
        read_options=pcsv.ReadOptions(
            column_names=names, skip_rows=1 if header else 0, block_size=_BLOCK_BYTES, use_threads=False
        ),
        parse_options=pcsv.ParseOptions(
            delimiter=sep,
            quote_char='"',
            double_quote=True,
            escape_char=False,
            newlines_in_values=True,
            ignore_empty_lines=len(names) >= 2,
        ),
        convert_options=pcsv.ConvertOptions(
            column_types={name: pa.string() for name in names},
            null_values=_NULLS,
            strings_can_be_null=True,
            quoted_strings_can_be_null=True,
        ),
    )


def _typed(text: pyarrow.Array, target: pyarrow.DataType) -> pyarrow.Array:
    """The string column `text` (NULL tokens already NULL) as the engine
    reads it into `target`: a cell that does not fit is NULL."""
    import pyarrow as pa
    import pyarrow.compute as pc

    if pa.types.is_boolean(target):
        false = pc.if_else(pc.is_in(text, value_set=pa.array(_FALSE)), pa.scalar(False), pa.scalar(None, pa.bool_()))
        return pc.if_else(pc.is_in(text, value_set=pa.array(_TRUE)), pa.scalar(True), false)
    if pa.types.is_integer(target):
        return _parsed(text, _INT, target, _int_cell)
    if pa.types.is_floating(target):
        return _parsed(text, _FLOAT, target, float)
    if pa.types.is_date(target):
        return _parsed(text, _DATE, target, _date_cell)
    return text.cast(target)


def _parsed(text, pattern, target, cell):
    """The cells of `text` that match `pattern`, cast to `target`, NULL for
    the others. When Arrow's cast refuses a matching cell (an integer outside
    int64, a day that is not in the calendar), each cell is converted by
    `cell` instead (Python's `float` for a float, whose forms `5.` and
    `.5` Arrow may refuse), which answers None for one that does not fit."""
    import pyarrow as pa
    import pyarrow.compute as pc

    fits = pc.match_substring_regex(text, pattern)
    text = pc.if_else(fits, pc.replace_substring_regex(text, r"^\+", ""), pa.scalar(None, pa.string()))
    try:
        return text.cast(target)
    except pa.ArrowInvalid:
        return pa.array([None if s is None else cell(s) for s in text.to_pylist()], type=target)


def _int_cell(s: str) -> int | None:
    v = int(s)
    return v if -(1 << 63) <= v < (1 << 63) else None


def _date_cell(s: str) -> object:
    import datetime

    try:
        return datetime.date.fromisoformat(s)
    except ValueError:
        return None
