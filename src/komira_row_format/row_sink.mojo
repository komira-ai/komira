# =============================================================================
# RowSink — the eval-layer refinement of core's `Sink` that adds the
# row-native write-path hook (`accept_row_blocks`).
# =============================================================================
#
# Why the hook lives here and not on the core `Sink` trait: its default body
# calls `bridge_row_output_to_record_batch`, a `komira_row_format` symbol. On the
# core `Sink` trait that would force `komira_core.source.sink` to import from
# `komira_row_format` — a `core -> row_format` up-edge, i.e. a dependency cycle. Core never
# CALLS the hook (only the SDK's `WriteSpec.feed_sinks_with_row_output` does).
# So the hook lives on this `RowSink(Sink)` refinement in `komira_row_format` (where
# `RowOutput` + the bridge live — a legal DOWN-edge: row_format -> core). The
# sinks that take the row path (`LocalFormatSink[F]`, `CsvSink`) bind to `RowSink`
# instead of `Sink`; every other sink (`InMemorySink`, `ParquetSink`,
# `ArrowCStreamSink`, `TypedInMemorySink`, `SearchSink`) stays a plain `Sink`
# — correct by the `is_text_output_sink() == False` invariant (they never
# reach the row-native path).
#
# Type identity: `RowOutput` is one struct in one package, so the carrier value
# is batch-safe across the boundary.
#
# Encapsulation: zero `UnsafePointer` in any public signature; zero wildcard
# origin; zero `unsafe_from_address`. The carrier owns its `Slab[RowBlock]` by
# value and is moved by `^`.
# =============================================================================

from komira_core.source.sink import Sink
from komira_row_format.row_output import (
    RowOutput,
    bridge_row_output_to_record_batch,
)


trait RowSink(Sink):
    """A write-side destination that ALSO supports the row-native write path.

    Refines core's `Sink` (inherits `init_sink` / `accept_batch` / `finish` /
    `is_text_output_sink`) and adds `accept_row_blocks(var ro: RowOutput)` —
    the hook `ctx.run` calls INSTEAD of `accept_batch` when (a) the sink emits
    a text serialization (`is_text_output_sink()`) AND (b) the plan is
    row-streaming-eligible (a pure FILTER/PROJECT/LIMIT chain), so the
    surviving rows arrive as `RowBlock`s WITHOUT the wasteful
    row->columnar->row-text bridge.

    The text-format sinks (`LocalFormatSink[Csv[*]]` / `LocalFormatSink[Jsonl]` + the
    legacy `CsvSink`) OVERRIDE `accept_row_blocks` to serialize rows DIRECTLY.
    The DEFAULT below bridges the RowBlocks to a columnar `RecordBatch` (the
    SHARED `bridge_row_output_to_record_batch`, byte-identical to the
    row-streaming finalize bridge) then delegates to `accept_batch` — so a
    `RowSink` conformer that does NOT override (e.g. `LocalFormatSink[Parquet[*]]`,
    which conforms to `RowSink` but whose text-output query never reaches the
    row path) still has a correct, no-op-equivalent fallback.
    """

    def accept_row_blocks(mut self, var ro: RowOutput) raises:
        """Row-native write-path hook.

        DEFAULT IMPLEMENTATION: bridge the RowBlocks to a columnar
        `RecordBatch` (the SHARED `bridge_row_output_to_record_batch`, which is
        byte-identical to the row-streaming finalize bridge) then delegate to
        `accept_batch`. So a `RowSink` conformer that does not override
        inherits a no-op-equivalent path and is UNAFFECTED — only the row-text
        sinks (`CsvSink`, `LocalFormatSink[Csv[*]]`, `LocalFormatSink[Jsonl]`) override this
        to serialize rows DIRECTLY.

        The carrier owns its `Slab[RowBlock]` by value and is moved in by `^`.
        """
        self.accept_batch(bridge_row_output_to_record_batch(ro^))
