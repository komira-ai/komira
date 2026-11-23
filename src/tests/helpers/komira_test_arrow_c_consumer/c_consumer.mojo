# =============================================================================
# FFI-BOUNDARY: hand an exported Arrow C stream to the C consumer of
# native/arrow_c_consumer.c and return what it read.
# =============================================================================
# `read_in_c(batches, schema, mode)` allocates one `struct ArrowArrayStream`,
# fills it with `arrow_ipc.c_data_stream.build_record_batch_stream` (which takes
# the batches and the schema), and passes its address to
# `komira_test_arrow_c_consume`. From then on the C consumer owns the stream,
# as a foreign host would: it calls the stream's callbacks and every `release`,
# twice each (see the C file's header). The C writes its text into a buffer
# this module owns and reads back with its length.
#
# Who frees what: the stream struct's memory is this module's, freed here after
# the call; what the stream and its chunks own is freed by their release
# callbacks, which the C calls. If the C returned with the stream still live
# (it failed before releasing it), this module releases it so a failing test
# leaks nothing. The text buffer is a `List[UInt8]` this module owns.
#
# The public API takes and returns values only.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc

from arrow.schema import RecordBatch, Schema
from arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    release_c_stream,
)
from containers.slab import Slab

comptime DRAIN: Int32 = 0
"""Read the schema and every chunk; release the stream before reading them."""
comptime UNREAD: Int32 = 1
"""Release the stream without calling any other callback."""
comptime FIRST_CHUNK: Int32 = 2
"""Read the schema and one chunk; release the stream before reading it."""

comptime _TEXT_CAP = 1 << 20


def read_in_c(
    var batches: Slab[RecordBatch], var schema: Schema, mode: Int32 = DRAIN
) raises -> String:
    """Export `batches` under `schema` as an Arrow C stream, let the C
    consumer read it in `mode`, and return its text. Raises with the C
    consumer's reason when it refused the stream."""
    # SAFETY: one `CArrowArrayStream`, allocated here and freed below on every
    # path; its address is the only pointer the C receives besides the text
    # buffer's, and the C keeps neither after the call.
    var stream = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    stream.unsafe_write(CArrowArrayStream())
    try:
        build_record_batch_stream(batches^, schema^, stream)
    except e:
        stream.free()
        raise e^
    var text = List[UInt8](length=_TEXT_CAP, fill=0)
    var text_len = Int64(0)
    # SAFETY: `text` holds `_TEXT_CAP` bytes for the call and `text_len` is a
    # live local; the C writes at most `_TEXT_CAP` bytes and the length, and
    # keeps neither pointer.
    var rc = external_call["komira_test_arrow_c_consume", Int32](
        stream,
        mode,
        text.unsafe_ptr(),
        Int64(_TEXT_CAP),
        UnsafePointer(to=text_len),
    )
    # A consumer that failed part way may return with the stream live.
    if not stream[].is_released():
        release_c_stream(stream)
    stream.free()
    text.resize(Int(text_len), 0)
    var out = String(unsafe_from_utf8=Span(text))
    if rc != 0:
        raise Error("the C consumer refused the stream: " + out)
    return out^
