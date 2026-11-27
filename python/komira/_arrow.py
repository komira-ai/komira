"""The Arrow C stream a query answers, handed to pyarrow.

`komira_sql_stream` fills a caller's `struct ArrowArrayStream` (the Arrow C
Stream Interface); `ArrowArrayStream` is that struct for ctypes.
`import_stream` gives a filled stream to pyarrow at once, through pyarrow's
public import of the Arrow PyCapsule interface
(`pyarrow.RecordBatchReader.from_stream`), and returns the
`pyarrow.RecordBatchReader` that owns it from then on: pyarrow releases the
stream when the reader is closed or collected, and a capsule made later by the
reader's own `__arrow_c_stream__` has pyarrow's destructor.

The capsule made here has no destructor, so no Python code runs when it is
destroyed, which may happen while an exception is propagating. pyarrow moves
the stream out of it when it imports (leaving the struct's `release` NULL),
also when the stream's schema then fails to read. If pyarrow did not take the
stream, `import_stream` releases it itself before it returns or raises: a
stream is released exactly once either way.

`stream_errors()` are the exceptions pyarrow raises for a stream callback that
fails: `ArrowException` for EINVAL, ENOMEM and ENOSYS, and `OSError` for any
other code, EIO among them.

A struct that is collected while it still holds a stream releases it: the
`KeyboardInterrupt` of a Ctrl-C during `komira_sql_stream` (a library older
than ABI 1.6) is raised once the call has returned, which may be after the
struct was filled and before `import_stream` took it; and a query cancelled
under a run handle (`_run.run_sql`) may still have answered, and its stream is
dropped.

`engine_reader` and `stream_address` go the other way, for
`Session.register`: the first reads another producer's stream (pyarrow,
polars, pandas) into the form the library holds, and the second is the
address of the `struct ArrowArrayStream` a stream capsule points at, which
the library drains and releases; the capsule's own destructor then finds it
released.

The stream needs neither the session nor its context (src/so/README.md,
Running SQL): it may be read, or released, after the session is closed. Its
callbacks are code of libkomira, which is never unloaded.
"""

from __future__ import annotations

import ctypes
from collections.abc import Iterator
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import pyarrow


class ArrowArrayStream(ctypes.Structure):
    """`struct ArrowArrayStream` of the Arrow C Stream Interface: four
    callbacks and the producer's private data, as addresses."""

    _fields_ = [
        ("get_schema", ctypes.c_void_p),
        ("get_next", ctypes.c_void_p),
        ("get_last_error", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("private_data", ctypes.c_void_p),
    ]

    def __del__(self) -> None:
        # A stream filled and never handed to pyarrow is released when its
        # struct is collected. That happens when a KeyboardInterrupt, which
        # Python raises once the native call has returned, lands after
        # komira_sql_stream filled the struct and before `import_stream`
        # took it. pyarrow's import, and `import_stream`, leave `release`
        # NULL, so this releases nothing a second time.
        if self.release:
            _Release(self.release)(ctypes.addressof(self))


# The name the Arrow PyCapsule interface gives a stream's capsule. A capsule
# keeps the pointer to its name, so the buffer lives as long as the module.
_NAME = ctypes.create_string_buffer(b"arrow_array_stream")

# `void (*release)(struct ArrowArrayStream *)`.
_Release = ctypes.CFUNCTYPE(None, ctypes.c_void_p)

# A handle of the C API of its own, so the argument types set here change
# nothing for other users of `ctypes.pythonapi`.
_new_capsule = ctypes.PyDLL(None).PyCapsule_New
_new_capsule.restype = ctypes.py_object
_new_capsule.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]


# The pointer a capsule holds, read under its name; a capsule of another name
# raises ValueError (the C API sets the error, and a PyDLL call raises it).
_capsule_pointer = ctypes.PyDLL(None).PyCapsule_GetPointer
_capsule_pointer.restype = ctypes.c_void_p
_capsule_pointer.argtypes = [ctypes.py_object, ctypes.c_char_p]


def stream_address(capsule: object) -> int:
    """The address of the `struct ArrowArrayStream` that `capsule`, what an
    `__arrow_c_stream__` returned, points at. Anything other than a capsule
    named "arrow_array_stream" is a `TypeError`."""
    try:
        address = _capsule_pointer(capsule, _NAME)
    except (TypeError, ValueError):
        address = None
    if not address:
        raise TypeError(
            "__arrow_c_stream__ returned {}, not a PyCapsule named arrow_array_stream".format(type(capsule).__name__)
        )
    return address


class _Given:
    """A producer of the one capsule another producer already returned."""

    def __init__(self, capsule: object) -> None:
        self._capsule = capsule

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        return self._capsule


def engine_reader(source: object) -> pyarrow.RecordBatchReader:
    """A `pyarrow.RecordBatchReader` of the rows of `source`, any object with
    `__arrow_c_stream__`, in the form `komira_register_arrow_stream` holds.
    What `__arrow_c_stream__` returns is checked first (`stream_address`):
    anything but a stream capsule is a `TypeError`.


    - a large or view string column (`large_string`, `string_view`) is cast to
      `string`, and a large or view binary column to `binary`, the values
      unchanged: the engine holds strings with 32-bit offsets, and DuckDB
      reads all of them as one type too (VARCHAR, BLOB). A batch whose strings
      do not fit 32-bit offsets raises pyarrow's error while it is read;
    - a column of a batch that starts past the start of its buffers (a
      sliced table, `to_batches(max_chunksize=...)`) is copied to one that
      starts at 0, which the engine's import reads.

    Every other column is passed as it is, for the engine to take or refuse
    by name. The batches are read from `source` as the engine asks for them."""
    import pyarrow as pa

    capsule = source.__arrow_c_stream__()
    stream_address(capsule)
    reader = pa.RecordBatchReader.from_stream(_Given(capsule))
    schema = pa.schema([field.with_type(_held_type(field.type)) for field in reader.schema], metadata=reader.schema.metadata)

    def batches() -> Iterator[pyarrow.RecordBatch]:
        for batch in reader:
            columns = []
            for column, field in zip(batch.columns, schema):
                if column.type != field.type:
                    column = column.cast(field.type)
                if column.offset != 0:
                    column = pa.concat_arrays([column])
                columns.append(column)
            yield pa.RecordBatch.from_arrays(columns, schema=schema)

    return pa.RecordBatchReader.from_batches(schema, batches())


def _held_type(arrow_type: pyarrow.DataType) -> pyarrow.DataType:
    """The type `engine_reader` gives a column of `arrow_type`."""
    import pyarrow as pa

    if pa.types.is_large_string(arrow_type) or pa.types.is_string_view(arrow_type):
        return pa.string()
    if pa.types.is_large_binary(arrow_type) or pa.types.is_binary_view(arrow_type):
        return pa.binary()
    return arrow_type


def stream_errors() -> tuple[type[BaseException], ...]:
    """The exceptions pyarrow raises for a stream callback that fails."""
    import pyarrow as pa

    return (pa.ArrowException, OSError)


class _Producer:
    """The one-shot PyCapsule producer `import_stream` hands pyarrow: its
    capsule points at `stream`, which it keeps alive, and has no destructor."""

    def __init__(self, stream: ArrowArrayStream) -> None:
        self._stream = stream

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        return _new_capsule(ctypes.addressof(self._stream), _NAME, None)


def import_stream(stream: ArrowArrayStream) -> pyarrow.RecordBatchReader:
    """The `pyarrow.RecordBatchReader` that owns `stream`, a struct the
    producer filled. The stream's schema is read now: a callback that fails
    raises one of `stream_errors()`, after the stream was released."""
    import pyarrow as pa

    try:
        return pa.RecordBatchReader.from_stream(_Producer(stream))
    finally:
        if stream.release:
            _Release(stream.release)(ctypes.addressof(stream))

