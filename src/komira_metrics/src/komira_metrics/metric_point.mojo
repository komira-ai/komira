# =============================================================================
# metric_point.mojo — the decoded POD metric observation
# =============================================================================
#
# THE ANALOGUE OF `LogRecordView`, for metrics. A `MetricPoint` is what a drain
# hands to an exporter: fully decoded, fixed-stride, owning nothing on the heap.
#
# ⛔ WHAT THIS FILE IS NOT. It is the IN-PROCESS record only. It says NOTHING
# about how a metric is stored at rest — no column layout, no file format, no
# time-partitioning; that is a separate storage design. Do not grow an
# at-rest concern into this struct; if a field here starts being
# justified by "the storage format needs it", that is the signal it belongs in
# the storage design instead.
#
# ⛔ AND IT IS NOT THE ON-RING ENCODING. This struct is the DECODED form; the
# encoded form is separate, deliberately, the same way `LogEventRecord`
# (encoded, on-ring) and `LogRecordView` (decoded, owned) are separate.
#
# WHY POD, AND WHY FIXED-STRIDE. The whole reason attributes are INTERNED to a
# `UInt32 attrset_id` (attr_set.mojo) rather than carried inline is that
# `ARG_INLINE_BYTES = 48` on the log record, and two realistic string labels do
# not fit in 48 bytes. An inline label set would spill to the ring arena on
# EVERY point, on the hot path. Interning makes this record fixed-size
# REGARDLESS of label count and moves the string cost to a one-time insert.
#
# ⭐ RESOURCE AND SCOPE ATTRIBUTES ARE DELIBERATELY ABSENT. They are
# process-constant, so carrying them per point would multiply a fixed cost by
# the number of observations. They are attached by the exporter at serialize
# time -- which is what every OTel SDK does, and what keeps this record fixed-
# stride. A `ResourceAttrs` value built once at process start is passed to the
# exporter, not to this struct.
#
# Encapsulation: scalars only. No `UnsafePointer`, no wildcard origin,
# no heap-owning field -- so a `MetricPoint` is trivially Copyable and can sit
# in an `InlineArray` or cross a drain boundary by value.
# =============================================================================


# -----------------------------------------------------------------------------
# `kind` — the OTel instrument that produced the point.
#
# These are the four OTel data-point kinds we adopt. HISTOGRAM is what makes
# a p99 expressible at all.
# -----------------------------------------------------------------------------
from std.memory import bitcast
from std.sys import size_of


comptime METRIC_COUNTER: UInt8 = UInt8(0)
comptime METRIC_UPDOWNCOUNTER: UInt8 = UInt8(1)
comptime METRIC_GAUGE: UInt8 = UInt8(2)
comptime METRIC_HISTOGRAM: UInt8 = UInt8(3)

# ⚠ THE FIRST UNUSED VALUE, and it exists so that a reader of a `kind` field can
# tell "a kind I do not know" from "the kind that happens to be 0". A drain that
# routes on a discriminant with an OPEN default silently decodes a new kind as
# the first one. Any consumer switching on `kind` MUST have a closed default.
comptime METRIC_KIND_UNKNOWN: UInt8 = UInt8(255)


# -----------------------------------------------------------------------------
# `flags` — one bit each. Packed rather than four Bools so the record stays
# fixed-stride and the whole header fits the cache line the ring already uses.
# -----------------------------------------------------------------------------
# Temporality. CLEAR = DELTA, SET = CUMULATIVE. Delta is the default because a
# per-worker table that is reduced and reset each export sweep produces deltas
# naturally; cumulative requires the reducer to hold state across sweeps.
comptime MFLAG_CUMULATIVE: UInt8 = UInt8(1) << 0
# Monotonic. Meaningful for COUNTER (always set) vs UPDOWNCOUNTER (always
# clear); an exporter needs it to pick the right OTLP message arm.
comptime MFLAG_MONOTONIC: UInt8 = UInt8(1) << 1
# SET = `value_bits` is a Float64 bit pattern; CLEAR = it is an Int64.
comptime MFLAG_VALUE_IS_DOUBLE: UInt8 = UInt8(1) << 2
# SET = `exemplar_span_id` is meaningful. ⚠ Needed as its OWN bit: span id 0 is
# indistinguishable from "no exemplar" otherwise: the absent-vs-empty trap.
comptime MFLAG_HAS_EXEMPLAR: UInt8 = UInt8(1) << 3


struct MetricPoint(Copyable, Movable, Deinitable):
    """One decoded metric observation. POD; no heap-owning field.

    Field order is chosen so the 4-byte ids pack together ahead of the two
    single-byte discriminants -- the same "scalars widest-first" layout
    `LogEventRecord` uses -- leaving no interior padding before the 8-byte
    timestamps.
    """

    # FNV-1a of the comptime metric name, via the existing `name_registry`.
    var name_id: UInt32
    # FNV-1a of the instrumentation scope. This is the SAME id space as the log
    # record's `module_id`, deliberately: a metric emitted from a module and a
    # log line emitted from that module must join on scope without a mapping
    # table.
    var scope_id: UInt32
    # Interned attribute-SET id (attr_set.mojo). 0 == the EMPTY attribute set,
    # which is a real, common case and NOT a sentinel for "unset".
    var attrset_id: UInt32
    var kind: UInt8
    var flags: UInt8
    var _pad: Array[UInt8, 2]
    # Start of the interval this point covers. For a DELTA point this is the
    # previous sweep's `time_unix_ns`; for a CUMULATIVE one it is process start.
    var start_time_unix_ns: UInt64
    var time_unix_ns: UInt64
    # Int64, or a Float64 bit pattern. `MFLAG_VALUE_IS_DOUBLE` decides, and
    # NOTHING ELSE DOES -- do not infer it from `kind`.
    var value_bits: UInt64
    # 0 == none, but ONLY when `MFLAG_HAS_EXEMPLAR` is clear. Read the flag.
    var exemplar_span_id: UInt64

    def __init__(out self):
        self.name_id = UInt32(0)
        self.scope_id = UInt32(0)
        self.attrset_id = UInt32(0)
        self.kind = METRIC_KIND_UNKNOWN
        self.flags = UInt8(0)
        self._pad = Array[UInt8, 2](fill=UInt8(0))
        self.start_time_unix_ns = UInt64(0)
        self.time_unix_ns = UInt64(0)
        self.value_bits = UInt64(0)
        self.exemplar_span_id = UInt64(0)

    # -------------------------------------------------------------------------
    # Flag predicates. Read these rather than masking at the call site -- a
    # hand-rolled mask is where an off-by-one-bit lands.
    # -------------------------------------------------------------------------

    @always_inline
    def is_cumulative(self) -> Bool:
        return (self.flags & MFLAG_CUMULATIVE) != UInt8(0)

    @always_inline
    def is_monotonic(self) -> Bool:
        return (self.flags & MFLAG_MONOTONIC) != UInt8(0)

    @always_inline
    def value_is_double(self) -> Bool:
        return (self.flags & MFLAG_VALUE_IS_DOUBLE) != UInt8(0)

    @always_inline
    def has_exemplar(self) -> Bool:
        return (self.flags & MFLAG_HAS_EXEMPLAR) != UInt8(0)

    # -------------------------------------------------------------------------
    # Value accessors. The bit pattern is ONE field with TWO interpretations,
    # so the only safe way to read it is through the flag.
    # -------------------------------------------------------------------------

    @always_inline
    def as_int(self) -> Int64:
        """The value as Int64. Caller must have checked `value_is_double()` is
        False -- reading a double's bit pattern as an Int64 is not a
        conversion, it is a reinterpretation, and it will be nonsense."""
        return Int64(self.value_bits)

    @always_inline
    def as_double(self) -> Float64:
        """The value as Float64. Caller must have checked `value_is_double()`."""
        # A REINTERPRETATION of the 64 bits, not a numeric conversion.
        return bitcast[DType.float64, 1](
            SIMD[DType.uint64, 1](self.value_bits)
        )[0]

    @always_inline
    def set_int_value(mut self, v: Int64):
        self.value_bits = UInt64(v)
        self.flags = self.flags & ~MFLAG_VALUE_IS_DOUBLE

    @always_inline
    def set_double_value(mut self, v: Float64):
        self.value_bits = UInt64(v.to_bits())
        self.flags = self.flags | MFLAG_VALUE_IS_DOUBLE

    @always_inline
    def set_exemplar(mut self, span_id: UInt64):
        """Attach an exemplar span. Sets the FLAG as well as the field, because
        span id 0 is a legal span id and cannot itself mean 'none'."""
        self.exemplar_span_id = span_id
        self.flags = self.flags | MFLAG_HAS_EXEMPLAR


# -----------------------------------------------------------------------------
# Constructors for the four kinds. These exist so the flag/kind pairs that MUST
# agree are set in one place: a COUNTER that is not monotonic, or an
# UPDOWNCOUNTER that is, is a malformed point an exporter cannot lower to OTLP.
# -----------------------------------------------------------------------------


def counter_point(
    name_id: UInt32,
    scope_id: UInt32,
    attrset_id: UInt32,
    value: Int64,
    start_time_unix_ns: UInt64,
    time_unix_ns: UInt64,
) -> MetricPoint:
    """A monotonic DELTA counter point."""
    var p = MetricPoint()
    p.name_id = name_id
    p.scope_id = scope_id
    p.attrset_id = attrset_id
    p.kind = METRIC_COUNTER
    p.flags = MFLAG_MONOTONIC
    p.start_time_unix_ns = start_time_unix_ns
    p.time_unix_ns = time_unix_ns
    p.set_int_value(value)
    return p^


def updown_counter_point(
    name_id: UInt32,
    scope_id: UInt32,
    attrset_id: UInt32,
    value: Int64,
    start_time_unix_ns: UInt64,
    time_unix_ns: UInt64,
) -> MetricPoint:
    """A NON-monotonic DELTA counter point (can decrease)."""
    var p = MetricPoint()
    p.name_id = name_id
    p.scope_id = scope_id
    p.attrset_id = attrset_id
    p.kind = METRIC_UPDOWNCOUNTER
    p.flags = UInt8(0)
    p.start_time_unix_ns = start_time_unix_ns
    p.time_unix_ns = time_unix_ns
    p.set_int_value(value)
    return p^


def gauge_point(
    name_id: UInt32,
    scope_id: UInt32,
    attrset_id: UInt32,
    value: Int64,
    time_unix_ns: UInt64,
) -> MetricPoint:
    """An instantaneous reading. A gauge has NO interval, so `start_time` is
    set equal to `time` rather than left at 0 -- an exporter that subtracts
    them must get a zero-width window, not a window back to the epoch."""
    var p = MetricPoint()
    p.name_id = name_id
    p.scope_id = scope_id
    p.attrset_id = attrset_id
    p.kind = METRIC_GAUGE
    p.flags = UInt8(0)
    p.start_time_unix_ns = time_unix_ns
    p.time_unix_ns = time_unix_ns
    p.set_int_value(value)
    return p^


# -----------------------------------------------------------------------------
# Compile-time SIZE anchor — the convention `komira_trace`'s
# `span_record.mojo` and `span_packet.mojo` follow.
#
# ⛔ IT IS NOT A POD GUARD. `size_of` of a non-POD type is NOT rejected: a
# probe `comptime _P: Int = size_of[String]()` appended to this file builds
# (String owns a heap allocation and has a non-trivial destructor), while the
# control `size_of[NoSuchTypeXYZ]()` fails with "use of unknown declaration".
# The control is what makes the first result evidence instead of a skipped
# declaration: comptime aliases in this file ARE elaborated, and `size_of`
# accepts the non-POD type regardless.
#
# NOR CAN THE CLAIM BE MADE TRUE HERE. Mojo 1.0.0 exposes no trait expressing
# POD-ness for a memory-only struct: `AnyTrivialRegType` is not a declaration in
# this compiler (`error: use of unknown declaration 'AnyTrivialRegType'`), and
# the nearest real bound, `ImplicitlyCopyable`, rejects `MetricPoint` itself
# (`parameter 'T' has 'ImplicitlyCopyable' type, but value has type
# 'AnyStruct[...]'`). So no POD claim is made here.
#
# WHAT THIS LINE ACTUALLY BUYS: `size_of[MetricPoint]()` is evaluated at
# elaboration and the number gets a name the TEST READS —
# `test_the_size_guard_constants_are_the_bytes_the_headers_claim` in
# `tests/test_metric_point_and_attr_set.mojo`; a guard nothing reads guards
# nothing. What catches a
# field-type swap is that NUMBER changing, plus the compiler at every site that
# assigns the field — never `size_of` itself.
# -----------------------------------------------------------------------------
comptime _METRIC_POINT_SIZE_GUARD: Int = size_of[MetricPoint]()
