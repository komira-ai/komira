# =============================================================================
# residual_mark_counter -- witnesses of the parallel residual mark join
# (`residual_semi_anti_parallel`): how often it ran, how many workers each of
# its three waves actually spanned, and its table geometry.
# =============================================================================
#
# A parallel path that silently ran on one worker gives the same answer as the
# serial one, so values cannot show it ran in parallel; these counters can.
# Spans and morsel counts keep the process-wide maximum. Every counter is a
# relaxed process-global atomic, updated per call, not per row.
# =============================================================================

from std.atomic import Atomic
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_residual_mark_fire() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the FIRE counter once per process (init 0)."""
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _RM_FIRE = _Global[
    "komira_residual_mark_fire",
    _init_residual_mark_fire,
]


@always_inline
def residual_mark_fire_incr() raises:
    """Record one parallel SEMI/ANTI residual mark-join invocation."""
    # SAFETY: FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    var gp = _RM_FIRE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def residual_mark_fire_count() raises -> Int:
    """Read the process-wide parallel-mark fire count."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_FIRE.get_or_create_ptr()
    return Int(gp[][].load())


def _init_residual_mark_build_span() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the BUILD-wave span max (init 0)."""
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


def _init_residual_mark_stream_span() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the STREAM(probe)-wave span max (init 0)."""
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _RM_BUILD_SPAN = _Global[
    "komira_residual_mark_build_span",
    _init_residual_mark_build_span,
]

comptime _RM_STREAM_SPAN = _Global[
    "komira_residual_mark_stream_span",
    _init_residual_mark_stream_span,
]


@always_inline
def residual_mark_build_span_record(span: Int) raises:
    """Record the BUILD wave's worker span (task instances that claimed >= 1
    morsel), keeping the process-wide MAXIMUM via a compare-exchange loop.
    """
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_BUILD_SPAN.get_or_create_ptr()
    var target = Int64(span)
    while True:
        var cur = gp[][].load()
        if target <= cur:
            break
        if Atomic[DType.int64].compare_exchange(
            UnsafePointer(to=gp[][].value), cur, target
        ):
            break


@always_inline
def residual_mark_stream_span_record(span: Int) raises:
    """Record the STREAM (probe+residual+mark) wave's worker span, process-wide
    MAX. See `residual_mark_build_span_record` for why the CAS is inline.
    """
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_STREAM_SPAN.get_or_create_ptr()
    var target = Int64(span)
    while True:
        var cur = gp[][].load()
        if target <= cur:
            break
        if Atomic[DType.int64].compare_exchange(
            UnsafePointer(to=gp[][].value), cur, target
        ):
            break


def residual_mark_build_span() raises -> Int:
    """Read the process-wide MAX worker span observed on the BUILD wave alone."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_BUILD_SPAN.get_or_create_ptr()
    return Int(gp[][].load())


def residual_mark_stream_span() raises -> Int:
    """Read the process-wide MAX worker span observed on the STREAM wave alone."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_STREAM_SPAN.get_or_create_ptr()
    return Int(gp[][].load())


def residual_mark_worker_span() raises -> Int:
    """Read the process-wide MAX worker span across build+stream (the UNION)."""
    var b = residual_mark_build_span()
    var s = residual_mark_stream_span()
    return b if b >= s else s


def _init_rm_prep_morsels() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the PREPARE morsel-count max (init 0)."""
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


def _init_rm_prep_span() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the PREPARE worker-span max (init 0)."""
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _RM_PREP_MORSELS = _Global[
    "komira_residual_mark_prepare_morsels",
    _init_rm_prep_morsels,
]

comptime _RM_PREP_SPAN = _Global[
    "komira_residual_mark_prepare_span",
    _init_rm_prep_span,
]


@always_inline
def residual_mark_prepare_record(morsels: Int, span: Int) raises:
    """Record the PREPARE fill wave's morsel count + worker span, keeping the
    process-wide MAXIMUM of each. Two atomic maxes per mark-join invocation
    (not per row).
    """
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gm = _RM_PREP_MORSELS.get_or_create_ptr()
    var m_target = Int64(morsels)
    while True:
        var cur = gm[][].load()
        if m_target <= cur:
            break
        if Atomic[DType.int64].compare_exchange(
            UnsafePointer(to=gm[][].value), cur, m_target
        ):
            break
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gs = _RM_PREP_SPAN.get_or_create_ptr()
    var s_target = Int64(span)
    while True:
        var cur = gs[][].load()
        if s_target <= cur:
            break
        if Atomic[DType.int64].compare_exchange(
            UnsafePointer(to=gs[][].value), cur, s_target
        ):
            break


def residual_mark_prepare_morsels() raises -> Int:
    """Read the process-wide MAX `n_prep_morsels` the PREPARE wave dispatched."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_PREP_MORSELS.get_or_create_ptr()
    return Int(gp[][].load())


def residual_mark_prepare_worker_span() raises -> Int:
    """Read the process-wide MAX worker span observed across the PREPARE wave."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_PREP_SPAN.get_or_create_ptr()
    return Int(gp[][].load())


comptime _GEOM_SLOTS: Int = 2
comptime _GEOM_FIELDS: Int = 3
comptime _GEOM_N: Int = 1 + _GEOM_SLOTS * _GEOM_FIELDS

comptime GEOM_BUILD_ROWS: Int = 0
comptime GEOM_PROBE_ROWS: Int = 1
comptime GEOM_CAP: Int = 2


def _init_rm_geom() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn: allocate the `_GEOM_N`-slot geometry array (all 0)."""
    var raw = alloc[Atomic[DType.int64]](_GEOM_N)
    for i in range(_GEOM_N):
        UnsafePointer(to=(raw + i)[].value).unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _RM_GEOM = _Global[
    "komira_residual_mark_geometry",
    _init_rm_geom,
]


def residual_mark_geometry_record(
    build_rows: Int, probe_rows: Int, cap: Int
) raises:
    """Record ONE mark-join invocation's real geometry into the next ordinal
    slot. Called once per `parallel_residual_semi_anti_mark` (not per row).
    """
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`). The
    # `+ i` arithmetic stays inside this module and never crosses a boundary;
    # `_init_rm_geom` allocated `_GEOM_N` contiguous elements.
    var gp = _RM_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    var ordinal = Int(base[].fetch_add(Int64(1)))
    var slot = ordinal % _GEOM_SLOTS
    var off = 1 + slot * _GEOM_FIELDS
    (base + off + GEOM_BUILD_ROWS)[].store(Scalar[DType.int64](build_rows))
    (base + off + GEOM_PROBE_ROWS)[].store(Scalar[DType.int64](probe_rows))
    (base + off + GEOM_CAP)[].store(Scalar[DType.int64](cap))


def residual_mark_geometry_count() raises -> Int:
    """How many mark-join invocations recorded geometry since the last reset."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gp = _RM_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    return Int(base[].load())


def residual_mark_geometry_field(slot: Int, field: Int) raises -> Int:
    """Read one recorded geometry field. `slot` is the invocation ordinal mod
    `_GEOM_SLOTS`; `field` is `GEOM_BUILD_ROWS` / `GEOM_PROBE_ROWS` /
    `GEOM_CAP`. Out-of-range returns -1 rather than reading past the array.
    """
    if slot < 0 or slot >= _GEOM_SLOTS:
        return -1
    if field < 0 or field >= _GEOM_FIELDS:
        return -1
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`); the index is
    # range-checked above against the `_GEOM_N` elements `_init_rm_geom` made.
    var gp = _RM_GEOM.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][])
    return Int((base + 1 + slot * _GEOM_FIELDS + field)[].load())


def reset_residual_mark_counters() raises:
    """Reset every process-wide counter in this module to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `residual_mark_fire_incr`).
    var gf = _RM_FIRE.get_or_create_ptr()
    gf[][].store(Scalar[DType.int64](0))
    var gb = _RM_BUILD_SPAN.get_or_create_ptr()
    gb[][].store(Scalar[DType.int64](0))
    var gt = _RM_STREAM_SPAN.get_or_create_ptr()
    gt[][].store(Scalar[DType.int64](0))
    var gm = _RM_PREP_MORSELS.get_or_create_ptr()
    gm[][].store(Scalar[DType.int64](0))
    var gp = _RM_PREP_SPAN.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
    var gg = _RM_GEOM.get_or_create_ptr()
    var gbase = UnsafePointer(to=gg[][])
    for i in range(_GEOM_N):
        (gbase + i)[].store(Scalar[DType.int64](0))
