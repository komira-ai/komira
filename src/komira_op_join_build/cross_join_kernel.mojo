# =============================================================================
# cross_join_kernel -- the CROSS-join (Cartesian product) kernel over two
# resident batches
# =============================================================================
#
# THE MATH IS A CARTESIAN PRODUCT, NOTHING MORE. A CROSS join of an M-row LEFT
# batch and an N-row RIGHT batch emits M x N rows: left row `i` paired with
# every right row `j`, row-major. The kernel builds the index pair
# (left_indices[k], right_indices[k]) for k in 0..M*N and hands it to
# `komira_join_assembly`'s `assemble_join_result`, the same post-probe gather
# every join assembler uses, with both sides NON-nullable: a Cartesian product
# never produces a -1 index, so there are no NULL fills (the structural
# difference from LEFT/RIGHT/FULL). `assemble_join_result` gathers every DType
# (fixed-width and STRING), so the kernel has no per-type code.
#
# THE OUTPUT SCHEMA is the standard join layout for a non-SEMI/ANTI join: all
# LEFT columns verbatim, then all RIGHT columns with a `_right` suffix on name
# collisions, source nullability preserved (a CROSS does not force nullability:
# every (i, j) pair is a real row). The caller passes it in, so the kernel
# stays schema-agnostic.
#
# The two batches come in by `ref` (read-only borrow), the output schema by
# value. No pointer in any signature.
# =============================================================================

from std.collections import List

from komira_arrow.schema import Schema, RecordBatch
from komira_join_assembly.compiler_join_assembly import assemble_join_result


def cross_join_cartesian(
    ref left: RecordBatch,
    ref right: RecordBatch,
    var out_schema: Schema,
) raises -> RecordBatch:
    """Emit the CROSS-join (Cartesian product) of two RESIDENT batches.

    For an M-row `left` and an N-row `right`, returns an M×N-row batch where left
    row `i` is paired with every right row `j` (row-major: all of right for left 0,
    then all of right for left 1, ...). `out_schema` is the standard join output
    schema (`LogicalPlan.join` for a non-SEMI/ANTI join: left cols verbatim + right
    cols `_right`-renamed on collision, source nullability preserved).

    Drives `assemble_join_result` with both sides non-nullable
    (a Cartesian product never yields a -1 index — there are no NULL rows; this is
    the structural difference from LEFT/RIGHT/FULL). Every DType (fixed-width +
    STRING) flows through `assemble_join_result`'s `emit_gather_column_projected`.

    The empty-side cases collapse correctly: M==0 or N==0 -> 0 output rows (the
    index lists are empty and `assemble_join_result` emits a 0-row batch with the
    output schema)."""
    var m = left.num_rows()
    var n = right.num_rows()
    var total = m * n

    # ---- Build the Cartesian index pair --------------------------------------
    # left_indices = [0]*N ++ [1]*N ++ ... ++ [M-1]*N  (each left row repeated N×)
    # right_indices = ([0,1,...,N-1]) repeated M× (the right block re-scanned per
    # left row).
    var left_indices = List[Int](capacity=total)
    var right_indices = List[Int](capacity=total)
    for i in range(m):
        for j in range(n):
            left_indices.append(i)
            right_indices.append(j)

    var result = assemble_join_result(
        left,
        right,
        left_indices,
        right_indices,
        out_schema^,
        left_nullable=False,
        right_nullable=False,
    )
    return result^
