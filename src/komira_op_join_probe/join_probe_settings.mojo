# =============================================================================
# join_probe_settings -- the process settings of the composite-key probe.
# =============================================================================
#
# FLAGS, NOT ENVIRONMENT VARIABLES. A host sets these once per process from its
# flags, before any join runs; nothing in this package reads the environment.
# Each setting is a process-global cell read with one relaxed load. Unset, each
# is the value the engine has always shipped with.
#
#   * THE PARALLEL PROBE (`mk_probe_configure`):
#       batch_width  probe rows a worker carries through the chain walk
#                    together (the batched walk; default 512). 0 selects the
#                    row-at-a-time walk, the reference both must agree with.
#       morsel_rows  the probe morsel in rows; 0 (the default) takes the
#                    engine's fork grain (`parallel_fork_grain`).
#       retile       when every core is busy and there are fewer than four
#                    morsels per worker, cut morsels down to give four (but
#                    never below 4,096 rows). Off by default.
#
# The composite parallel BUILD has no setting of its own: it follows the hash
# join's build mode and fill settings in `komira_op_join_build`'s
# `hash_chain_build_settings`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import alloc, OwnedPointer


comptime MK_PROBE_BATCH_DEFAULT: Int = 512
"""The batched walk's width when `mk_probe_configure` was never called."""

comptime MK_PROBE_RETILE_MIN_ROWS: Int = 4_096
"""The smallest morsel the retile cuts to."""


def _init_jps_i64() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


# 0 = not configured (`MK_PROBE_BATCH_DEFAULT`), else the width plus one.
comptime _JPS_BATCH = _Global["komira_mk_probe_batch", _init_jps_i64]
# 0 = the fork grain, else the morsel in rows.
comptime _JPS_MORSEL = _Global["komira_mk_probe_morsel", _init_jps_i64]
# 0 = off, 1 = on.
comptime _JPS_RETILE = _Global["komira_mk_probe_retile", _init_jps_i64]


def mk_probe_configure(
    batch_width: Int = MK_PROBE_BATCH_DEFAULT,
    morsel_rows: Int = 0,
    retile: Bool = False,
) raises:
    """Set the parallel composite probe's walk width, morsel and retile.

    Raises on a negative width or morsel.
    """
    if batch_width < 0:
        raise Error("mk_probe_configure: negative batch_width")
    if morsel_rows < 0:
        raise Error("mk_probe_configure: negative morsel_rows")
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    _JPS_BATCH.get_or_create_ptr()[][].store(Scalar[DType.int64](batch_width + 1))
    _JPS_MORSEL.get_or_create_ptr()[][].store(Scalar[DType.int64](morsel_rows))
    _JPS_RETILE.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if retile else 0))


def mk_probe_batch_width() raises -> Int:
    """The batched walk's width; 0 is the row-at-a-time walk."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    var v = Int(_JPS_BATCH.get_or_create_ptr()[][].load())
    return MK_PROBE_BATCH_DEFAULT if v == 0 else v - 1


def mk_probe_morsel_rows() raises -> Int:
    """The configured probe morsel in rows; 0 takes the fork grain."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_MORSEL.get_or_create_ptr()[][].load())


def mk_probe_retile_on() raises -> Bool:
    """Is the probe retile on? Off unless configured."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RETILE.get_or_create_ptr()[][].load()) != 0


def reset_join_probe_settings() raises:
    """TEST-ONLY. Every setting back to its default."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    _JPS_BATCH.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_MORSEL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RETILE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
