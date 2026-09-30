# =============================================================================
# Regression test: `c_data_interface.mojo` export/release does not leak
# =============================================================================
#
# The hazard: `export_schema()` heap-allocates `format` + `name` C strings via
#   `_copy_string_to_c`; `export_primitive()` heap-allocates a `bufs` array.
#   If `release` is stubbed as a null pointer, the Arrow C Data Interface
#   release protocol never runs and every export leaks the heap-allocated
#   bytes.
#
# The contract: a callable `release` is installed at export time, and
#   `release_c_schema()` / `release_c_array()` helpers walk the struct, free
#   every heap allocation this module made, and null the `release` member per
#   the Arrow spec.
#
# This test checks it in two ways:
#   1. Spec-compliance assertion — post-export, `release` is non-NULL
#      (struct is "live" per Arrow spec); post-release, `release` is
#      NULL and `format` / `name` / `buffers` are NULL (struct is
#      "released").
#   2. Repeated alloc/release cycle — exports + releases N times in a
#      loop and asserts the test does not crash and the structs are
#      always in the spec-correct state. A leaking export would lose ~80
#      bytes per iteration; a correct one is an alloc-balanced cycle.
#
# STORAGE. Every exported struct below lives on the HEAP and is read back
# THROUGH ITS POINTER. A stack local passed as
# `UnsafePointer(to=local).unsafe_origin_cast[MutExternalOrigin]()` to
# `release_c_*` and then read afterwards is the pattern
# `drain_record_batch_stream` documents as unsound ("Mojo does not extend `c`'s
# lifetime through the UnsafePointer, so the compiler is free to reuse the
# stack slot"), and a wildcard-origin cast severs lifetime tracking. The
# consequence is concrete: a crash in `TCMallocInternalCfree` — the release
# NULLs the fields through the pointer while the idempotence check reads a
# STALE non-NULL `release` out of the compiler's copy, so the second
# `release_c_*` frees already-freed memory. Heap storage + pointer reads make
# the release protocol observable exactly as a real C consumer sees it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.memory import alloc

from komira_core.arrow import (
    ArrowType,
    Field,
    PrimitiveArray,
    CArrowSchema,
    CArrowArray,
    export_schema,
    export_primitive,
    release_c_schema,
    release_c_array,
)


# =============================================================================
# Spec-compliance: export -> live; release -> released
# =============================================================================


def test_export_schema_release_is_live_post_export() raises:
    """After export_schema, the CArrowSchema `release` member is non-NULL,
    per the Arrow C Data Interface 'live struct' contract."""
    var field = Field("x", ArrowType.INT32, nullable=False)
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(export_schema(field))

    assert_false(sp[].is_released())
    assert_true(Int(sp[].release) != 0)

    # Cleanup so the test itself does not leak.
    release_c_schema(sp)
    sp.free()


def test_export_schema_release_nulls_format_and_name() raises:
    """After release_c_schema, the heap-allocated format + name strings
    are freed and the pointers are NULL."""
    var field = Field("my_column", ArrowType.INT64, nullable=True)
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(export_schema(field))

    # Pre-release: format + name are heap-allocated.
    assert_true(Int(sp[].format) != 0)
    assert_true(Int(sp[].name) != 0)

    release_c_schema(sp)

    # Post-release: spec requires `release` NULL; our impl also nulls
    # `format` + `name` so a use-after-release is more likely to trap.
    assert_true(sp[].is_released())
    assert_equal(Int(sp[].release), 0)
    assert_equal(Int(sp[].format), 0)
    assert_equal(Int(sp[].name), 0)
    sp.free()


def test_export_schema_release_idempotent() raises:
    """release_c_schema is idempotent — calling it twice is safe."""
    var field = Field("x", ArrowType.FLOAT64, nullable=False)
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(export_schema(field))

    release_c_schema(sp)
    assert_true(sp[].is_released())

    # Second release: must be a no-op (no double-free).
    release_c_schema(sp)
    assert_true(sp[].is_released())
    sp.free()


def test_export_primitive_release_is_live_post_export() raises:
    """After export_primitive, the CArrowArray `release` member is
    non-NULL, per the Arrow C Data Interface 'live struct' contract."""
    var arr = PrimitiveArray[DType.int32].allocate(16)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(export_primitive[DType.int32](arr))

    assert_false(ap[].is_released())
    assert_true(Int(ap[].release) != 0)

    release_c_array(ap)
    ap.free()


def test_export_primitive_release_frees_buffers_array() raises:
    """After release_c_array, the heap-allocated `buffers` array is
    freed and the pointer is NULL. (The buffer BYTES are NOT freed —
    they belong to the source PrimitiveArray.)"""
    var arr = PrimitiveArray[DType.int64].allocate(32)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(export_primitive[DType.int64](arr))

    # Pre-release: buffers array is heap-allocated.
    assert_true(Int(ap[].buffers) != 0)

    release_c_array(ap)

    # Post-release: spec requires `release` NULL; our impl also nulls
    # `buffers` so a use-after-release is more likely to trap.
    assert_true(ap[].is_released())
    assert_equal(Int(ap[].release), 0)
    assert_equal(Int(ap[].buffers), 0)
    ap.free()


def test_export_primitive_release_idempotent() raises:
    """release_c_array is idempotent — calling it twice is safe."""
    var arr = PrimitiveArray[DType.float64].allocate(8)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(export_primitive[DType.float64](arr))

    release_c_array(ap)
    assert_true(ap[].is_released())

    # Second release: must be a no-op (no double-free).
    release_c_array(ap)
    assert_true(ap[].is_released())
    ap.free()


# =============================================================================
# Repeated alloc/release cycle — leak-detection proxy
# =============================================================================
#
# Without the release machinery, every iteration would leak ~80 bytes
# (schema: format string + name string; array: 2-slot buffers void**).
# Across 1000 iterations this is ~80 KB — small but real. With the
# release machinery in place, every iteration is alloc-balanced.
#
# The test here is NOT a hard leak detector (Mojo lacks ASAN-style
# instrumentation surfaced to user code), but a behavioral assertion
# that the export+release cycle completes without crash, that every
# exported struct ends in the "released" state, and that the test
# pattern can run for N iterations without corruption (which is the
# observable signal a leak would produce by exhausting tcmalloc heap
# or by stale-pointer-reuse corruption).


def test_export_schema_release_cycle_1000_iterations() raises:
    """1000 export/release cycles of a primitive schema."""
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    for _ in range(1000):
        var field = Field("col", ArrowType.INT32, nullable=False)
        sp.unsafe_write(export_schema(field))
        assert_false(sp[].is_released())
        release_c_schema(sp)
        assert_true(sp[].is_released())
    sp.free()


def test_export_primitive_release_cycle_1000_iterations() raises:
    """1000 export/release cycles of a primitive array."""
    var arr = PrimitiveArray[DType.int32].allocate(64)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    for _ in range(1000):
        ap.unsafe_write(export_primitive[DType.int32](arr))
        assert_false(ap[].is_released())
        release_c_array(ap)
        assert_true(ap[].is_released())
    ap.free()


def test_export_primitive_nullable_release_cycle() raises:
    """Nullable-array export/release cycle exercises the validity-bitmap
    path of the buffers array."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(16)
    arr._set_null(3)
    arr.null_count = 1
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    for _ in range(100):
        ap.unsafe_write(export_primitive[DType.int32](arr))
        assert_false(ap[].is_released())
        # buffers[0] (validity) is non-NULL for nullable arrays.
        var validity_ptr = (ap[].buffers + 0)[]
        assert_true(Int(validity_ptr) != 0)
        release_c_array(ap)
        assert_true(ap[].is_released())
    ap.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
