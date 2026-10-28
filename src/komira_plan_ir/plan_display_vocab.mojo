# =============================================================================
# plan_display_vocab — the vocabulary writers `plan_display` renders with
# =============================================================================
#
# Moved out of `plan_display.mojo` unchanged, to keep that file under 1,000
# lines. `plan_display` imports every name below.
# =============================================================================

from komira_plan_ir.logical_plan import (
    AsofTolerance,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    ASOF_TOL_NONE,
    ASOF_TOL_INT64,
    ASOF_TOL_FLOAT64,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_NDJSON,
    SOURCE_IN_MEMORY,
    SOURCE_JSON,
    SOURCE_ORC,
    SOURCE_AVRO,
    SOURCE_ARROW,
    SOURCE_BINDING,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_HASH,
    JOIN_ALGO_SORT_MERGE,
)
from komira_plan_expr.render_text import write_quoted


# =============================================================================
# ⚠ THE VOCABULARY HELPERS BELOW **WRITE**; THEY DO NOT **RETURN**.
# =============================================================================
#
# The shape these helpers avoid is `def _<thing>_name(v: UInt8) -> String` —
# an if/elif ladder returning a string LITERAL per arm — with the call site
# reading `writer.write("Join(type=", _join_type_name(...))`. In a shared
# library (`_komira.{dylib,so}`) that shape can crash: a query with a JOIN
# SIGSEGV'd at 0x4 on mac and aborted in `alloc` on linux.
#
# MEASURED CAUSE (lldb, on the shipped dylib):
#
#     cmp  x8, #0x6
#     b.hi <UNKNOWN arm>
#     adrp/add x9, <TABLE A>   ;  ldr x23, [x9, x8, lsl #3]   -> the POINTER
#     adrp/add x9, <TABLE B>   ;  ldr x24, [x9, x8, lsl #3]   -> the LENGTH
#
# The compiler lowers an N-arm literal-returning ladder into TWO PARALLEL
# CONSTANT ARRAYS — one of `ptr`, one of `len` — and binds the site's two
# references INDEPENDENTLY. In the shared library those two bindings CROSSED:
# x23 (the pointer operand) loaded 4 out of a LENGTH-shaped array, and x24 (the
# length operand) loaded a POINTER out of another ladder's pointer array.
# `String.__iadd__` then dereferenced 4. The expected length array was ABSENT
# FROM THE LIBRARY ENTIRELY and PRESENT in an executable built from the same
# sources — so this is `mojo build --emit shared-lib`, not this file.
#
# ⚠ IT IS NOT ONE SITE'S BUG. The binding is a property of the WHOLE program,
# so which literal-returning ladder gets crossed can change on every build.
# Fixing one site would dodge one crash and leave the next render to take it.
#
# THE SHAPE THAT DEFEATS IT: the arm WRITES its literal instead of RETURNING
# it. No value crosses a boundary, so there is nothing to select and no
# parallel arrays are synthesised — every call becomes `bl write_string` with
# an IMMEDIATE length. Verified by disassembly, not by "it stopped crashing":
# a standalone shared lib built from the returning shape emits 4
# register-indexed constant-array loads and the writing shape emits 0.
#
# ⚠ THE RENDERED BYTES ARE UNCHANGED, and they must be — this render IS the
# input to `LogicalPlan.structural_hash` (logical_plan.mojo), which is the
# plan-compile cache key. A changed byte here silently re-buckets every
# cached plan.
# =============================================================================


def _write_source_type[W: Writer](mut writer: W, st: UInt8):
    """Human-readable source type name.

    ⚠ EVERY `SOURCE_*` CONSTANT MUST HAVE AN ARM HERE. This ladder's `else`
    does not fail — it prints `UNKNOWN` — so a constant added to
    `logical_plan.mojo` without a matching arm here degrades EXPLAIN silently
    AND (because the render IS the `structural_hash` input) merges the new
    source type into the same hash bucket as every other unnamed type.

    ⚠ A REPOSITORY LINT ANCHORS ON THIS FUNCTION'S NAME: it locates the ladder
    with `^def _write_source_type[` and checks that every `SOURCE_*` token is
    named in the body. Renaming this function without updating that lint turns
    arm coverage OFF rather than red.
    """
    if st == SOURCE_PARQUET:
        writer.write("PARQUET")
    elif st == SOURCE_CSV:
        writer.write("CSV")
    elif st == SOURCE_NDJSON:
        writer.write("NDJSON")
    elif st == SOURCE_IN_MEMORY:
        writer.write("IN_MEMORY")
    elif st == SOURCE_JSON:
        writer.write("JSON")
    elif st == SOURCE_ORC:
        writer.write("ORC")
    elif st == SOURCE_AVRO:
        writer.write("AVRO")
    elif st == SOURCE_ARROW:
        writer.write("ARROW")
    elif st == SOURCE_BINDING:
        # "not one of the legacy enum's kinds — consult `binding_ref()
        # .kind_id`". The binding's own reverse-DNS `kind_name` is rendered
        # alongside, by the `binding=` field this node also emits, so EXPLAIN
        # still names the concrete kind.
        writer.write("BINDING")
    else:
        writer.write("UNKNOWN")


def _write_source_kind[W: Writer](mut writer: W, sk: UInt8):
    """Human-readable source-kind annotation. One of `COLUMNAR` (Hierarchy A:
    Parquet, Arrow IPC, InMemory) or `ROW` (Hierarchy B: CSV, NDJSON,
    future row-decoded sources)."""
    if sk == SOURCE_KIND_COLUMNAR:
        writer.write("COLUMNAR")
    elif sk == SOURCE_KIND_ROW:
        writer.write("ROW")
    else:
        writer.write("UNKNOWN")


def _write_join_type[W: Writer](mut writer: W, jt: UInt8):
    """Human-readable join type name."""
    if jt == JOIN_INNER:
        writer.write("INNER")
    elif jt == JOIN_LEFT:
        writer.write("LEFT")
    elif jt == JOIN_RIGHT:
        writer.write("RIGHT")
    elif jt == JOIN_FULL:
        writer.write("FULL")
    elif jt == JOIN_SEMI:
        writer.write("SEMI")
    elif jt == JOIN_ANTI:
        writer.write("ANTI")
    elif jt == JOIN_CROSS:
        writer.write("CROSS")
    else:
        writer.write("UNKNOWN")


def _write_join_algo[W: Writer](mut writer: W, algo: UInt8):
    """Human-readable join-algorithm name."""
    if algo == JOIN_ALGO_AUTO:
        writer.write("AUTO")
    elif algo == JOIN_ALGO_HASH:
        writer.write("HASH")
    elif algo == JOIN_ALGO_SORT_MERGE:
        writer.write("SORT_MERGE")
    else:
        writer.write("UNKNOWN")


def _write_asof_strategy[W: Writer](mut writer: W, s: UInt8):
    """Human-readable ASOF match strategy name."""
    if s == ASOF_BACKWARD:
        writer.write("BACKWARD")
    elif s == ASOF_FORWARD:
        writer.write("FORWARD")
    elif s == ASOF_NEAREST:
        writer.write("NEAREST")
    else:
        writer.write("UNKNOWN")


def _write_asof_tolerance[W: Writer](mut writer: W, tol: AsofTolerance):
    """ASOF tolerance: its tag AND the value the tag selects (`INT64(5)`,
    `FLOAT64(0.5)`). The value is plan identity -- see the PLAN_ASOF_JOIN arm.
    """
    var t = tol.tag
    if t == ASOF_TOL_NONE:
        writer.write("NONE")
    elif t == ASOF_TOL_INT64:
        writer.write("INT64(", tol.int_val, ")")
    elif t == ASOF_TOL_FLOAT64:
        writer.write("FLOAT64(", tol.float_val, ")")
    else:
        # An unknown tag keeps both payload slots so two unknown tolerances
        # still render apart.
        writer.write(
            "UNKNOWN(tag=", Int(t), ", ", tol.int_val, ", ", tol.float_val, ")"
        )


def _write_sort_hint[W: Writer](
    mut writer: W, keys: List[String], desc: List[Bool]
):
    """An as-of pre-sort hint: the keys, then the per-key directions as their
    own list (`["k", "ts"]/[F, T]`). The two lists are written separately so a
    length mismatch between them still reaches the render. Each key is QUOTED
    (`write_quoted`): a raw key `k, ts` rendered like the two keys `k`, `ts`,
    and a key could spell `]/[F], right_sorted=[…` and forge the other hint."""
    writer.write("[")
    for i in range(len(keys)):
        if i > 0:
            writer.write(", ")
        write_quoted(writer, keys[i])
    writer.write("]/[")
    for i in range(len(desc)):
        if i > 0:
            writer.write(", ")
        writer.write("T" if desc[i] else "F")
    writer.write("]")
