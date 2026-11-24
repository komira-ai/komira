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

The stream needs neither the session nor its context (src/so/README.md,
Running SQL): it may be read, or released, after the session is closed. Its
callbacks are code of libkomira, which is never unloaded.
"""

from __future__ import annotations

import ctypes
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

