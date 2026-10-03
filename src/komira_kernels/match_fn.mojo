# =============================================================================
# match_fn.mojo — MatchFn[T, OP, NO_MATCH_SEL, LHS_VALID, RHS_VALID]:
#                  the comptime-templated predicate kernel trait
# =============================================================================
#
# Mirrors DuckDB's `TemplatedMatchLoop<NO_MATCH_SEL, T, OP,
# LHS_ALL_VALID, RHS_ALL_VALID>` template (`duckdb/src/common/row_operations/
# row_matcher.cpp:17-90`). The 4× validity-flag fanout deletes the per-row
# null-check branch at compile time, leaving the SIMD lane loop branch-free.
#
# Kernel-trait pattern:
#   - The hot-path method `eval_chunk(lhs, rhs, mut out_mask) -> Int` is
#     NON-RAISING. The `Int` return value is the count of matched rows.
#     The kernel writes the data bitmap (`out_mask`) lane-by-lane.
#     Errors caught at the operator boundary (one check per chunk).
#   - All input / output buffers are typed `PrimitiveArray[T]` / `Bitmap`;
#     NO `UnsafePointer` crosses any module boundary (the
#     encapsulation rule).
#
# Why the kernel writes a packed-bit MASK (`Bitmap`), not a selection vector
# ---------------------------------------------------------------------------
# The SIMD inner loop produces a packed-byte bitmap as its natural output:
# the comparison `lhs.gt(rhs)` yields a `SIMD[Bool, W]` mask whose lanes
# are byte-packed into a bitmap byte (matches the existing `eval_col_gt`
# shape in `komira_core.eval.comparison`). When the operator
# wants a selection vector (`NO_MATCH_SEL=True` per DuckDB's terminology),
# it materializes the sel-vector AFTER the SIMD loop via
# `filter_to_indices(bitmap)`. Keeping the kernel output uniform across
# both modes lets the kernel stay branch-free; the post-pass to sel-vector
# is a SIMD-friendly bit-scan that already exists.
#
# The `NO_MATCH_SEL: Bool` comptime parameter is carried on the trait to
# preserve the DuckDB-mirror brief and to enable future kernel variants
# that DIRECTLY emit a sel-vector for very-sparse predicates (a win
# for highly-selective filters). This ships only the bitmap-output
# path; `NO_MATCH_SEL=True` is reserved for forward compatibility (the
# operator wrapper handles the materialization either way).
#
# The `LHS_VALID` / `RHS_VALID` Bool matrix — 4 cells per (T, OP)
# ---------------------------------------------------------------
# Each (T, OP) combination produces 4 comptime monomorphizations of the
# kernel: (lhs_valid, rhs_valid) ∈ {(F,F), (F,T), (T,F), (T,T)}. The
# `(False, False)` cell is the tightest loop — no validity AND, pure
# compare-pack. The `(True, True)` cell ANDs the two validity bitmaps
# into the result mask before storing. Compile-time elimination of the
# validity branch is the entire performance argument.
#
# Mojo discipline:
#   - No `UnsafePointer` in any signature on this trait or its conformers.
#   - No wildcard origins (`MutAnyOrigin` / `ImmutAnyOrigin` / `MutExternalOrigin`)
#     anywhere — kernel state is pure-comptime + immutable inputs.
#   - File < 1000 LOC.
#   - `MatchFn(Movable, Copyable, Deinitable)`: per-worker
#     copies by value (mirrors `BinaryFn`'s shape).
# =============================================================================
#
# Comptime parameters
# -------------------
# Each `MatchFn` conformer carries five comptime parameters:
#
#   T: DType            -- the input column physical type (lhs and rhs match)
#   OP_TAG: UInt8       -- comparison-op tag (reuse `BIN_LT` / `BIN_LE` /
#                          `BIN_GT` / `BIN_GE` / `BIN_EQ` / `BIN_NE` from
#                          `komira_core.plan.expr`). The conformer asserts
#                          which tag it implements via the `OP_TAG` member.
#   NO_MATCH_SEL: Bool  -- True ⇒ the operator will additionally materialize
#                          a sel-vector of NON-matching rows (reserved;
#                          today informational). The kernel always writes
#                          a packed bitmap regardless.
#   LHS_VALID: Bool     -- True ⇒ lhs may contain nulls (validity bitmap is
#                          read and ANDed in). False ⇒ lhs validity is
#                          comptime-deleted — tightest loop.
#   RHS_VALID: Bool     -- same for rhs.
#   KERNEL_ID: UInt32   -- stable identifier (akin to BinaryFn's KERNEL_ID).
#                          Used by EXPLAIN and the (future) kernel registry.
#
# This ships INT64 + FLOAT64 binary comparison cells. UnaryMatchFn
# (IS_NULL / IS_NOT_NULL) lives in the same module as a SEPARATE trait;
# its 3-param shape is simpler (no rhs).
# =============================================================================

from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.primitive_array import PrimitiveArray


# =============================================================================
# MatchFn — binary predicate kernel
# =============================================================================


trait MatchFn(Movable, Copyable, Deinitable):
    """A typed binary-comparison predicate kernel: two input columns of the
    same physical type -> packed boolean mask.

    Conformers MUST provide:
      - `T: DType` -- comptime physical type of the lhs and rhs columns.
        this version is homogeneous (both sides same type). Mixed-type cells
        with promotion are followup.
      - `OP_TAG: UInt8` -- the comparison-op tag (`BIN_LT` / `BIN_LE` /
        `BIN_GT` / `BIN_GE` / `BIN_EQ` / `BIN_NE`).
      - `NO_MATCH_SEL: Bool` -- forward-compatibility marker for the
        operator wrapper. The kernel itself always writes a bitmap.
      - `LHS_VALID: Bool` / `RHS_VALID: Bool` -- the comptime validity
        flags. The kernel ANDs validity into the output mask only when
        the corresponding flag is True. The operator picks the right
        monomorphization based on `lhs.validity.is_some()` /
        `rhs.validity.is_some()` per chunk.
      - `KERNEL_ID: UInt32` -- a stable identifier (akin to BinaryFn's
        `KERNEL_ID`).
      - `name(self)` -- one-line human-readable kernel name for EXPLAIN.
      - `eval_chunk(self, lhs, rhs, mut out_mask) -> Int` -- the hot
        path. NON-RAISING. Reads `count == lhs.length == rhs.length`
        lanes from both inputs, writes `count` bits into `out_mask.data`
        (the data bitmap; validity is the operator's responsibility).
        Returns the number of set bits in the output (== match count).

    Null-handling model (this version)
    -------------------------------
    PROPAGATE: a row is a NON-match (output bit 0) if either input lane
    is null. The kernel ANDs validity into the comparison result.
    When `LHS_VALID == False` AND `RHS_VALID == False`, the validity AND
    is comptime-deleted — pure compare-pack loop.

    Hot-path autovectorization
    --------------------------
    Mojo 1.0.0b1's autovectorizer does NOT fire on unit-stride numeric
    loops. Each conformer's `eval_chunk` body MUST hand-stage SIMD via
    the `PrimitiveArray.load[width=W]` + `.gt() / .lt() / .eq()` cascade
    (see `komira_core.eval.comparison:eval_col_gt` for the
    canonical compare-pack shape). The built-in conformers in
    `builtin_match_fns.mojo` follow this template.

    Per-worker semantics
    --------------------
    `Copyable` — the operator builds N per-worker copies of the kernel
    struct (one per worker thread). The struct's fields (if any) are
    pure-data captures.
    """

    comptime T: DType
    comptime OP_TAG: UInt8
    comptime NO_MATCH_SEL: Bool
    comptime LHS_VALID: Bool
    comptime RHS_VALID: Bool
    comptime KERNEL_ID: UInt32

    def name(self) -> String:
        ...

    # ---- HOT PATH — NON-RAISING ----
    #
    # `lhs` and `rhs` are typed input arrays with `lhs.length == rhs.length`.
    # `out_mask` is a pre-allocated `Bitmap` of the same length (allocated
    # by the operator in raising context). The kernel writes the data
    # bits (1 = match, 0 = non-match) into `out_mask`. Returns the
    # number of matches.
    #
    # Validity is incorporated into the output bits per the comptime
    # flags `LHS_VALID` / `RHS_VALID`. When both are False, the kernel
    # body skips the validity-AND path entirely.
    def eval_chunk(
        self,
        lhs: PrimitiveArray[Self.T],
        rhs: PrimitiveArray[Self.T],
        mut out_mask: Bitmap,
    ) -> Int:
        ...


# =============================================================================
# UnaryMatchFn — IS_NULL / IS_NOT_NULL kernel
# =============================================================================


trait UnaryMatchFn(Movable, Copyable, Deinitable):
    """A typed unary-predicate kernel: one input column -> packed mask.

    Used for `IS_NULL` / `IS_NOT_NULL` predicates which inherently
    inspect validity rather than data; the comptime `INPUT_VALID`
    flag controls whether the kernel must read the input bitmap at
    all (an IS_NULL on a non-nullable input is trivially all-zeros).

    Conformers MUST provide:
      - `T: DType` -- comptime physical type of the input column.
      - `OP_TAG: UInt8` -- `UN_IS_NULL` / `UN_IS_NOT_NULL` from
        `komira_core.plan.expr`.
      - `INPUT_VALID: Bool` -- True ⇒ input may have validity bitmap.
        False ⇒ input is non-nullable (IS_NULL is trivially false,
        IS_NOT_NULL is trivially true — kernel body is comptime-elided).
      - `KERNEL_ID: UInt32` -- stable identifier.
      - `name(self)` -- one-line kernel name for EXPLAIN.
      - `eval_chunk(self, input, mut out_mask) -> Int` -- non-raising.
        Writes 1 bit per row; returns the number of set bits.
    """

    comptime T: DType
    comptime OP_TAG: UInt8
    comptime INPUT_VALID: Bool
    comptime KERNEL_ID: UInt32

    def name(self) -> String:
        ...

    def eval_chunk(
        self,
        input: PrimitiveArray[Self.T],
        mut out_mask: Bitmap,
    ) -> Int:
        ...
