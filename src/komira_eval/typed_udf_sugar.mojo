# =============================================================================
# typed_udf_sugar.mojo — the customer-facing typed UDF surface
# =============================================================================
#
# THE ASK: the typed path now authors a PhysicalPlan directly.
# A typed UDF never touches the wire — no `UdfData`, no registry, no name
# resolution — so the function can be a COMPTIME PARAMETER in a plan that is
# already comptime. This file is what the customer WRITES against.
#
# ── The problem this deletes ────────────────────────────────────────────────
# Conforming to `MapFn` by hand costs 2 structs and ~16 lines for `a * 10`:
# an `InRow` struct, an `OutputSchema`, an `OutType` restating the same fact,
# a hand-picked global `UDF_ID`, and a `run_row` body. The design principle
# "Users First, Engine Second" asks for 1-3 lines for exactly this case.
#
# Here, the customer writes a PLAIN MOJO FUNCTION and names its columns:
#
#     def margin(price: Float64, cost: Float64) -> Float64:
#         return (price - cost) / price
#
#     comptime Margin = Map2[f=margin, out_name="margin", in0="price", in1="cost"]
#
# Everything else is DERIVED. `T0`, `T1` and `O` are INFERRED from `margin`'s
# own signature via the `//` inferred-parameter list, so one adapter serves
# every arity-2 dtype combination and the customer declares no types at all.
#
# ── Why the column NAMES are still written by hand (measured, not assumed) ──
# Because comptime CANNOT read a `def`'s parameter names in Mojo 1.0.0.
# Measured: `reflect[T]` takes a TYPE, and a function is a VALUE
# (`reflect[margin]` => "parameter 'T' has 'AnyType' type, but value has type
# 'def margin(price: Float64, cost: Float64) thin -> Float64'"). The names ARE
# in the type — the compiler prints them — but `reflect[type_of(margin)]`
# reflects the opaque callable (`field_count() == 1`, the field named "value")
# and `.name()` renders `std.builtin._stubs.__MLIRType[<unprintable>]`.
# So the information exists in the compiler and no API surfaces it. That is a
# MISSING ACCESSOR upstream, not a language impossibility — if Modular ever
# exposes it, `in0`/`in1` collapse and `out_name` is the only string left.
#
# Naming the columns at the call site is also the reason ONE `def margin` can
# be applied to two different pairs of columns, which a parameter-name-derived
# API could not express.
# =============================================================================

from komira_eval.map_fn import MapFn
from komira_eval.filter_fn import FilterFn
from komira_eval.auto_komira_schema import AutoKomiraSchema
from komira_eval.schema_descriptor import (
    SchemaDescriptor, dtype_to_dtag, schema_of,
)


# =============================================================================
# `DType` -> `DT_*` tag. The inverse of `dtag_to_dtype`, which did not exist.
# =============================================================================
#
# ⚠ WHY NOT `_dtag_for[Scalar[O]]()`: because it is WRONG FOR BOOL, and
# silently so. `_dtag_for` discriminates on the Mojo TYPE and tests `T == Bool`,
# but a `MapFn` returns `Scalar[OutType]` = `SIMD[OutType, 1]`, and
# `SIMD[DType.bool, 1]` is NOT the type `Bool` in Mojo 1.0.0. Float64 and Int64
# hide the bug — `Float64` IS `SIMD[DType.float64, 1]`, so those unify — but a
# bool-output UDF derived its output tag as DT_UNKNOWN (-1).
#
# With `_dtag_for[Scalar[Self.O]]()`, a Bool-output UDF's
# `OutputSchema.cols[0].dtype` comes back -1 instead of DT_BOOL (10), so the
# plan node advertises an UNKNOWN-typed output column and no error fires. This
# is the same defect class the two `comptime assert`s in `build_map_udf_data`
# guard — a dtype fact restated in a second place and allowed to disagree.
#
# Deriving from the `DType` is exact and total: `O` is the single source of
# truth for the output type, and it comes from the customer's own return type.
#
# ⚠ AND THE SAME BUG APPLIES ON THE *INPUT* SIDE. Deriving `InputSchema` from
# the Mojo TYPE via `_dtag_for[Self.T0]()` has the same defect: a UDF taking a
# bool column (`def not_flag(b: Scalar[DType.bool]) -> Scalar[DType.bool]`)
# reports `InputSchema.cols[0].dtype == -1`. A test that only asserts the
# OUTPUT tag for bool cannot see it.
#
# The answer is to stop having two derivations. `Map*`'s input parameters are
# `DType`s, exactly like `O`, so BOTH sides go through `_dtag_of_dtype` and
# there is no second place to disagree. `Scalar[T0]` is what the customer's
# `Float64`/`Int64`/`Scalar[DType.bool]` parameter already spells, so
# `Row1[Float64]`/`Row2[Float64, Float64]` construct identically.
#
# ⚠ `_dtag_for` ITSELF IS STILL WRONG and this file no longer uses it. Its one
# remaining consumer is `_derive_schema[T]()` (the `MapFn.InputSchema` trait
# default), which reflects STRUCT FIELDS — so any conformer with a
# `Scalar[DType.bool]` field silently derives DT_UNKNOWN. The one-arm fix is
# `elif (T == Scalar[DType.bool]): return DT_BOOL` in `schema_descriptor.mojo`;
# it is NOT applied here because that file carries another lane's uncommitted
# work and committing it would sweep theirs.


def _dtag_of_dtype(d: DType) -> Int:
    """`DType` -> `DT_*` tag.

    ⚠ THE BODY MOVED TO `schema_descriptor.dtype_to_dtag` AND THIS IS NOW A
    FORWARDER — deliberately, not as tidying. A second consumer arrived (the
    untyped scalar-UDF surface derives BOTH its tags from the customer's
    signature the same way), and this file's own header records what happens
    when one dtype fact is written down in two places: a `Scalar[DType.bool]`
    column derived DT_UNKNOWN on one side and DT_BOOL on the other, silently,
    twice, three lines apart. One implementation, so there is nothing to
    disagree with."""
    return dtype_to_dtag(d)


# =============================================================================
# Derived UDF_ID
# =============================================================================
#
# `MapFn` requires a `comptime UDF_ID: UInt32` the customer picks by hand, out
# of a documented range. That is a collision hazard AND a poor experience, and
# the collisions are NOT hypothetical: hand-picked ids repeat across distinct
# conformers.
#
# What a collision costs: `UDF_ID` becomes `UdfData.operator_factory_id`, and
# `lower_untyped_udf_segment` asserts `udf_data.operator_factory_id == F.UDF_ID`
# to check "F is the UDF this segment is for". Two DISTINCT UDFs sharing an id
# make that sanity check pass when it should fail. (Two USES of the SAME UDF
# are already handled — `call_site_salt` disambiguates them for plan-CSE.)
#
# Here it is DERIVED: a comptime FNV-1a over the column names the customer
# already wrote. Deterministic, stable across builds, and distinct for distinct
# (output, inputs) triples. Emitted above 10000 so it can never collide with
# the hand-assigned [7000, 9999] range still in use by the legacy conformers.
#
# ⚠⚠ IT DOES NOT IDENTIFY THE FUNCTION, ONLY ITS COLUMNS — so it reintroduces
# a collision mode a human assigning integers does NOT have:
# `Map1[f=twice, out_name="y", in0="a"]` and
# `Map1[f=thrice, out_name="y", in0="a"]` both derive `1635047856`. Pinned by
# `test_udf_id_does_NOT_identify_the_function`.
#
# It cannot be fixed by a better hash. `twice` and `thrice` have the SAME Mojo
# type (`def(Int64) thin -> Int64`) — `reflect[type_of(f)]` returns the same
# `Reflected[...]` for both — so comptime has nothing to distinguish them with.
#
# So the honest claim is NARROWER than "collisions solved": it removes the
# hand-picked-integer hazard and adds a same-columns one, and it is safe only
# because the typed path builds no `UdfData` node, so nothing reads `UDF_ID`
# there (see the note on Map1/Map2 below). Anything that DOES read it to answer
# "which UDF is this" must not be fed these adapters.


def _fnv1a(s: StringSlice) -> UInt32:
    """FNV-1a over the UTF-8 bytes. Comptime-evaluable."""
    var h = UInt32(2166136261)
    for i in range(s.byte_length()):
        h = (h ^ UInt32(s.as_bytes()[i])) * UInt32(16777619)
    return h


def udf_id_1[out_name: StringLiteral, in0: StringLiteral]() -> UInt32:
    comptime H = _fnv1a(StringSlice(out_name)) ^ (_fnv1a(StringSlice(in0)) * UInt32(31))
    return UInt32(10000) + (H % UInt32(4294957295))


def udf_id_2[
    out_name: StringLiteral, in0: StringLiteral, in1: StringLiteral
]() -> UInt32:
    comptime H = (
        _fnv1a(StringSlice(out_name))
        ^ (_fnv1a(StringSlice(in0)) * UInt32(31))
        ^ (_fnv1a(StringSlice(in1)) * UInt32(131))
    )
    return UInt32(10000) + (H % UInt32(4294957295))


# =============================================================================
# Generic row structs — the `InRow` the customer no longer writes.
# =============================================================================
#
# `MapFn.InRow` must be a concrete `@fieldwise_init` struct, one field per
# input column. These are that struct, parameterized on the column types, so
# the SDK supplies it instead of the customer. Field names are positional
# (`c0`, `c1`) and deliberately NOT used for schema derivation — the trait
# default `_derive_schema[InRow]()` would name the columns "c0"/"c1", so every
# adapter below OVERRIDES `InputSchema` with the customer's real column names.
# (That override is a documented, supported path: "the explicit value wins".)


@fieldwise_init
struct Row1[T0: Copyable & Deinitable](Copyable, Movable, AutoKomiraSchema):
    var c0: Self.T0


@fieldwise_init
struct Row2[T0: Copyable & Deinitable, T1: Copyable & Deinitable](
    Copyable, Movable, AutoKomiraSchema
):
    var c0: Self.T0
    var c1: Self.T1


@fieldwise_init
struct Row3[
    T0: Copyable & Deinitable, T1: Copyable & Deinitable, T2: Copyable & Deinitable
](Copyable, Movable, AutoKomiraSchema):
    var c0: Self.T0
    var c1: Self.T1
    var c2: Self.T2


# =============================================================================
# Map adapters — `MapFn` from a plain `def`.
# =============================================================================
#
# ⚠ THE FUNCTION PARAMETER MUST BE SPELLED `thin`. A top-level `def` is a THIN
# function and does not bind to a closure-typed parameter: passing `margin` to
# `f: def(T0, T1) -> Scalar[O]` fails with "a thin function cannot bind to a
# closure trait". `thin` is what lets the customer pass a bare function name
# with no wrapper, no struct, and no capture list.
#
# ⚠ ZERO FIELDS, ON PURPOSE. Six conformers in `src/` carry a `var dummy: Int64`
# nobody reads. It is not required by anything: these structs have no fields at
# all, are `@fieldwise_init`, conform to `MapFn`, and construct as `Map2[...]()`.
#
# ⚠ `UDF_ID` IS VESTIGIAL HERE. It is the selector for matching a runtime
# `UdfData` plan node back to its comptime UDF. The typed path builds no such
# node — the function is a comptime parameter — so on the PhysicalPlan-emitting
# path nothing reads this. It is derived rather than deleted only because the
# shared `MapFn` trait still requires the member.


@fieldwise_init
struct Map1[
    T0: DType, O: DType, //,
    f: def(Scalar[T0]) raises thin -> Scalar[O],
    out_name: StringLiteral,
    in0: StringLiteral,
](MapFn):
    """One input column -> one output column, from a plain `def`."""

    comptime InRow = Row1[Scalar[Self.T0]]
    comptime InputSchema = schema_of[Self.in0, _dtag_of_dtype(Self.T0)]()
    comptime OutputSchema = schema_of[Self.out_name, _dtag_of_dtype(Self.O)]()
    comptime OutType = Self.O
    comptime UDF_ID = udf_id_1[Self.out_name, Self.in0]()

    def run_row(mut self, row: Self.InRow) raises -> Scalar[Self.OutType]:
        return Self.f(row.c0)


@fieldwise_init
struct Map2[
    T0: DType, T1: DType, O: DType, //,
    f: def(Scalar[T0], Scalar[T1]) raises thin -> Scalar[O],
    out_name: StringLiteral,
    in0: StringLiteral,
    in1: StringLiteral,
](MapFn):
    """Two input columns -> one output column, from a plain `def`."""

    comptime InRow = Row2[Scalar[Self.T0], Scalar[Self.T1]]
    comptime InputSchema = schema_of[
        Self.in0, _dtag_of_dtype(Self.T0), Self.in1, _dtag_of_dtype(Self.T1)
    ]()
    comptime OutputSchema = schema_of[Self.out_name, _dtag_of_dtype(Self.O)]()
    comptime OutType = Self.O
    comptime UDF_ID = udf_id_2[Self.out_name, Self.in0, Self.in1]()

    def run_row(mut self, row: Self.InRow) raises -> Scalar[Self.OutType]:
        return Self.f(row.c0, row.c1)


# =============================================================================
# Filter adapter — `FilterFn` from a plain `def ... -> Bool`.
# =============================================================================
#
# `FilterFn` refines `Predicate`, so a conformer must also supply
# `eval_scalar(batch, i)`. That one CANNOT be derived generically here: it
# reads a typed column off a `BatchView` (`batch.col_f64(0)`, `col_i64(0)`, …)
# and the accessor name depends on the dtype. Deriving it needs a
# dtype-dispatched column reader, which is engine-side work, not sugar. Until
# that exists the filter sugar is deliberately NOT offered — an adapter that
# silently omitted `eval_scalar` would not conform, and one that guessed the
# accessor would be wrong for every other dtype.
#
# This is the honest boundary of this file: MAP is fully sugared, FILTER needs
# one engine-side helper first. Named rather than faked.


# =============================================================================
# WHAT IS STILL IRREDUCIBLE, AND WHY
# =============================================================================
#
# * the column NAMES (`out_name`, `in0`, …) — comptime cannot read a `def`'s
#   parameter names (measured; see the header). Also load-bearing: naming them
#   at the call site is what lets one `def` serve two different column pairs.
#
# * A UDF THAT CAN FAIL IS EXPRESSIBLE: `Map1.f` / `Map2.f` are `def(...) raises thin -> Scalar[O]`
#   (see their declarations below), and a `raises thin` comptime parameter
#   accepts BOTH a raising and a non-raising customer function — widening is
#   variance, not a requirement, so nothing the old bullet warned about is
#   paid by anyone. The measured table below makes the widening look
#   expensive, but it applies to a VARIADIC trait method, which is a different
#   question from a `def` PARAMETER, and is retained only for the sake of
#   whoever next proposes re-adding a variadic oracle.
#
#     trait method `raises`, NON-variadic, conformer non-raising  -> rc=0
#     trait method `raises`, VARIADIC,     conformer non-raising  -> rc=139 ⛔
#     trait method `raises`, VARIADIC,     conformer ALSO raising -> rc=0
#
#   The middle row is a COMPILER CRASH (SIGSEGV, "Please submit a bug
#   report"), not a compile error; repro + bisect pinned in
#   `test_typed_udf_raises_variance.mojo`. There is no variadic oracle on
#   the traits, so it is unreachable.
#
#   ⚠ WHAT IS STILL NON-RAISING, NAMED SO THE NEXT READER DOES NOT HAVE TO
#   RE-MEASURE IT: `SumOf2.f` (below) — blocked BY THAT MIDDLE ROW, since
#   `AggFn.update_scalar` is variadic and widening `f` without widening it
#   crashes the compiler; `PlanCarrier.map`'s own `m` and the seven
#   `def(In) thin -> Out` declarations it threads through
#   (`row_udf_chain`, `row_udf_driver`, `row_map_projects`, `row_udf`); and
#   `Predicate.eval_scalar` on the filter side, which every `FilterFn`
#   conformer implements by hand. None of the three is blocked by anything in
#   THIS file.
#
# * ⛔ THIS BULLET IS OBSOLETE AS OF UDF-STRING — kept, corrected,
#   because it is cited elsewhere. It read: "a STRING-returning UDF cannot be
#   expressed. `run_row` returns `Scalar[OutType]` and no `DType` holds a
#   String ... the refusal is correct-but-total."
#
#   The first half is still TRUE and is a fact about `MapFn`: `run_row`'s
#   `-> Scalar[Self.OutType]` return pins a MapFn's output to a DType, and
#   `dtag_has_scalar_dtype` refuses DT_STRING by construction. What was wrong
#   was "TOTAL" — `MapFn` is not the only carrier. See `MapXString` at the
#   bottom of this file: an `ExprXString` conformer takes the customer's plain
#   `def`, and `ExprXString` refines `RowTransform`, so the value lands
#   through the builder's STRING channel with no `DType` on the path at all.


# =============================================================================
# Aggregate sugar — DOES the aggregate shape differ from the scalar one? YES.
# =============================================================================
#
# A scalar UDF is ONE function. An aggregate is a PARALLEL FOLD, and `AggFn`
# accordingly requires five methods plus a `State` POD: `init`, `update`,
# `update_scalar`, `merge`, `finalize`. That is NOT ceremony and must not be
# sugared away in general — `merge` is the parallel-correctness contract and
# cannot be derived from `update`. Two workers each fold a morsel and their
# states are combined; only the author knows how to combine them.
#
# ⚠ BUT the shape the CUSTOMER actually wants is almost never a custom fold.
# It is "reduce a scalar expression": sum of `price*qty`, average of a margin.
# For those, the customer should write the SAME plain function as the scalar
# case and merely name the reduction — the fold is the ENGINE's, not theirs.
#
#     def margin(price: Float64, cost: Float64) -> Float64:
#         return (price - cost) / price
#
#     comptime SumMargin = SumOf2[f=margin, out_name="sum_margin",
#                                 in0="price", in1="cost"]
#
# Identical to the scalar surface: one plain function, one line, nothing about
# state or merging. The five-method `AggFn` stays for genuinely custom
# aggregates (a t-digest, a HyperLogLog), which is the right place for it.

from komira_eval.agg_fn import AggFn, PodState


@fieldwise_init
struct _SumState[O: DType](PodState, Copyable, Movable):
    var total: Scalar[Self.O]


@fieldwise_init
struct SumOf2[
    T0: DType, T1: DType, O: DType, //,
    f: def(Scalar[T0], Scalar[T1]) thin -> Scalar[O],
    out_name: StringLiteral,
    in0: StringLiteral,
    in1: StringLiteral,
](AggFn):
    """SUM of a scalar expression over two columns. The customer writes the
    same plain `def` the scalar path takes; the fold belongs to the engine."""

    comptime InRow = Row2[Scalar[Self.T0], Scalar[Self.T1]]
    comptime InputSchema = schema_of[
        Self.in0, _dtag_of_dtype(Self.T0), Self.in1, _dtag_of_dtype(Self.T1)
    ]()
    comptime OutputSchema = schema_of[Self.out_name, _dtag_of_dtype(Self.O)]()
    comptime OutType = Self.O
    comptime State = _SumState[Self.O]
    comptime UDF_ID = udf_id_2[Self.out_name, Self.in0, Self.in1]()

    def init(self) -> Self.State:
        return _SumState[Self.O](Scalar[Self.O](0))

    def update(self, mut s: Self.State, row: Self.InRow):
        s.total = s.total + Self.f(row.c0, row.c1)

    def update_scalar[*Ts: Copyable](self, mut s: Self.State, *vals: *Ts):
        s.total = s.total + Self.f(
            rebind[Scalar[Self.T0]](vals[0]), rebind[Scalar[Self.T1]](vals[1])
        )

    def merge(self, a: Self.State, b: Self.State) -> Self.State:
        return _SumState[Self.O](a.total + b.total)

    def finalize(self, s: Self.State) -> Scalar[Self.OutType]:
        return s.total


# =============================================================================
# STRING-RETURNING UDF SUGAR — `MapXString`
# =============================================================================
#
# UDF-STRING. This closes the "STILL IRREDUCIBLE" bullet above
# that read:
#
#     "a STRING-returning UDF cannot be expressed. `run_row` returns
#      `Scalar[OutType]` and no `DType` holds a String ... A numeric ->
#      string UDF (a `grade()`, a `format_currency()`) is off this surface
#      entirely. This is a real customer case and the refusal is
#      correct-but-total."
#
# It is no longer total. What that paragraph got right is that `MapFn` is the
# wrong carrier — `MapFn.run_row`'s `-> Scalar[Self.OutType]` return pins the
# output to a DType and nothing about a String fits through it. What it did
# not say is that `MapFn` is not the ONLY carrier: `RowTransform` is the
# unified row->row surface, `ExprXString` refines it as of UDF-STRING, and an
# `ExprXString` conformer lands its value through the builder's STRING
# channel (`append_string_at[k]`) with no `DType` anywhere on the path.
#
# ⚠ SO THE SUGAR FAMILIES DIVERGE HERE, AND THE ASYMMETRY IS REAL, NOT AN
# OVERSIGHT. `Map1` / `Map2` above are `MapFn` conformers; `MapXString` below
# is an `ExprXString` conformer. They are both "wrap the customer's plain
# `def`", they both reach the same `ProjectList`-driven project emit, and
# they are different traits because the OUTPUT TYPE VOCABULARY is different:
# `MapFn` speaks `DType`, and there is no String in it.
#
# WHAT THE CUSTOMER WRITES (this is the whole surface):
#
#     @fieldwise_init
#     struct Order(Copyable, Movable):
#         var total: Float64
#
#     @fieldwise_init
#     struct Graded(Copyable, Movable):
#         var grade: String
#
#     def grade_of(row: Order) -> Graded:
#         if row.total >= 100.0:
#             return Graded(String("gold"))
#         return Graded(String("standard"))
#
#     comptime GradeCol = MapXString[
#         f=grade_of, in0="total", in_dtype=DType.float64
#     ]
#     # ... ProjectList[GradeCol](GradeCol()) -> a STRING output column.
#
# ROW IN, ROW OUT. `f` takes the customer's named input row struct and
# returns their named output row struct; the engine builds the input row
# (`_build_row[R]`, the ONE generic UDF row constructor)
# and reads the single String field back out of the output row. Both sides
# are arity-1 and COMPTIME-ASSERTED to be — a 2-field row is a compile error
# naming the mismatch, never a read off the end.
#
# ⛔ WHAT THIS IS NOT. A `RowMapFn` that emits N output columns of MIXED
# types from one returned row is the multi-column row-UDF carrier; this is the arity-1 String case, which is the one the
# String primitive unblocks and the one `typed_projects.mojo` was waiting
# for. The output-side extraction below is deliberately the exact mirror of
# `_build_row`'s input-side one, so widening it to N fields is a loop over
# `field_offset[index=j]()` in the SAME shape rather than a new mechanism.

from komira_core.arrow.arrow_types import ArrowType
from komira_core.collections.batch_view import BatchView
from komira_core.plan.expr import Expr

from komira_eval.column_resolver import ColumnResolver
from komira_eval.expr_x import ExprXString
from komira_eval.row_builder import _build_row


@always_inline
def _read_one_string_field[
    O: Copyable & Movable & Deinitable
](imm row: O) -> String:
    """Read the ONE `String` field out of the UDF's output row `O`.

    The output-side mirror of `row_builder._build_row[R]`, and it exists for
    the same reason: comptime reflection over `O`'s field offsets is what
    lets the ENGINE speak rows, so the customer never has to hand fields
    over positionally.

    Both facts about `O` are ASSERTED, not assumed — a 2-field output row,
    or a 1-field row whose field is not a `String`, is a COMPILE ERROR
    naming the mismatch. (Under a positional oracle the same mistake would
    have compiled and reinterpreted the bytes.)

    Returns a `.copy()`, deliberately: `row` still owns its own String and
    destroys it normally at the caller's scope exit. This is a READ, not a
    partial move — no `take_pointee`, nothing left half-initialised
    (no partial move out of a struct field).
    """
    comptime r = reflect[O]

    comptime assert r.field_count() == 1, (
        "_read_one_string_field: the UDF output row must have exactly ONE"
        " field. A multi-column UDF output is the `RowMapFn` carrier,"
        " not this arity-1 String sugar."
    )

    comptime ts = r.field_types()
    comptime assert ts[0] == String, (
        "_read_one_string_field: the UDF output row's single field must be"
        " a `String`. `MapXString` lands its value through the column"
        " builder's STRING channel; a numeric output belongs on `Map1` /"
        " `Map2` above."
    )

    comptime off = r.field_offset[index=0]()
    # SAFETY: `row` is a live borrow for the whole of this expression, and
    # `off` is O's OWN reflected field offset, so the byte cursor addresses
    # O's String field in place. The pointer is function-local (it never
    # appears in a signature and never escapes) and carries `row`'s concrete
    # origin. `.copy()` produces an independent String, so ownership of the
    # original stays with `row`.
    var base = UnsafePointer(to=row).unsafe_bitcast[UInt8]()
    return base.unsafe_offset(off).unsafe_bitcast[String]()[].copy()


struct MapXString[
    R: Copyable & Movable & Deinitable,
    O: Copyable & Movable & Deinitable, //,
    f: def (R) thin -> O,
    in0: StringLiteral,
    in_dtype: DType,
](ExprXString):
    """A STRING output column computed by a plain customer `def`.

    `f` takes the customer's input row struct `R` (one field, holding the
    cell of column `in0`) and returns their output row struct `O` (one
    field, a `String`). Both shapes are comptime-asserted at the two
    reflection sites, so a mismatched row is a named compile error.

    ⚠ THE FUNCTION PARAMETER MUST BE SPELLED `thin`, for the same reason
    `Map1`'s is: a top-level `def` is a THIN function and does not bind to a
    closure-typed parameter. `thin` is what lets the customer pass a bare
    function name with no wrapper, no struct and no capture list.

    ⚠ `in_dtype` IS EXPLICIT AND CANNOT BE INFERRED. `Map1` infers its input
    DType from `f: def(Scalar[T0]) -> ...` because the cell type is IN the
    signature. Here the signature says `def(R)` — the DType lives one level
    down, inside `R`'s field — and comptime cannot read it back out to
    SELECT a `BatchView` accessor. `_build_row[R, in_dtype]` then asserts
    the two agree, so naming it wrong is a compile error rather than a
    reinterpret.

    Name-keyed leaf; the runtime `_idx` is populated by `bind`,
    which also checks the bound column's ArrowType against `in_dtype`.
    """

    var _idx: Int

    def __init__(out self):
        self._idx = -1

    def bind(mut self, resolver: ColumnResolver) raises:
        """Resolve `in0` to a column index and CHECK the file's type.

        The type check is the same defensive one `ColXF64.bind` performs:
        an index alone would happily read a Float64 column's bytes as
        Int64. Mirrors that conformer's message shape.
        """
        self._idx = resolver.index_for(String(Self.in0))
        var at = resolver.arrow_type_for(String(Self.in0))
        if at != ArrowType.from_dtype(Self.in_dtype):
            raise Error(
                String("MapXString[in0=\""),
                String(Self.in0),
                String("\"].bind: file's ArrowType is "),
                String(at),
                String(", expected "),
                String(ArrowType.from_dtype(Self.in_dtype)),
                String(" (the declared `in_dtype`)"),
            )

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> String:
        """Read the cell, build the customer's row, call their function,
        read the String back out. One row, no intermediate column.

        The `comptime if` ladder over `in_dtype` folds away — this compiles
        to a direct typed load + a direct call to `f` + a field read, the
        same zero-`bl` shape `MapFnRT.write_one` has.
        """
        comptime if Self.in_dtype == DType.float64:
            var v = batch.col_f64(self._idx).load[1](i)[0]
            return _read_one_string_field[Self.O](
                Self.f(_build_row[Self.R, DType.float64](v))
            )
        elif Self.in_dtype == DType.int64:
            var v = batch.col_i64(self._idx).load[1](i)[0]
            return _read_one_string_field[Self.O](
                Self.f(_build_row[Self.R, DType.int64](v))
            )
        elif Self.in_dtype == DType.int32:
            var v = batch.col_i32(self._idx).load[1](i)[0]
            return _read_one_string_field[Self.O](
                Self.f(_build_row[Self.R, DType.int32](v))
            )
        elif Self.in_dtype == DType.float32:
            var v = batch.col_f32(self._idx).load[1](i)[0]
            return _read_one_string_field[Self.O](
                Self.f(_build_row[Self.R, DType.float32](v))
            )
        else:
            comptime assert False, (
                "MapXString: `in_dtype` is not a supported input column"
                " DType. Covered today: float64 / int64 / int32 / float32"
                " — the same four `EvaluatorAdapterFor_Map` covers. Extend"
                " both ladders together."
            )
            return String("")

    @staticmethod
    @always_inline
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        """NO runtime-Expr twin — a customer `def` is a comptime parameter,
        not an `Expr` node. Raises rather than lowering to something that
        would evaluate differently, which is the same choice
        `_UnsupportedXI64.to_expr` makes."""
        raise Error(
            String(
                "MapXString.to_expr: a customer Mojo function has no"
                " runtime-Expr equivalent. The typed path emits this"
                " transform directly; there is nothing to lower."
            )
        )
