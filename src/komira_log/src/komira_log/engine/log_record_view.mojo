# =============================================================================
# komira_log.engine.log_record_view — the POD-owned drain seam.
# =============================================================================
#
# `LogRecordView` is the OWNED, search-FREE handoff value the drain produces for
# a search-side consumer (`komira_log_index`). It is the POD-returning,
# inspectable twin of the text drain: it carries the record's scalars PLUS the
# already-interpolated `message` String PLUS the already-decoded arg key=value
# pairs — all OWNED (no arena reference, no `UnsafePointer`, no wildcard origin
# crosses the engine boundary).
#
# WHY THIS SHAPE:
#   * `komira_log` MUST stay import-clean (no Arrow / search / S3 dependency).
#     So the transpose-to-`RecordBatch` lives in the search-side consumer; the
#     engine returns ONLY this POD value.
#   * The drain decodes the arg-blob out of the per-ring ARENA
#     (`ring.arena_slice`). The arena is reclaimed at `reset_arena`. So every
#     byte that leaves the engine MUST be COPIED into an owned `String` / `List`
#     BEFORE the seam — which `decode_one`'s helpers already do (they build
#     owned `String`s). `LogRecordView` holds those owned Strings, so the
#     consumer never touches the arena.
#
# NOTE THIS IS NOT THE POD ON-RING RECORD. `LogEventRecord` (log_event_record.mojo)
# is the fixed-stride ring element (every field a scalar / InlineArray).
# `LogRecordView` is the DECODED, owned, heap-carrying value — it is NEVER stored
# in a byte-slab; it lives only in a function-local `List[LogRecordView]` the drain
# returns and the consumer immediately transposes + drops.
#
# FIELD INVENTORY (the consumer codes against THIS):
#   level       UInt8   -> rendered to STRING `level` by the consumer (KEYWORD)
#   module_id   UInt32  -> the consumer maps via dict OR the engine pre-renders it
#                          (we carry the resolved `module` String so the consumer
#                          needs ZERO `komira_log` dictionary internals)
#   timestamp   UInt64  -> RAW cycle ticks; the engine ALSO carries the converted
#                          wall-ms (`wall_ms`) so the consumer needs no anchor
#   corr_id     UInt64  -> widened to Int64 by the consumer
#   flags       UInt16  -> widened to Int64 by the consumer
#   site_id     UInt32  -> widened to Int64 by the consumer
#   message     String  -> interpolate(fmt, positionals) — the TEXT field
#   arg_keys    []String, arg_vals []String -> the decoded trailing key=value
#                          Field args (the consumer can emit fixed-known-key
#                          columns; free-form keys fold into `_source`)
# =============================================================================


struct LogRecordView(Copyable, Movable, Deinitable):
    """The owned, search-free handoff value the drain produces per LOG record.

    Carries the record's scalars + the interpolated message + the decoded arg
    key=value pairs, all OWNED (no arena reference). The search-side consumer
    (`komira_log_index`) transposes a `List[LogRecordView]` into a typed
    multi-column `RecordBatch`. `komira_log` never depends on the consumer."""

    # --- scalars ---
    var level: UInt8
    var flags: UInt16
    var site_id: UInt32
    var module_id: UInt32
    var timestamp: UInt64  # RAW cycle ticks (ordering key)
    var corr_id: UInt64
    var wall_ms: Int64  # the converted wall-clock ms (anchor.tick_to_wall_ms)

    # --- owned decoded payload ---
    var message: String  # interpolate(fmt, positionals) — the inverted TEXT field
    var module: String  # resolved module name (dict.lookup_module) — KEYWORD
    var arg_keys: List[String]  # trailing Field arg keys (parallel to arg_vals)
    var arg_vals: List[String]  # trailing Field arg values

    def __init__(
        out self,
        level: UInt8,
        flags: UInt16,
        site_id: UInt32,
        module_id: UInt32,
        timestamp: UInt64,
        corr_id: UInt64,
        wall_ms: Int64,
        var message: String,
        var module: String,
        var arg_keys: List[String],
        var arg_vals: List[String],
    ):
        self.level = level
        self.flags = flags
        self.site_id = site_id
        self.module_id = module_id
        self.timestamp = timestamp
        self.corr_id = corr_id
        self.wall_ms = wall_ms
        self.message = message^
        self.module = module^
        self.arg_keys = arg_keys^
        self.arg_vals = arg_vals^
