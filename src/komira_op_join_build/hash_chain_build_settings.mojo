# =============================================================================
# hash_chain_build_settings -- the process settings of the parallel chained-hash
# build (`hash_chain_parallel_build`): which build serves a join, and who fills
# the chain-head table
# =============================================================================
#
# FLAGS, NOT ENVIRONMENT VARIABLES. A host sets these once per process from its
# flags, before any join builds; nothing here reads the environment. Each is a
# process-global read with one relaxed load, resolved ONCE per build by the
# driver and never inside a wave.
#
#   * THE BUILD MODE (`join_parallel_build_configure`):
#       AUTO  (the default) the parallel build above
#             `JOIN_BUILD_PARALLEL_THRESHOLD` rows, the serial build below;
#       OFF   the serial build always (the rollback);
#       FORCE the parallel build at any size, at a ONE-ROW morsel grain, and
#             the fanned fill at any table size. A TEST HOOK: it is what lets a
#             fixture-sized build fan across every worker.
#   * THE CHAIN-HEAD FILL (`join_ht_fill_configure`): fanned across the pool
#     (the default) or one `memset` on the driver before the build fork (the
#     A/B baseline and the differential oracle, kept reachable on purpose:
#     both arms leave byte-identical tables at the build barrier). Its grain
#     in slots can be overridden for tests: at the default 16,384 every table
#     a unit fixture produces is ONE morsel, so the tiling arithmetic would be
#     reachable from no test.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import alloc, OwnedPointer


comptime JOIN_PARALLEL_BUILD_AUTO: Int = 0
comptime JOIN_PARALLEL_BUILD_OFF: Int = 1
comptime JOIN_PARALLEL_BUILD_FORCE: Int = 2

comptime JOIN_BUILD_PARALLEL_THRESHOLD: Int = 250_000
"""Below this build-row count the dispatch overhead exceeds the parallel-build
gain, so AUTO takes the serial build."""

comptime HT_FILL_MORSEL_SLOTS: Int = 16_384
"""The fill grain in SLOTS: 128 KiB of `memset` per claim against ~20 ns for
the `fetch_add` that claims it, so the per-morsel overhead is ~0.1%. Flat, not
pool-shaped: a driver/worker disagreement about the grain is how a fill wave
leaves a table TAIL uninitialised, and one flat constant cannot disagree with
itself."""


def _init_hcb_i64() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _HCB_MODE = _Global["komira_join_parallel_build_mode", _init_hcb_i64]
# 0 = not configured (fanned), -1 = driver memset, 1 = fanned.
comptime _HCB_FILL = _Global["komira_join_ht_fill_mode", _init_hcb_i64]
# 0 = not configured (`HT_FILL_MORSEL_SLOTS`), else the grain in slots.
comptime _HCB_FILL_GRAIN = _Global["komira_join_ht_fill_grain", _init_hcb_i64]


def join_parallel_build_configure(mode: Int) raises:
    """Set the build mode: `JOIN_PARALLEL_BUILD_AUTO`, `_OFF` or `_FORCE`.

    Raises on any other value.
    """
    if (
        mode != JOIN_PARALLEL_BUILD_AUTO
        and mode != JOIN_PARALLEL_BUILD_OFF
        and mode != JOIN_PARALLEL_BUILD_FORCE
    ):
        raise Error(
            "join_parallel_build_configure: unknown mode " + String(mode)
        )
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    _HCB_MODE.get_or_create_ptr()[][].store(Scalar[DType.int64](mode))


def join_parallel_build_mode() raises -> Int:
    """The build mode; `JOIN_PARALLEL_BUILD_AUTO` when never configured."""
    # SAFETY: FFI carve-out (see `join_parallel_build_configure`).
    return Int(_HCB_MODE.get_or_create_ptr()[][].load())


def join_ht_fill_configure(fanned: Bool, morsel_slots: Int = 0) raises:
    """Set who fills the chain-head table: fanned across the pool (the
    default) or the driver's single `memset`; and the fill grain in slots
    (`<= 0` keeps `HT_FILL_MORSEL_SLOTS`)."""
    # SAFETY: FFI carve-out (see `join_parallel_build_configure`).
    _HCB_FILL.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if fanned else -1))
    var g = morsel_slots if morsel_slots > 0 else 0
    _HCB_FILL_GRAIN.get_or_create_ptr()[][].store(Scalar[DType.int64](g))


def join_ht_fill_parallel_on() raises -> Bool:
    """Is the chain-head fill fanned? DEFAULT ON."""
    # SAFETY: FFI carve-out (see `join_parallel_build_configure`).
    return Int(_HCB_FILL.get_or_create_ptr()[][].load()) >= 0


def ht_fill_morsel_slots() raises -> Int:
    """The fill grain in slots: `HT_FILL_MORSEL_SLOTS` unless configured.

    Resolved ONCE per build by the driver and carried on
    `ChainBuildState.fill_morsel`, so the driver's morsel count and every
    worker's grain are the same value by construction."""
    # SAFETY: FFI carve-out (see `join_parallel_build_configure`).
    var g = Int(_HCB_FILL_GRAIN.get_or_create_ptr()[][].load())
    return g if g > 0 else HT_FILL_MORSEL_SLOTS


def reset_hash_chain_build_settings() raises:
    """TEST-ONLY. Every setting back to its default (AUTO, fanned fill, the
    default grain)."""
    # SAFETY: FFI carve-out (see `join_parallel_build_configure`).
    _HCB_MODE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _HCB_FILL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _HCB_FILL_GRAIN.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
