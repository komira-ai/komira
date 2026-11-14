# =============================================================================
# residual_latemat_counter -- how many cells the residual join's predicate
# evaluation assembled (rows x columns), process-wide: the witness that the
# late-materialised arm assembled only the referenced columns.
# =============================================================================

from std.atomic import Atomic
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_residual_latemat_counter() -> OwnedPointer[Atomic[DType.int64]]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0. Mirrors `dict_mat_counter._init_dict_mat_counter`
    (`alloc` + `init_pointee_move` + `OwnedPointer(unsafe_from_raw_pointer=)`)
    since `Atomic` is not movable-by-value.
    """
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


comptime _RESIDUAL_LATEMAT_CELLS = _Global[
    "komira_residual_latemat_assembled_cells",
    _init_residual_latemat_counter,
]


@always_inline
def residual_mask_cells_incr(cells: Int) raises:
    """Record `cells` output cells assembled during residual-mask computation
    (rows × cols). One relaxed atomic add per residual join probe. `raises` only
    to propagate the stdlib `_Global.get_or_create_ptr` signature — never raises
    at runtime.
    """
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _RESIDUAL_LATEMAT_CELLS.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(cells))


def residual_mask_assembled_cells() raises -> Int:
    """Read the process-wide count of cells assembled for residual-mask eval."""
    # SAFETY: FFI carve-out (see `residual_mask_cells_incr`).
    var gp = _RESIDUAL_LATEMAT_CELLS.get_or_create_ptr()
    return Int(gp[][].load())


def reset_residual_mask_assembled_cells() raises:
    """Reset the process-wide assembled-cell count to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `residual_mask_cells_incr`).
    var gp = _RESIDUAL_LATEMAT_CELLS.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
