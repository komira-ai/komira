# =============================================================================
# hbs_key_share_counter — arm witness for `HashBuildSink`'s build-key
# extraction (`hbs_key_extract`)
# =============================================================================
#
# Two process-global counters, each an `Atomic[int64]` created once per
# process in a stdlib `_Global` slot.
#
# ⚠ WHY A COUNTER AND NOT AN ASSERTION ON THE ANSWER. The share cannot change
# a value: the shared `PrimitiveArray` reads byte-identically to the copy
# (every value accessor indexes `self.offset + i`), which is exactly what makes
# it safe and exactly what makes it INVISIBLE to a byte-equivalence oracle. A
# test that only compares join output passes with the route wired to nothing.
# These cells are the falsifier: they say WHICH arm ran.
#
#   * SHARE   — `Column.share_as_primitive` served the extraction and the
#               200 MB copy did not happen.
#   * SHAPE   — `can_share_as_primitive[int64]()` REFUSED the column (it
#               carries a validity bitmap, or its storage type is not
#               INT64-compatible), so the copy ran. This is the cell that tells
#               you a route measured at zero was never REACHED rather than
#               worth nothing.
#
# Their sum is the number of `_extract_build_key_array` calls in the process,
# so a conservation check (`share + shape == extractions`) is available to any
# test that knows how many builds it drove.
#
# The `[HBS_KEY]` line `_extract_build_key_array` prints when its caller passes
# `marker_on` carries the same verdict per invocation plus the DISAMBIGUATING
# terms (`nullable=`, `type=`), which is why SHAPE is not split further here.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_hbs_share() -> OwnedPointer[AtomicI64]:
    # SAFETY: `alloc` returns one uninitialised `AtomicI64` slot, owned by
    # this function until the `OwnedPointer` below takes it. The zero write
    # initialises it through an int64 view of the same bytes (an `AtomicI64`
    # holds one int64). From then on the returned `OwnedPointer` owns the
    # slot and frees it when it is destroyed; `_Global` keeps that
    # `OwnedPointer` in its process-global slot.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_hbs_shape() -> OwnedPointer[AtomicI64]:
    # SAFETY: as `_init_hbs_share`.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _HBS_KEY_SHARE = _Global[
    "komira_dispatch_hbs_key_share", _init_hbs_share
]
comptime _HBS_KEY_DECLINE_SHAPE = _Global[
    "komira_dispatch_hbs_key_decline_shape", _init_hbs_shape
]


@always_inline
def hbs_key_share_incr() raises:
    """Record one build-key extraction served by the zero-copy SHARE arm."""
    # SAFETY: `_Global.get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the untracked origin is the stdlib API's own
    # return type, confined to this helper.
    var gp = _HBS_KEY_SHARE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def hbs_key_share_count() raises -> Int:
    """Read the process-wide SHARE-arm count."""
    # SAFETY: as `hbs_key_share_incr`.
    var gp = _HBS_KEY_SHARE.get_or_create_ptr()
    return Int(gp[][].load())


@always_inline
def hbs_key_decline_shape_incr() raises:
    """Record one extraction that copied because
    `Column.can_share_as_primitive[int64]()` REFUSED the column."""
    # SAFETY: as `hbs_key_share_incr`.
    var gp = _HBS_KEY_DECLINE_SHAPE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def hbs_key_decline_shape_count() raises -> Int:
    """Read the process-wide accessor-refused decline count."""
    # SAFETY: as `hbs_key_share_incr`.
    var gp = _HBS_KEY_DECLINE_SHAPE.get_or_create_ptr()
    return Int(gp[][].load())
