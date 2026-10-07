# =============================================================================
# Sink trait + InMemorySink — write-side dual of SourceLike / InMemorySource.
# =============================================================================
#
# `Sink` is the mirror image of `SourceLike` (`source_like.mojo`) on the write
# side: every concrete destination (in-memory buffer, Parquet file, Arrow C
# stream, CSV) implements `init_sink(schema)` / `accept_batch(var rb)` /
# `finish()`. Lives here in `komira_scan_source`.source` next to `SourceLike` —
# `ParquetSink` does NOT (it needs the Parquet writer, which the core packages
# must not depend on), so the concrete `ParquetSink` lives in the SDK layer.
# `InMemorySink` only needs `Slab` / `RecordBatch` / `Schema` / `ArcPointer`
# (all in the core packages), so it lives here.
#
# Mojo-mechanics notes:
#   - `trait Sink(Movable, Deinitable)` requires ONLY `Movable` —
#     a `Copyable`-too implementor (`InMemorySink`) is fine (extra
#     conformance), and a `Movable`-only implementor (`ParquetSink`) conforms
#     too.
#   - `InMemorySink` declares `ImplicitlyCopyable` (not just `Copyable`) so
#     `df^.write_to(my_sink)` copies the Arc handle WITHOUT a visible `^` at
#     the call site (`Copyable` alone is RED at a `var`-pack call site —
#     `error: value cannot be implicitly copied`).
#   - `.take()` cannot do `var out = self.buf[].batches^` (`error: expression
#     does not designate a value with an origin` — no `^`-move through an
#     `ArcPointer` deref). The working shape: a new `Slab[RecordBatch]` + the
#     `Slab.extend(mut src)` overload (moves all elements from `src` into the
#     new slab in order and empties `src` in place).
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab


trait Sink(Movable, Deinitable):
    """A write-side destination. Mirrors `SourceLike` on the read side.

    Every concrete sink (`InMemorySink`, `ParquetSink`, future
    `ArrowCStreamSink` / `CsvSink`) implements:
      - `init_sink(schema)` — called once, on the driver thread, strictly
        before any `accept_batch`. `schema` is the feeding DataFrame's
        resolved OUTPUT schema (post-projection / post-agg, NOT the input
        schema).
      - `accept_batch(var rb)` — called once per output `RecordBatch`, in
        order, on the driver thread (post-barrier). Takes the batch by `^`
        (move); when this sink is one of K>1 sinks attached to one
        DataFrame, the driver did `copy_batch` for the first K-1 and a
        move-take by the Kth before calling, so this sink owns its batch.
      - `finish()` — called once, after the last batch. Returns nothing
        uniformly — sink-specific RESULT retrieval is NOT through the trait
        (`InMemorySink.take()` is an `InMemorySink`-only method; `ParquetSink`
        has no result — the file is the result).
    """

    def init_sink(mut self, schema: Schema) raises:
        """Called once, on the driver thread, strictly before any
        `accept_batch`. `schema` is the feeding df's resolved OUTPUT
        schema."""
        ...

    def accept_batch(mut self, var rb: RecordBatch) raises:
        """Called once per output `RecordBatch`, in order, on the driver
        thread. Takes the batch by `^` (move)."""
        ...

    # NOTE: the row-native write hook `accept_row_blocks(var ro: RowOutput)`
    # is NOT on the core `Sink` trait — it would force the core packages to
    # import `RowOutput` from `komira_eval` (a higher layer), creating a
    # `core -> eval` import cycle. Instead the hook lives on the
    # `RowSink(Sink)` refinement in `komira_eval.row_format.row_sink`.
    # Core's `Sink` never CALLS the hook (only the SDK's
    # `WriteSpec.feed_sinks_with_row_output` does, and it binds the sole text
    # sink to the concrete `LocalFormatSink[F]` / `CsvSink` type — both `RowSink`
    # conformers). The columnar / binary / in-memory sinks (`InMemorySink`,
    # `ParquetSink`, `ArrowCStreamSink`, `SearchSink`) stay plain `Sink`
    # conformers — they never take the row path (`is_text_output_sink()` is
    # False for all of them), so they have no need for the hook.

    def finish(mut self) raises:
        """Called once, on the driver thread, after the last batch. Returns
        nothing uniformly."""
        ...

    def is_text_output_sink(self) -> Bool:
        """True iff this sink emits a TEXT serialization (CSV / JSONL) whose
        column encoding requires per-column UTF-8 strings on the wire.
        Default: False (binary / columnar / in-memory sinks).

        Read by `cast_to_varchar_insert.insert_cast_if_text_output` to decide
        whether to wrap the root plan with a `PLAN_CAST_TO_VARCHAR` node
        before lowering. The rule pushes the columnar->UTF-8 cast UP THE
        PLAN so the engine can fuse it with the projection / final
        materialization, instead of forcing each row-format sink to do the
        cast on its own hot path.

        Specifically True for:
          * `LocalFormatSink[Csv[Rfc4180]]` / `LocalFormatSink[Csv[Excel]]` /
            `LocalFormatSink[Csv[Posix]]`
          * `LocalFormatSink[Jsonl]`
          * `LocalFormatSink[WholeFileCompressed[Csv[Rfc4180], C]]` for
            C in {Gzip[6], Zstd[3], Lz4Raw}
          * `LocalFormatSink[WholeFileCompressed[Jsonl, C]]` for the same C set
        Explicitly False for: `InMemorySink`, `TypedInMemorySink`,
        `ArrowCStreamSink`, `ParquetSink`, `CsvSink` (legacy direct sink),
        `LocalFormatSink[Parquet[*]]`, `LocalFormatSink[Arrow[*]]`. The False on the
        legacy `CsvSink` reflects that the legacy path materializes its
        own per-column conversions; the rule only fires when the sink is
        the trait-parametric `LocalFormatSink[Csv[*]]` / `LocalFormatSink[Jsonl]`
        family.

        Default implementation returns False so any new sink trait
        implementor that does not opt in is treated as binary / columnar
        — safe for the rule (which would silently NOT cast a sink it
        cannot prove needs the cast).
        """
        return False


# =============================================================================
# InMemBuf — the shared buffer behind an InMemorySink handle.
# =============================================================================


struct InMemBuf(Movable):
    """The Arc-owned buffer behind an `InMemorySink` handle.

    Holds the collected `RecordBatch`es plus two guard flags:
      - `finished`: set by `finish()`. `.take()` raises if not set.
      - `taken`: set by `.take()`. A second `.take()` raises.

    The schema (recorded by `init_sink`) is kept so `.take()` consumers know
    the result shape even when `batches` is empty. `Optional[Schema]` (None
    until `init_sink` records it).
    """

    var batches: Slab[RecordBatch]
    var schema: Optional[Schema]
    var finished: Bool
    var taken: Bool

    def __init__(out self):
        self.batches = Slab[RecordBatch]()
        self.schema = Optional[Schema](None)
        self.finished = False
        self.taken = False


# =============================================================================
# InMemorySink — Arc-backed shareable result handle.
# =============================================================================


struct InMemorySink(Sink, Movable, Copyable, ImplicitlyCopyable):
    """An in-memory write destination: collects every output `RecordBatch`
    into an `ArcPointer[InMemBuf]`, retrievable afterward via `.take()`.

    THE POWER PATH for retrieving query results (`ctx.materialize(df)` is the
    recommended default for the simple case — it does this dance for you):

        var a_buf = InMemorySink()
        var b_buf = InMemorySink()
        ctx.run(a^.write_to(a_buf), b^.write_to(b_buf))   # fills a_buf, b_buf
        var ra = a_buf.take()                             # Slab[RecordBatch]
        var rb = b_buf.take()

    `InMemorySink()` is cheap (one Arc alloc). `.copy()` is a refcount bump —
    the `InMemBuf` is NOT byte-copied; mutating through one handle (the copy
    the `WriteSpec` holds, which the SINK driver fills) is visible through the
    other (the user's `a_buf`, which they `.take()` from). Declares
    `ImplicitlyCopyable` so `df^.write_to(my_sink)` copies the handle without
    a visible `^` at the call site.

    The SINK drain is post-barrier on the driver thread — the `ArcPointer` is
    mutated single-threaded, never cross-thread from morsel workers. The
    buffer is Arc-owned on the heap with a tracked refcount, not a stack
    pointer, so no destroy-recreate lifetime hazard applies.

    Examples:
        ```mojo
        from komira_sdk import InMemorySink
        # multi-sink fan-out: run two pipelines, collect each into its own buffer
        var a_buf = InMemorySink()
        var b_buf = InMemorySink()
        ctx.run(a^.write_to(a_buf), b^.write_to(b_buf))
        var ra = a_buf.take()    # Slab[RecordBatch]
        var rb = b_buf.take()
        ```
    (example not yet doctest-verified)
    """

    var buf: ArcPointer[InMemBuf]

    def __init__(out self):
        """Construct a fresh, empty in-memory sink (one Arc allocation)."""
        self.buf = ArcPointer[InMemBuf](InMemBuf())

    def __init__(out self, *, var buf: ArcPointer[InMemBuf]):
        """Internal: wrap an existing buffer Arc. Used by `.copy()`."""
        self.buf = buf^

    def copy(self) -> Self:
        """Refcount-bump the buffer Arc — NO byte-copy. Both handles see the
        same `InMemBuf` (that is the point: the caller holds one handle, the
        `WriteSpec` holds a copy, `ctx.run` fills via the copy, the caller
        `.take()`s via their handle)."""
        return InMemorySink(buf=self.buf.copy())

    # --- Sink trait conformance ---

    def init_sink(mut self, schema: Schema) raises:
        """Record the feeding df's output schema. No-op beyond stashing it
        (the `.take()` batches carry their own schema; this is for consumers
        that want the shape when `batches` is empty)."""
        self.buf[].schema = Optional[Schema](schema.copy())

    def accept_batch(mut self, var rb: RecordBatch) raises:
        """Append `rb` to the shared buffer (the SINK driver calls this on
        the driver thread, post-barrier)."""
        self.buf[].batches.append(rb^)

    def finish(mut self) raises:
        """Flip the `finished` guard — `.take()` is now allowed."""
        self.buf[].finished = True

    def is_text_output_sink(self) -> Bool:
        """Explicit False — InMemorySink consumes Arrow-typed RecordBatches
        directly; it never needs the per-column UTF-8 cast."""
        return False

    # --- InMemorySink-specific result retrieval (NOT on the Sink trait) ---

    def take(mut self) raises -> Slab[RecordBatch]:
        """Move the collected batches out of the shared buffer. Caller owns
        the result.

        TWO distinct guards:
          - `finished` — set by `finish()` (called by the `ctx.run` tail
            loop). `.take()` before any `ctx.run` (or after a `ctx.run` that
            *raised* before reaching `finish()` for this sink) → raise.
          - `taken` — set by `take()`. A second `.take()` → raise.

        Cannot do `self.buf[].batches^` (no `^`-move through an `ArcPointer`
        deref). The working shape: a new `Slab[RecordBatch]` + the
        `Slab.extend(mut src)` overload, which moves all elements from the
        shared buffer into the new slab IN ORDER and empties the shared
        buffer in place.
        """
        if not self.buf[].finished:
            raise Error(
                "InMemorySink.take(): this sink was never finished — call"
                " ctx.run(... write_to(this_sink) ...) first, and check it"
                " did not raise"
            )
        if self.buf[].taken:
            raise Error(
                "InMemorySink.take(): already taken — the result Slab was"
                " moved out by a prior take() call"
            )
        self.buf[].taken = True
        var out = Slab[RecordBatch]()
        out.extend(self.buf[].batches)
        return out^
