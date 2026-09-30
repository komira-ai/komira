# =============================================================================
# ArrowCStreamSink — write-side Sink that exports the result as an Arrow C
# Data Interface stream (ArrowArrayStream).
# =============================================================================
#
# The Arrow C Stream Interface (`ArrowArrayStream`) is a *pull* interface — the
# consumer pulls batches via `get_next`. A `Sink` is *push* — the engine pushes
# batches via `accept_batch`. So `ArrowCStreamSink` is `InMemorySink` with a
# different result-retrieval method: `accept_batch` buffers each batch into an
# `ArcPointer`-backed buffer (so the handle is `ImplicitlyCopyable` — the
# `WriteSpec` holds the copy the SINK driver fills, the user holds the copy
# they `.export_stream()` from, same `InMemBuf`-style sharing as `InMemorySink`),
# `finish()` marks done, then `.export_stream(out)` (called AFTER `ctx.run`)
# moves the buffered batches into `komira_core.arrow.c_data_stream`'s
# `build_record_batch_stream`, which builds a `CArrowArrayStream` whose
# `get_next` walks the buffered `Slab[RecordBatch]` one chunk per batch.
#
# The sink buffers, then exports. `build_record_batch_stream` is
# multi-chunk-capable (it takes a `Slab[RecordBatch]` and yields one
# `get_next` chunk per batch), so a batch-streaming materialize path needs no
# surface change — `accept_batch` just appends more batches.
#
# The SDK's `materialize_to_arrow_c_stream(ctx, df^, out)` is sugar over
# `ctx.run` + this sink: it builds an `ArrowCStreamSink`, runs
# `ctx.run(df^.write_to(s))`, then `s.export_stream(out)`
# — no intermediate `InMemorySink` + `.take()` + Slab rebuild. It is the
# recommended convenience; `ctx.run(df^.write_to(ArrowCStreamSink()))` +
# `.export_stream(out)` is the power form.
#
# Pointer rules: `buf: ArcPointer[CStreamBuf]` (the sanctioned shared-ownership
# type — Rust's `Arc<T>`; the SINK drain is post-barrier on the driver thread,
# never cross-thread, so no cross-thread allocator reuse hazard applies —
# the buffer is Arc-owned on the heap with a tracked refcount, not a stack
# pointer). The `out: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]`
# parameter on `.export_stream()` is the C-ABI FFI boundary — the same
# `_StreamOutPtr` alias `materialize_to_arrow_c_stream` uses; the untracked
# origin is confined to the C-ABI export surface (the C consumer allocates
# the struct; we populate it; the `release` callback frees the heap). No
# `unsafe_from_address`; no `UnsafePointer` crossing a NON-FFI module
# boundary.
# =============================================================================

from std.memory import ArcPointer

from komira_core.arrow.schema import RecordBatch, Schema
from komira_core.arrow.table import Table
from komira_core.arrow.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
)
from komira_core.collections.slab import Slab
from komira_core.source.sink import Sink


# The C-ABI export pointer — the SAME alias `materialize_arrow_c_stream.mojo`
# uses (FFI boundary; the consumer allocates the `ArrowArrayStream` struct, we
# populate it, the `release` callback frees the heap).
comptime _StreamOutPtr = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]


# =============================================================================
# CStreamBuf — the Arc-owned buffer behind an ArrowCStreamSink handle.
# =============================================================================


struct CStreamBuf(Movable):
    """The Arc-owned buffer behind an `ArrowCStreamSink` handle.

    Holds the collected `RecordBatch`es plus two guard flags:
      - `finished`: set by `finish()`. `.export_stream()` raises if not set.
      - `exported`: set by `.export_stream()`. A second `.export_stream()`
        raises (the batches were moved out into the C stream).

    The schema (recorded by `init_sink`) is kept so `.export_stream()` can hand
    `build_record_batch_stream` the correct stream schema even when `batches`
    is empty (a zero-row result is a valid empty stream)."""

    var batches: Slab[RecordBatch]
    var schema: Optional[Schema]
    var finished: Bool
    var exported: Bool

    def __init__(out self):
        self.batches = Slab[RecordBatch]()
        self.schema = Optional[Schema](None)
        self.finished = False
        self.exported = False


# =============================================================================
# ArrowCStreamSink — Arc-backed shareable Arrow-C-stream result handle.
# =============================================================================


struct ArrowCStreamSink(Sink, Movable, Copyable, ImplicitlyCopyable):
    """An Arrow C Stream Interface write destination: collects every output
    `RecordBatch` into an `ArcPointer[CStreamBuf]`, exportable afterward via
    `.export_stream(out)` as an `ArrowArrayStream`.

        var s = ArrowCStreamSink()
        ctx.run(df^.write_to(s))                  # fills s
        var c_stream = CArrowArrayStream()
        s.export_stream(<&c_stream as MutUntrackedOrigin ptr>)   # populates it

    (`materialize_to_arrow_c_stream(ctx, df^, out)` is the recommended
    convenience — it does this dance for you; `ctx.run(df^.write_to(...))` +
    `.export_stream(out)` is the power form, e.g. for a multi-sink fan-out
    where one sink is the C stream.)

    `ArrowCStreamSink()` is cheap (one Arc alloc). `.copy()` is a refcount bump
    — the `CStreamBuf` is NOT byte-copied; mutating through one handle (the copy
    the `WriteSpec` holds, which the SINK driver fills) is visible through the
    other (the user's `s`, which they `.export_stream()` from). Declares
    `ImplicitlyCopyable` so `df^.write_to(my_sink)` copies the handle without a
    visible `^` at the call site.

    The SINK drain is post-barrier on the driver thread — the `ArcPointer` is
    mutated single-threaded, never cross-thread from morsel workers.

    Examples:
        ```mojo
        from komira_sdk import ArrowCStreamSink
        # hand the result to a consumer over the Arrow C Data Interface
        var s = ArrowCStreamSink()
        ctx.run(df^.write_to(s))                # fills s with the output batches
        var c_stream = CArrowArrayStream()
        s.export_stream(UnsafePointer(to=c_stream))   # populates the C struct
        ```
    """

    var buf: ArcPointer[CStreamBuf]

    def __init__(out self):
        """Construct a fresh, empty Arrow-C-stream sink (one Arc allocation)."""
        self.buf = ArcPointer[CStreamBuf](CStreamBuf())

    def __init__(out self, *, var buf: ArcPointer[CStreamBuf]):
        """Internal: wrap an existing buffer Arc. Used by `.copy()`."""
        self.buf = buf^

    def copy(self) -> Self:
        """Refcount-bump the buffer Arc — NO byte-copy. Both handles see the
        same `CStreamBuf` (the caller holds one handle, the `WriteSpec` holds a
        copy, `ctx.run` fills via the copy, the caller `.export_stream()`s via
        their handle)."""
        return ArrowCStreamSink(buf=self.buf.copy())

    # --- Sink trait conformance ---

    def init_sink(mut self, schema: Schema) raises:
        """Record the feeding df's output schema (so `.export_stream()` knows
        the stream shape even for a zero-row result)."""
        self.buf[].schema = Optional[Schema](schema.copy())

    def accept_batch(mut self, var rb: RecordBatch) raises:
        """Append `rb` to the shared buffer (the SINK driver calls this on the
        driver thread, post-barrier)."""
        # If init_sink somehow didn't record a schema (degenerate path),
        # capture it from the first batch so `.export_stream()` has one.
        if not self.buf[].schema:
            self.buf[].schema = Optional[Schema](rb.schema.copy())
        self.buf[].batches.append(rb^)

    def finish(mut self) raises:
        """Flip the `finished` guard — `.export_stream()` is now allowed."""
        self.buf[].finished = True

    def is_text_output_sink(self) -> Bool:
        """Explicit False — ArrowCStreamSink emits binary Arrow IPC chunks
        to a C consumer. Never needs the per-column UTF-8 cast."""
        return False

    # --- ArrowCStreamSink-specific result retrieval (NOT on the Sink trait) ---

    def export_stream(mut self, out_stream: _StreamOutPtr) raises:
        """Move the collected batches out of the shared buffer and populate the
        caller-allocated `ArrowArrayStream` (`out_stream`) with a
        `CArrowArrayStream` whose `get_next` walks them (one chunk per batch,
        then end-of-stream).

        The consumer owns `out_stream` after this returns and MUST invoke its
        `release` callback exactly once (Mojo-side:
        `komira_core.arrow.c_data_stream.release_c_stream(out_stream)`; a C
        consumer: `out_stream->release(out_stream)`) — that frees the batches'
        heap.

        TWO distinct guards:
          - `finished` — set by `finish()` (called by the `ctx.run` tail loop).
            `.export_stream()` before any `ctx.run` (or after a `ctx.run` that
            *raised* before reaching `finish()` for this sink) → raise.
          - `exported` — set by `export_stream()`. A second `.export_stream()`
            → raise (the batches were moved out into the first stream).

        Raises:
            - If `out_stream` is NULL.
            - If `finished` is not set / `exported` is already set.
            - `UnsupportedArrowCABIType` if the result schema has a column
              outside the supported C-ABI type subset (see `c_data_stream.mojo`)."""
        if Int(out_stream) == 0:
            raise Error("ArrowCStreamSink.export_stream: out_stream is NULL")
        if not self.buf[].finished:
            raise Error(
                "ArrowCStreamSink.export_stream(): this sink was never finished"
                " — call ctx.run(... write_to(this_sink) ...) first, and check"
                " it did not raise"
            )
        if self.buf[].exported:
            raise Error(
                "ArrowCStreamSink.export_stream(): already exported — the"
                " batches were moved out into a prior ArrowArrayStream"
            )
        self.buf[].exported = True
        # Move the batches out of the shared buffer (no `^`-move through an
        # `ArcPointer` deref — a fresh Slab + the `Slab.extend(mut src)`
        # overload, which moves all elements IN ORDER and empties the buffer).
        var batches = Slab[RecordBatch]()
        batches.extend(self.buf[].batches)
        # The stream schema: the `init_sink` / first-batch schema if present,
        # else an empty schema (a zero-column / never-fed sink — degenerate;
        # `build_record_batch_stream` handles a 0-batch Slab).
        var schema: Schema
        if self.buf[].schema:
            schema = self.buf[].schema.value().copy()
        elif len(batches) > 0:
            schema = batches[0].schema.copy()
        else:
            schema = Schema()
        build_record_batch_stream(batches^, schema^, out_stream)


# =============================================================================
# export_table_as_c_stream — the ONE-RESULT-TYPE egress.
# =============================================================================


def export_table_as_c_stream(var table: Table, out_stream: _StreamOutPtr) raises:
    """Export EVERY chunk of `table` as one `ArrowArrayStream`, in row order.

    An `ArrowArrayStream` IS a sequence of batches — `build_record_batch_stream`
    yields one `get_next` chunk per batch — so this function does NOT
    concatenate and must never be changed to. Reaching `to_record_batch()`
    here would buy one flat buffer the consumer immediately re-splits, and on
    a divergent-dictionary result it would do so QUADRATICALLY in the chunk
    count (`Table.to_record_batch`'s own warning).

    It takes a `Table`, not a `List[RecordBatch]`: the result is one
    collection, and the list form loses the SCHEMA.

    THE SCHEMA COMES FROM THE TABLE, NOT FROM CHUNK 0. A 0-chunk table has no
    chunk to read a schema off, and `Table` carries the driver's own output
    schema because an empty result still has a schema. Feeding the chunks
    alone would export a zero-row answer as a schema-less stream, which makes
    a downstream Project raise `Schema.column_index: no field named '<k>'`
    rather than return no rows.

    Args:
        table: The result. Consumed — its chunks are MOVED into the stream.
        out_stream: The caller-allocated `ArrowArrayStream` to populate. The
            consumer owns it afterward and MUST release it exactly once.

    Raises:
        If `out_stream` is NULL, or `UnsupportedArrowCABIType` when the schema
        holds a column outside the C-ABI subset — both from `export_stream`.
    """
    var sink = ArrowCStreamSink()
    # BEFORE the drain: `take_chunks()` empties the chunk list but KEEPS the
    # schema, so the order is not load-bearing — stating it here is.
    sink.init_sink(table.schema())
    var chunks = table.take_chunks()
    var n = len(chunks)
    # FORWARD DRAIN, ONE PASS. `take_chunks()` hands back a `Slab`, so the
    # batches are moved out front to back with no reversal and no O(N^2)
    # front removal.
    #
    # THE DRAIN VERB IS `replace(i, RecordBatch())`, NOT `Slab`'s
    # `take_slot_unchecked(i)` + `set_len(0)`. The difference is EXCEPTION
    # SAFETY, because THE LOOP BODY BELOW RAISES. `take_slot_unchecked` moves a
    # slot out WITHOUT adjusting the length -- the length fix is the caller's
    # `set_len(0)` afterwards -- so a raise part-way through unwinds with the
    # slab still claiming all N slots are live, and its destructor then
    # `destroy_pointee`s the ones already moved out: a DOUBLE FREE. `replace`
    # swaps a default `RecordBatch` into the slot it empties, so every slot is
    # initialised at every point and the destructor is sound on any unwind
    # path.
    #
    # Not `take_at(0)` in a loop either -- that shifts the tail on every call
    # (O(N^2)).
    for i in range(n):
        sink.accept_batch(chunks.replace(i, RecordBatch()))
    sink.finish()
    sink.export_stream(out_stream)
