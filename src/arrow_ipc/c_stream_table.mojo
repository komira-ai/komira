# =============================================================================
# c_stream_table -- an Arrow C stream drained into one Table
# =============================================================================
#
# FFI-BOUNDARY: the caller's `CArrowArrayStream`, taken by reference. The
# struct and everything its callbacks hand out belong to the stream's
# producer; this module reads it, copies every buffer it imports
# (`c_data_stream._drain_stream`) and calls the stream's own `release`
# callback once, on every path out. The one pointer is the stream's own
# address, cast to the untracked origin (`MutUntrackedOrigin`) the C callbacks
# are typed with; it is built here, used for the length of the call and kept
# nowhere. The caller sees only the reference it passed in and the `Table` it
# gets back, which holds no pointer into the producer's memory.
# =============================================================================

from arrow.schema import Schema
from arrow.table import Table

from arrow_ipc.c_data_stream import CArrowArrayStream, _drain_stream


def drain_record_batch_stream_table(
    mut stream: CArrowArrayStream,
) raises -> Table:
    """Drain `stream` into a `Table` of its chunks, in the order the stream
    gave them, with the stream's schema: a stream that ends at once is a
    table of no chunk that still has the schema `get_schema` gave.

    Every buffer is copied, so the table stays valid after the stream is
    released. The stream is released (its own `release` callback is called,
    once) before this returns or raises, unless it was released already.

    Raises:
        `from_arrow_c_stream: stream is already released` when `stream`'s
        `release` is NULL (nothing is called then); a callback's non-zero
        status with the stream's last error text; and
        `UnsupportedArrowCABIType` naming a column type outside the import
        subset (`c_data_stream`).
    """
    var schema = Schema()
    # SAFETY: `stream` is a live reference for the whole call, so its address
    # is valid until this returns. The origin is the untracked one the stream's
    # C callbacks take (`MutUntrackedOrigin`); `_drain_stream` keeps no copy of
    # the pointer, and the struct stays the caller's.
    var ptr = UnsafePointer(to=stream).unsafe_origin_cast[MutUntrackedOrigin]()
    var batches = _drain_stream(ptr, schema)
    return Table.from_chunks(batches^, schema^)
