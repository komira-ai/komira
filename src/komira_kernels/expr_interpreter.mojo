# =============================================================================
# expr_interpreter.mojo — generic Expr-tree interpreter (fallback path)
# =============================================================================
#
# The interpreter is the fallback
# path for Expr shapes that do NOT match a templated kernel (returned by
# `_match_expr_to_kernel_template` in `optimizer_expr.mojo` as
# `Optional.none()`). The interpreter is ~5-10 ns/lane vs the
# template path's ~0.5 ns/lane — much slower than the templates but correct
# for arbitrary Expr trees.
#
# Scope:
#   - Recursive scalar interpretation of Expr trees over a typed row context.
#   - Supports BIN_ADD/SUB/MUL/DIV/MOD on F64+I64; BIN_GT/GE/LT/LE/EQ/NE on
#     same; BIN_AND/OR/NOT for boolean composition; UN_NEGATE; EXPR_LITERAL
#     evaluation; EXPR_COL_REF resolution via a callback.
#   - Returns a typed `EvalScalar` carrying the result + dtype tag.
#
# Out of scope:
#   - SIMD-chunk vectorized interpreter (this file ships scalar only;
#     vectorization at the chunk level happens at the engine boundary
#     where the morsel executor has access to typed PrimitiveArray slices).
#   - String / Date32 / Timestamp / Decimal128 / nested compounds —
#     these route through the engine evaluator (the RecordBatch-aware
#     bridge).
#   - EXPR_CAST runtime evaluation — the cast templates (37-44) cover the
#     common dtype pairs; uncommon casts also route through the engine path.
#
# Design rule: even the generic walker inlines into a single loop body;
# the only cost is the per-node dispatch inside the walker. The chunk-fused
# version
# moves the per-node dispatch out of the inner loop entirely.
#
# Encapsulation rule: no UnsafePointer in any signature here.
# The interpreter operates on Expr value semantics + a typed `EvalScalar`
# return value. Source-of-truth for ColRef resolution is the optional
# `EvalContext` callback the caller threads in.
# =============================================================================

from std.ffi import external_call

from komira_core.eval.cast_null import round_half_to_even
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_ABS,
    UN_SIGN,
    UN_BIT_COUNT,
    UN_TRUNC,
    UN_ROUND,
    UN_IS_NOT_NULL,
)


# =============================================================================
# EvalScalar — the typed result of an interpreted Expr node.
#
# Carries one of: Int64 / Float64 / Bool / String. The `kind` discriminator
# tells the caller which slot is populated. Mirrors `ScalarValue` but is
# specifically the runtime VALUE (no plan-side metadata like decimal
# precision/scale) and is local to the interpreter.
# =============================================================================

comptime EVAL_KIND_NULL: Int = 0
comptime EVAL_KIND_INT: Int = 1
comptime EVAL_KIND_FLOAT: Int = 2
comptime EVAL_KIND_BOOL: Int = 3
comptime EVAL_KIND_STRING: Int = 4


@fieldwise_init
struct EvalScalar(Copyable, Movable):
    """The runtime result of one Expr-interpreter step.

    One of `int_val` / `float_val` / `bool_val` / `string_val` is populated
    per `kind`. NULL is `kind == EVAL_KIND_NULL` (other slots ignored).
    """
    var kind: Int
    var int_val: Int64
    var float_val: Float64
    var bool_val: Bool
    var string_val: String

    @staticmethod
    @always_inline
    def from_int(v: Int64) -> EvalScalar:
        return EvalScalar(EVAL_KIND_INT, v, 0.0, False, String(""))

    @staticmethod
    @always_inline
    def from_float(v: Float64) -> EvalScalar:
        return EvalScalar(EVAL_KIND_FLOAT, 0, v, False, String(""))

    @staticmethod
    @always_inline
    def from_bool(v: Bool) -> EvalScalar:
        return EvalScalar(EVAL_KIND_BOOL, 0, 0.0, v, String(""))

    @staticmethod
    @always_inline
    def from_string(v: String) -> EvalScalar:
        return EvalScalar(EVAL_KIND_STRING, 0, 0.0, False, v)

    @staticmethod
    @always_inline
    def null() -> EvalScalar:
        return EvalScalar(EVAL_KIND_NULL, 0, 0.0, False, String(""))

    @always_inline
    def as_float(self) -> Float64:
        """Best-effort numeric coercion to Float64. Used for arithmetic that
        mixes Int and Float operands."""
        if self.kind == EVAL_KIND_FLOAT:
            return self.float_val
        if self.kind == EVAL_KIND_INT:
            return Float64(self.int_val)
        return 0.0

    @always_inline
    def as_int(self) -> Int64:
        """Best-effort numeric coercion to Int64."""
        if self.kind == EVAL_KIND_INT:
            return self.int_val
        if self.kind == EVAL_KIND_FLOAT:
            return Int64(self.float_val)
        return 0

    @always_inline
    def is_numeric(self) -> Bool:
        return self.kind == EVAL_KIND_INT or self.kind == EVAL_KIND_FLOAT


# =============================================================================
# RowContext — minimal column-resolver shim for the interpreter.
#
# The interpreter needs to resolve `EXPR_COL_REF("x")` to a value. The
# callsite (a chunk loop driver, a single-row test, etc.) provides the
# resolution via a simple `(name) -> EvalScalar` callback.
#
# Here this is a struct holding a lookup table; the engine can swap it
# for a SimdOf-backed resolver that reads
# from typed PrimitiveArray slices.
# =============================================================================


@fieldwise_init
struct RowContext(Copyable, Movable):
    """Column-name → EvalScalar resolution for one row.

    Pre-populated by the caller (test fixture or chunk loop driver).
    For tests, build via `RowContext.empty()` then call `.set_*` per column.
    """
    var col_names: List[String]
    var col_values: List[EvalScalar]

    @staticmethod
    def empty() -> RowContext:
        return RowContext(List[String](), List[EvalScalar]())

    def set_int(mut self, name: String, v: Int64):
        self.col_names.append(name)
        self.col_values.append(EvalScalar.from_int(v))

    def set_float(mut self, name: String, v: Float64):
        self.col_names.append(name)
        self.col_values.append(EvalScalar.from_float(v))

    def set_bool(mut self, name: String, v: Bool):
        self.col_names.append(name)
        self.col_values.append(EvalScalar.from_bool(v))

    def set_string(mut self, name: String, v: String):
        self.col_names.append(name)
        self.col_values.append(EvalScalar.from_string(v))

    def lookup(self, name: String) -> EvalScalar:
        """Return the value of column `name`, or NULL if absent."""
        for i in range(len(self.col_names)):
            if self.col_names[i] == name:
                return self.col_values[i].copy()
        return EvalScalar.null()


# =============================================================================
# `interpret_expr` — recursive Expr-tree walker.
#
# The interpreter walks `expr` recursively; for each node:
#   - EXPR_LITERAL: lift `ScalarValue` → `EvalScalar`.
#   - EXPR_COL_REF: look up via `ctx.lookup(name)`.
#   - EXPR_BINARY_OP: recurse on left + right, dispatch on op + operand
#     dtypes, return result.
#   - EXPR_UNARY_OP: recurse on child, dispatch on op, return.
#   - EXPR_CAST: recurse on child, convert via `EvalScalar.as_*`.
#   - EXPR_ALIAS: recurse through (alias is a name-rebind, not a value op).
#   - other tags (EXPR_WHEN / EXPR_IN_LIST / EXPR_REGEXP / etc.):
#     return NULL with a comment — these route through the legacy engine
#     evaluator at the morsel-executor layer.
#
# All arithmetic on mixed Int/Float operands coerces to Float64 (matches
# Python / SQL implicit coercion for arithmetic). Comparisons coerce
# similarly; string compare is byte-equality only (no lex-order in scalar
# interpreter — that's indirect-handle territory).
# =============================================================================


def interpret_expr(expr: Expr, ctx: RowContext) -> EvalScalar:
    """Interpret one Expr node against `ctx`. Returns the typed result.

    Recursive. Inlines `comptime if` cascades for op dispatch; the hot loop
    is the per-node dispatch ladder. ~5-10 ns/lane in
    aggregate when inlined.
    """
    if expr.tag == EXPR_LITERAL:
        var sv = expr.literal_value()
        if sv.dtype == DType.float64 or sv.dtype == DType.float32:
            return EvalScalar.from_float(sv.float_val)
        # Carry ALL Int64-family integers (int8/16/32/64
        # + uint8/16/32) — their value is in int_val. uint64 is excluded
        # (fits_int64_family()) and falls through to null (no signed carry).
        if sv.fits_int64_family():
            return EvalScalar.from_int(sv.int_val)
        if sv.dtype == DType.bool:
            return EvalScalar.from_bool(sv.bool_val)
        # Use is_string() (kind-based) so the empty string is a real
        # value and a NULL is NOT mistaken for one. A NULL (or any not-yet-
        # interpretable extended kind) falls through to EvalScalar.null().
        if sv.is_string():
            return EvalScalar.from_string(sv.string_val.copy())
        return EvalScalar.null()

    if expr.tag == EXPR_COL_REF:
        return ctx.lookup(expr.col_ref_name())

    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        var left = interpret_expr(expr.binary_left_ref(), ctx)
        var right = interpret_expr(expr.binary_right_ref(), ctx)
        return _eval_binary(op, left^, right^)

    if expr.tag == EXPR_UNARY_OP:
        var u_op = expr.unary_op()
        var child = interpret_expr(expr.unary_child_ref(), ctx)
        return _eval_unary(u_op, child^)

    if expr.tag == EXPR_CAST:
        var child = interpret_expr(expr.cast_child_ref(), ctx)
        var tgt = expr.cast_target()
        return _eval_cast(child^, tgt)

    if expr.tag == EXPR_ALIAS:
        # Alias is a name-rebind; pass-through the value.
        return interpret_expr(expr.alias_child_ref(), ctx)

    # All other tags (EXPR_WHEN, EXPR_IN_LIST, EXPR_REGEXP, EXPR_AGG_FN,
    # EXPR_WINDOW_FN, EXPR_CORRELATED_SUBQUERY, EXPR_BETWEEN, EXPR_SORT_KEY,
    # EXPR_STRING_OP, EXPR_COL_IDX): NOT in scope for the 3.b interpreter.
    # These either have their own engine evaluator (compiler_eval_*) that the
    # caller dispatches to, OR are consumed by a plan-pass before reaching
    # the interpreter (e.g. EXPR_AGG_FN consumed by optimizer_scalar_broadcast).
    # The interpreter returns NULL here as a clear marker of "not my path".
    return EvalScalar.null()


def _eval_binary(op: UInt8, var left: EvalScalar, var right: EvalScalar) -> EvalScalar:
    """Binary op evaluation. Numeric ops coerce to Float64 if either side
    is Float; pure-Int ops stay in Int64. Comparison ops produce Bool."""
    # Arithmetic
    if op == BIN_ADD:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_float(left.as_float() + right.as_float())
        return EvalScalar.from_int(left.int_val + right.int_val)
    if op == BIN_SUB:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_float(left.as_float() - right.as_float())
        return EvalScalar.from_int(left.int_val - right.int_val)
    if op == BIN_MUL:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_float(left.as_float() * right.as_float())
        return EvalScalar.from_int(left.int_val * right.int_val)
    if op == BIN_DIV:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            # FLOAT stays IEEE 754: +-inf / NaN, which is what DuckDB v1.5.3
            # returns for `10.0 / 0.0` and `0.0 / 0.0`. Untouched deliberately.
            return EvalScalar.from_float(left.as_float() / right.as_float())
        # ⚠ WITHOUT THE GUARD BELOW THIS IS A SILENT WRONG ANSWER, NOT A
        # CRASH: `17 // 0` returns INT 0.
        #
        # THE MECHANISM IS THE OPERATOR, and it is worth writing down because
        # it is not what anyone assumes. Mojo's `//` is stdlib-guarded and
        # yields 0 on a zero divisor, so it never traps. Its sibling `/`
        # (__truediv__) on an INTEGRAL SIMD lowers to a raw hardware divide
        # with NO guard, so the same expression through `/` takes the PROCESS
        # DOWN with SIGFPE. Same op, same dtype, same machine; different
        # operator.
        #
        # 0 is the worst of the three failure regimes: no raise, no crash,
        # wrong data. DuckDB v1.5.3 answers NULL for `//` and `%` by zero, so
        # that is what this returns.
        if right.int_val == Int64(0):
            return EvalScalar.null()
        return EvalScalar.from_int(left.int_val // right.int_val)
    if op == BIN_MOD:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            # Float mod via fmod-equivalent. Mojo's `%` on Float64 implements
            # IEEE 754 remainder behavior.
            return EvalScalar.from_float(left.as_float() % right.as_float())
        # Same silent-0 as BIN_DIV above; DuckDB v1.5.3 `qty % 0` -> NULL.
        if right.int_val == Int64(0):
            return EvalScalar.null()
        return EvalScalar.from_int(left.int_val % right.int_val)
    # Comparison
    if op == BIN_EQ:
        if left.kind == EVAL_KIND_STRING and right.kind == EVAL_KIND_STRING:
            return EvalScalar.from_bool(left.string_val == right.string_val)
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() == right.as_float())
        if left.kind == EVAL_KIND_BOOL and right.kind == EVAL_KIND_BOOL:
            return EvalScalar.from_bool(left.bool_val == right.bool_val)
        return EvalScalar.from_bool(left.int_val == right.int_val)
    if op == BIN_NE:
        if left.kind == EVAL_KIND_STRING and right.kind == EVAL_KIND_STRING:
            return EvalScalar.from_bool(left.string_val != right.string_val)
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() != right.as_float())
        if left.kind == EVAL_KIND_BOOL and right.kind == EVAL_KIND_BOOL:
            return EvalScalar.from_bool(left.bool_val != right.bool_val)
        return EvalScalar.from_bool(left.int_val != right.int_val)
    if op == BIN_LT:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() < right.as_float())
        return EvalScalar.from_bool(left.int_val < right.int_val)
    if op == BIN_LE:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() <= right.as_float())
        return EvalScalar.from_bool(left.int_val <= right.int_val)
    if op == BIN_GT:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() > right.as_float())
        return EvalScalar.from_bool(left.int_val > right.int_val)
    if op == BIN_GE:
        if left.kind == EVAL_KIND_FLOAT or right.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(left.as_float() >= right.as_float())
        return EvalScalar.from_bool(left.int_val >= right.int_val)
    # Boolean composition
    if op == BIN_AND:
        return EvalScalar.from_bool(left.bool_val and right.bool_val)
    if op == BIN_OR:
        return EvalScalar.from_bool(left.bool_val or right.bool_val)
    return EvalScalar.null()


def _eval_unary(op: UInt8, var child: EvalScalar) -> EvalScalar:
    """Unary op evaluation."""
    if op == UN_NOT:
        return EvalScalar.from_bool(not child.bool_val)
    if op == UN_NEGATE:
        if child.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_float(-child.float_val)
        if child.kind == EVAL_KIND_INT:
            return EvalScalar.from_int(-child.int_val)
        return EvalScalar.null()
    if op == UN_IS_NULL:
        return EvalScalar.from_bool(child.kind == EVAL_KIND_NULL)
    if op == UN_IS_NOT_NULL:
        return EvalScalar.from_bool(child.kind != EVAL_KIND_NULL)
    # ★ NUM-TYPEPRES. ARMED HERE BECAUSE THE FALLTHROUGH BELOW IS
    # A SILENT `null()`, NOT A RAISE. This ladder's "unknown op" answer is
    # indistinguishable from a genuine SQL NULL, so a member wired into the
    # plan space and not into this ladder would not fail — it would answer
    # NULL for every row. That is the defect class this repo has paid for
    # three times in the projection ladders, and it costs twelve lines here.
    if op == UN_ABS:
        if child.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_float(
                -child.float_val if child.float_val < 0.0 else child.float_val
            )
        if child.kind == EVAL_KIND_INT:
            # ⚠ `Int64.MIN` HAS NO ABSOLUTE VALUE and `-Int64.MIN` WRAPS to
            # itself — a NEGATIVE result from `abs`. DuckDB raises; this
            # ladder cannot (it is non-raising by signature), so it answers
            # NULL, which is the one answer that is not silently wrong. The
            # COLUMN kernel, which is the one on a live path, raises properly.
            if child.int_val == Int64.MIN:
                return EvalScalar.null()
            return EvalScalar.from_int(
                -child.int_val if child.int_val < 0 else child.int_val
            )
        return EvalScalar.null()
    if op == UN_SIGN:
        # INT8 in the column world; this ladder has no narrow-int kind, so the
        # value is carried as an INT. -1 / 0 / 1 either way, and `sign(-0.0)`
        # and `sign(nan)` are both 0 because neither comparison holds.
        if child.kind == EVAL_KIND_FLOAT:
            if child.float_val > 0.0:
                return EvalScalar.from_int(Int64(1))
            if child.float_val < 0.0:
                return EvalScalar.from_int(Int64(-1))
            return EvalScalar.from_int(Int64(0))
        if child.kind == EVAL_KIND_INT:
            if child.int_val > 0:
                return EvalScalar.from_int(Int64(1))
            if child.int_val < 0:
                return EvalScalar.from_int(Int64(-1))
            return EvalScalar.from_int(Int64(0))
        return EvalScalar.null()
    if op == UN_BIT_COUNT:
        # ⛔ THIS LADDER CANNOT ANSWER A NEGATIVE OPERAND AND DOES NOT TRY.
        # `bit_count`'s value depends on the operand's DECLARED WIDTH --
        # `bit_count((-1)::INTEGER)` is 32 and `::BIGINT` is 64, measured on
        # DuckDB v1.5.3 -- and `EvalScalar` has ONE integer kind, Int64, with
        # the source width already thrown away. A negative value here would be
        # counted over 64 bits whatever column it came from, which is right
        # only by luck. NULL is the one answer that is not silently wrong, and
        # it is the same call `UN_ABS` makes two arms up for `Int64.MIN`.
        #
        # A NON-NEGATIVE operand IS answerable: its popcount is identical at
        # every width wide enough to hold it, so no width information is
        # needed. The COLUMN kernel (`eval_bit_count_int`) is the one on a live
        # path and it has the width, so it answers both signs exactly.
        if child.kind == EVAL_KIND_INT:
            if child.int_val < 0:
                return EvalScalar.null()
            var bits = child.int_val
            var n = Int64(0)
            while bits != 0:
                bits &= bits - 1
                n += 1
            return EvalScalar.from_int(n)
        # FLOAT / BOOL / STRING: DuckDB has NO non-integer overload of
        # `bit_count` -- `bit_count(1.5)` is a BIND ERROR there -- so there is
        # no value to return.
        return EvalScalar.null()
    if op == UN_TRUNC or op == UN_ROUND:
        if child.kind == EVAL_KIND_INT:
            # DuckDB: `trunc(BIGINT) -> BIGINT`, `round(BIGINT) -> BIGINT`,
            # both the identity.
            return EvalScalar.from_int(child.int_val)
        if child.kind == EVAL_KIND_FLOAT:
            if op == UN_TRUNC:
                return EvalScalar.from_float(
                    external_call["trunc", Float64](child.float_val)
                )
            return EvalScalar.from_float(
                external_call["round", Float64](child.float_val)
            )
        return EvalScalar.null()
    return EvalScalar.null()


def _eval_cast(var src: EvalScalar, target: DType) -> EvalScalar:
    """Cast evaluation. Source EvalScalar's kind is the source dtype."""
    if target == DType.float64 or target == DType.float32:
        return EvalScalar.from_float(src.as_float())
    if target == DType.int64 or target == DType.int32 or target == DType.int16 or target == DType.int8:
        # ⛔ NOT `src.as_int()`. That coerces a float with `Int64(float_val)`,
        # which TRUNCATES TOWARD ZERO; a SQL CAST to an integer rounds HALF TO
        # EVEN (DuckDB v1.5.3: 2.5 -> 2, 3.5 -> 4, -1.5 -> -2). ⚠ `as_int` is
        # deliberately left alone rather than "fixed" — it is the general numeric
        # coercion and its other callers are not casts, so changing it would move
        # this defect somewhere nobody is looking instead of removing it.
        if src.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_int(
                round_half_to_even[DType.float64, 1](SIMD[DType.float64, 1](src.float_val)).cast[DType.int64]()[0]
            )
        return EvalScalar.from_int(src.as_int())
    if target == DType.bool:
        # Numeric truthiness: 0 → False, non-zero → True
        if src.kind == EVAL_KIND_INT:
            return EvalScalar.from_bool(src.int_val != 0)
        if src.kind == EVAL_KIND_FLOAT:
            return EvalScalar.from_bool(src.float_val != 0.0)
        if src.kind == EVAL_KIND_BOOL:
            return EvalScalar.from_bool(src.bool_val)
        return EvalScalar.from_bool(False)
    return EvalScalar.null()
