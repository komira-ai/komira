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
#   * THE PARALLEL RESIDUAL MARK JOIN (`residual_mark_configure`, each lever
#     set on its own), the SEMI / ANTI join with a residual predicate over one
#     INT64 key:
#       key_share        borrow the key columns instead of copying (on);
#       prepare_parallel fill its three buffers in one fanned wave instead of
#                        on the driver (on);
#       chain_fill_elide skip zero-filling the chain links, every one of which
#                        the build writes (on);
#       cap_nearest      halve the table when the row count is within 1/64 of
#                        the lower power of two (off: it trades a smaller
#                        table for a higher load factor, unmeasured);
#       fill_morsel      the fill wave's grain in elements (0: 262,144);
#       force            take the parallel path at any size, one-row morsels
#                        (a test hook; off).
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


comptime RESIDUAL_MARK_FILL_MORSEL_DEFAULT: Int = 262_144
"""The residual mark join's fill grain in elements when unconfigured."""

# Each Bool cell: 0 = not configured (the default), 1 = on, 2 = off.
comptime _JPS_RM_SHARE = _Global["komira_residual_mark_key_share", _init_jps_i64]
comptime _JPS_RM_PREP = _Global["komira_residual_mark_prepare", _init_jps_i64]
comptime _JPS_RM_ELIDE = _Global["komira_residual_mark_elide", _init_jps_i64]
comptime _JPS_RM_CAP = _Global["komira_residual_mark_cap_nearest", _init_jps_i64]
comptime _JPS_RM_FORCE = _Global["komira_residual_mark_force", _init_jps_i64]
# 0 = `RESIDUAL_MARK_FILL_MORSEL_DEFAULT`, else the grain.
comptime _JPS_RM_FILL = _Global["komira_residual_mark_fill", _init_jps_i64]


@always_inline
def _cell(on: Bool) -> Scalar[DType.int64]:
    return Scalar[DType.int64](1 if on else 2)


def residual_mark_configure(
    key_share: Optional[Bool] = None,
    prepare_parallel: Optional[Bool] = None,
    chain_fill_elide: Optional[Bool] = None,
    cap_nearest: Optional[Bool] = None,
    fill_morsel: Optional[Int] = None,
    force: Optional[Bool] = None,
) raises:
    """Set the parallel residual mark join's levers (see the header). Each
    argument given sets its lever; one left `None` keeps its current value.
    `fill_morsel` 0 is the default grain.

    Raises on a negative fill grain.
    """
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    if fill_morsel:
        if fill_morsel.value() < 0:
            raise Error("residual_mark_configure: negative fill_morsel")
        _JPS_RM_FILL.get_or_create_ptr()[][].store(
            Scalar[DType.int64](fill_morsel.value())
        )
    if key_share:
        _JPS_RM_SHARE.get_or_create_ptr()[][].store(_cell(key_share.value()))
    if prepare_parallel:
        _JPS_RM_PREP.get_or_create_ptr()[][].store(
            _cell(prepare_parallel.value())
        )
    if chain_fill_elide:
        _JPS_RM_ELIDE.get_or_create_ptr()[][].store(
            _cell(chain_fill_elide.value())
        )
    if cap_nearest:
        _JPS_RM_CAP.get_or_create_ptr()[][].store(_cell(cap_nearest.value()))
    if force:
        _JPS_RM_FORCE.get_or_create_ptr()[][].store(_cell(force.value()))


def residual_mark_key_share_on() raises -> Bool:
    """Borrow the key columns? On unless configured off."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RM_SHARE.get_or_create_ptr()[][].load()) != 2


def residual_mark_prepare_parallel_on() raises -> Bool:
    """Fill the buffers in a fanned wave? On unless configured off."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RM_PREP.get_or_create_ptr()[][].load()) != 2


def residual_mark_chain_fill_elide_on() raises -> Bool:
    """Skip the chain-link zero fill? On unless configured off."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RM_ELIDE.get_or_create_ptr()[][].load()) != 2


def residual_mark_cap_nearest_on() raises -> Bool:
    """Halve a near-power-of-two table? Off unless configured on."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RM_CAP.get_or_create_ptr()[][].load()) == 1


def residual_mark_force_on() raises -> Bool:
    """The FORCE test hook. Off unless configured on."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    return Int(_JPS_RM_FORCE.get_or_create_ptr()[][].load()) == 1


def residual_mark_fill_morsel() raises -> Int:
    """The fill wave's grain in elements."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    var v = Int(_JPS_RM_FILL.get_or_create_ptr()[][].load())
    return v if v > 0 else RESIDUAL_MARK_FILL_MORSEL_DEFAULT


def reset_join_probe_settings() raises:
    """TEST-ONLY. Every setting back to its default."""
    # SAFETY: FFI carve-out (see `mk_probe_configure`).
    _JPS_BATCH.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_MORSEL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RETILE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_SHARE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_PREP.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_ELIDE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_CAP.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_FORCE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JPS_RM_FILL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
