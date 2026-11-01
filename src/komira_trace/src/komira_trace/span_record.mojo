# =============================================================================
# span_record.mojo — POD types crossing the worker → drain boundary
# =============================================================================
#
# POD-only on cross-thread payloads. Every byte that crosses a worker
# boundary (ring buffer slot, span event, link record) is POD:
# `InlineArray[_, N]` or fixed-size primitives. NO `List[T]`, `String`,
# `OwnedPointer[T]`, or wildcard origins.
#
# This is a hard rule: a non-POD field in a slot that is destroyed and
# reused would reinterpret stale bytes under a new lifetime. Any future
# field added to these structs MUST stay POD or the static-assertion
# test (`tests/test_span_record_pod.mojo`) fails.
# =============================================================================

from std.sys import size_of


# Comptime-tunable hard caps. Bumping these changes the per-record byte
# size; do NOT raise without auditing the ring-buffer slot stride.
comptime TRACE_ID_BYTES: Int = 16  # 128-bit, fits OTel-shaped trace_id
comptime DEFAULT_MAX_LINKS: Int = 4
comptime MAX_ATTR_STR_BYTES: Int = 32  # InlineArray[UInt8, 32] — string attr bound

# Flag bits for SpanRecord.flags
comptime SPAN_FLAG_ROOT: UInt32 = UInt32(1) << 0
comptime SPAN_FLAG_HAS_ERROR: UInt32 = UInt32(1) << 1
comptime SPAN_FLAG_HAS_LINKS: UInt32 = UInt32(1) << 2
# bits 8..15 reserved per design

# SpanRecord.status: 0=open, 1=closed, 2=dropped (overflow)
comptime SPAN_STATUS_OPEN: UInt8 = UInt8(0)
comptime SPAN_STATUS_CLOSED: UInt8 = UInt8(1)
comptime SPAN_STATUS_DROPPED: UInt8 = UInt8(2)


struct SpanLink(Copyable, Movable, Deinitable):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy an implicit copy emitted
    # implicitly, so codegen and cost are unchanged.
    """A cross-thread happens-before edge — POD by construction.

    Schema: `target_trace_id` (InlineArray[UInt8, 16]) +
    `target_span_id` (UInt64) + `flags` (UInt32). Total: 16 + 8 + 4 = 28
    bytes (compiler may pad to 32 on aarch64).
    """

    var target_trace_id: Array[UInt8, TRACE_ID_BYTES]
    var target_span_id: UInt64
    var flags: UInt32

    def __init__(out self):
        self.target_trace_id = Array[UInt8, TRACE_ID_BYTES](fill=UInt8(0))
        self.target_span_id = UInt64(0)
        self.flags = UInt32(0)

    def __init__(
        out self,
        target_trace_id: Array[UInt8, TRACE_ID_BYTES],
        target_span_id: UInt64,
        flags: UInt32,
    ):
        self.target_trace_id = target_trace_id.copy()
        self.target_span_id = target_span_id
        self.flags = flags


struct SpanRecord(Copyable, Movable, Deinitable):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy an implicit copy emitted
    # implicitly, so codegen and cost are unchanged.
    """One span emission unit — POD by construction.

    Schema:
        trace_id   InlineArray[UInt8, 16]
        span_id    UInt64
        parent_id  UInt64           (0 = root)
        name_id    UInt32           (FNV-1a hash; lazy-registered)
        start_ns   UInt64           (perf_counter_ns())
        end_ns     UInt64           (0 if still open)
        worker_id  UInt32
        flags      UInt32
        status     UInt8            (open / closed / dropped)
        n_links    UInt8            (number of valid entries in links[])
        _pad       InlineArray[UInt8, 6]   (align to 8)
        links      InlineArray[SpanLink, DEFAULT_MAX_LINKS]

    POD invariant: every field is a primitive scalar or an InlineArray of
    a POD element — proved by `tests/test_span_record_pod.mojo`.
    """

    var trace_id: Array[UInt8, TRACE_ID_BYTES]
    var span_id: UInt64
    var parent_id: UInt64
    var name_id: UInt32
    var start_ns: UInt64
    var end_ns: UInt64
    var worker_id: UInt32
    var flags: UInt32
    var status: UInt8
    var n_links: UInt8
    # 6-byte pad keeps the struct 8-aligned before the links array.
    var _pad: Array[UInt8, 6]
    var links: Array[SpanLink, DEFAULT_MAX_LINKS]

    def __init__(out self):
        self.trace_id = Array[UInt8, TRACE_ID_BYTES](fill=UInt8(0))
        self.span_id = UInt64(0)
        self.parent_id = UInt64(0)
        self.name_id = UInt32(0)
        self.start_ns = UInt64(0)
        self.end_ns = UInt64(0)
        self.worker_id = UInt32(0)
        self.flags = UInt32(0)
        self.status = SPAN_STATUS_OPEN
        self.n_links = UInt8(0)
        self._pad = Array[UInt8, 6](fill=UInt8(0))
        self.links = Array[SpanLink, DEFAULT_MAX_LINKS](fill=SpanLink())

    @always_inline
    def is_root(self) -> Bool:
        return (self.flags & SPAN_FLAG_ROOT) != UInt32(0)

    @always_inline
    def has_error(self) -> Bool:
        return (self.flags & SPAN_FLAG_HAS_ERROR) != UInt32(0)


# -----------------------------------------------------------------------------
# Compile-time size guards. `size_of` of a non-POD type is NOT rejected (see
# `metric_point.mojo`), so what these catch is the SIZE changing, which
# `tests/test_span_record_pod.mojo` checks.
# -----------------------------------------------------------------------------
comptime _SPAN_LINK_SIZE_GUARD: Int = size_of[SpanLink]()
comptime _SPAN_RECORD_SIZE_GUARD: Int = size_of[SpanRecord]()
