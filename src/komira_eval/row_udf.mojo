# =============================================================================
# row_udf.mojo — the ROW-form typed UDF surface: a plain Mojo function IS the UDF
# =============================================================================
#
# The row-form UDF surface and the identity it mints for each row UDF (a
# wrong identity is a wrong-result bug, see §1).
#
# ── What the customer writes ────────────────────────────────────────────────
#
#     @fieldwise_init
#     struct Order(AutoKomiraSchema):
#         var price: Float64
#         var cost: Float64
#
#     @fieldwise_init
#     struct Priced(AutoKomiraSchema):
#         var margin: Float64
#         var bucket: Int64
#
#     def margin(row: Order) -> Priced: ...
#     def cheap(row: Order) -> Bool: ...
#
#     df.map[margin]().filter[cheap]()
#
# BOTH row types are recovered from the function signature alone, through
# Mojo's inferred-parameter list (`//`). No string column names, no `UDF_ID`,
# no `InputSchema`, no `OutputSchema`, no conformer struct.
#
# ── Why the ROW form gets the column names the SCALAR form cannot ───────────
#
# `typed_udf_sugar.mojo`'s `Map2[f=margin, out_name="margin", in0="price",
# in1="cost"]` makes the customer write the column names, and its header
# records why: comptime CANNOT read a `def`'s PARAMETER names in Mojo 1.0.0
# (`reflect[T]` takes a TYPE; a function is a VALUE). That limit is real and
# this file does not repeal it.
#
# It SIDESTEPS it. The names move out of the function's parameter list and
# into a STRUCT, and `reflect` reads a struct's field names perfectly well —
# it is what `_derive_schema` has always done. So `Order`'s fields ARE the
# input column names and `Priced`'s fields ARE the output column names, both
# derived, both in declared order.
#
# The scalar form keeps one thing this one gives up: naming the columns at the
# CALL SITE lets one `def margin` serve two different column pairs. Here the
# binding is fixed by the row type. That is a deliberate trade, not an
# oversight — the two surfaces coexist.
#
# ── The positional column binding, and the contract that makes it sound ─────
#
# `_build_row_n[R]` reads field k from batch COLUMN k. That is only correct
# because `row_projection[R]()` (below) is what the SDK seam pushes into the
# scan as the projection: the batch has R's fields, in R's declared order, by
# construction. ⛔ Anything driving a row UDF over a batch it did not project
# this way reads the wrong columns and NOTHING reports it.
# =============================================================================

from komira_core.collections.batch_view import BatchView

from komira_eval.auto_komira_schema import AutoKomiraSchema
from komira_eval.filter_fn import FilterFn
from komira_eval.row_builder import _build_row_n, _row_field_dtype
from komira_eval.schema_descriptor import SchemaDescriptor, _derive_schema


# =============================================================================
# §1 — What a row UDF's identity is, and what it CANNOT be
# =============================================================================
#
# `UDF_ID` is required by the `FilterFn` / `MapFn` traits and becomes
# `UdfData.operator_factory_id`. Two consumers read it to answer "which UDF is
# this": `lower_untyped_udf_segment[F]`, whose whole body is
# `assert udf_data.operator_factory_id == F.UDF_ID`, and the plan
# `structural_hash` that `plan_cse` shares subtrees by. Two DISTINCT UDFs
# sharing an id make the first assert pass when it should fail, and let the
# second share two nodes that compute different things.
#
# ⚠ THE COLLISIONS ARE NOT HYPOTHETICAL: hand-picked integer ids repeat
# across distinct conformers. And the scalar sugar's derived id fixed the hand-picked-integer hazard while
# introducing a same-COLUMNS one: `Map1[f=twice, out_name="y", in0="a"]` and
# `Map1[f=thrice, ...]` both derive `1635047856`.
#
# ── What this file folds in, and why it is strictly more ────────────────────
#
# `reflect[R].name()` returns the FULLY QUALIFIED struct name — measured
# it renders `q3_ident.Order`, module path included. So the
# identity below folds, for both the input and the output row:
#
#     the qualified STRUCT NAME  +  every FIELD NAME  +  every FIELD DTYPE
#
# plus a KIND tag (a filter over `Order` and a map over `Order` are different
# operators, and must not collide even when their input rows agree).
#
# That is measurably stronger than the columns-only derivation next door. Two
# structurally IDENTICAL output structs with different names — the exact case
# a field-name-only hash cannot separate — get different ids:
#
#     struct Priced(AutoKomiraSchema): var margin: Float64; var bucket: Int64
#     struct Total (AutoKomiraSchema): var margin: Float64; var bucket: Int64
#     measured:  1432003302  vs  1617500027
#
# ── ⛔ AND WHAT IT STILL CANNOT DO. READ THIS BEFORE TRUSTING THE ID. ────────
#
# TWO FUNCTIONS WITH THE SAME SIGNATURE STILL COLLIDE, AND NO HASH FIXES IT:
#
#     def margin(row: Order) -> Priced: ...
#     def markup(row: Order) -> Priced: ...
#
# `margin` and `markup` have the SAME Mojo type (`def(Order) thin -> Priced`),
# so `reflect` returns the same `Reflected[...]` for both and comptime has
# NOTHING left to distinguish them with. This is a missing upstream accessor,
# not a hash weakness — a better hash over the same inputs yields the same
# collision.
#
# So the fix is three parts, and the third is the load-bearing one:
#
#   1. FOLD MORE (above) — closes every collision except same-signature.
#   2. AN EXPLICIT `id: StringLiteral` (defaulted `""`) the customer supplies
#      when two functions genuinely share both row types. Folded when
#      non-empty.
#   3. A REFUSAL, so the residue is LOUD. A silent collision is the bug; a
#      compile error the customer can fix is not. `assert_row_udf_ids_differ`
#      below is the comptime half (a chain carrying two colliding row UDFs is
#      a COMPILE ERROR naming `id=`), and `lower_untyped_udf_segment`'s
#      recovery check now compares the derived NAME as well as the id, so a
#      same-id/different-shape `F` is REFUSED at recovery instead of silently
#      accepted.
#
# ⚠ `__builtin_LINE` DOES NOT EXIST on Mojo 1.0.0 — verified, `error: use of
# unknown declaration '__builtin_LINE'`. Do not re-propose a line-number salt.


def _fnv1a_32(s: StringSlice) -> UInt32:
    """FNV-1a 32 over the UTF-8 bytes. Comptime-evaluable."""
    var h = UInt32(2166136261)
    for i in range(s.byte_length()):
        h = (h ^ UInt32(s.as_bytes()[i])) * UInt32(16777619)
    return h


def row_type_signature[R: AnyType & Copyable & Movable]() -> String:
    """The comptime identity string of a row struct: its QUALIFIED name plus
    every field's name and DType.

    Rendered rather than hashed straight so it can be READ — it is what
    `lower_untyped_udf_segment`'s strengthened recovery check compares and
    what EXPLAIN shows, which is the difference between "the ids disagree"
    and "you threaded a `Order->Total` map into a `Order->Priced` segment".
    """
    comptime r = reflect[R]
    var out = String(r.name())
    out += "{"
    comptime ts = r.field_types()
    comptime for k in range(r.field_count()):
        comptime nm = String(r.field_names()[k])
        comptime dt = String(_row_field_dtype[ts[k]]())
        if k > 0:
            out += ","
        out += nm
        out += ":"
        out += dt
    out += "}"
    return out^


def _row_udf_signature_of(
    var kind: String, var in_sig: String, var out_sig: String, var id: String
) -> String:
    """Assemble the identity string. `id` is folded only when non-empty, so
    supplying one CHANGES the identity (which is the whole point) and
    omitting one costs nothing."""
    var out = kind^
    out += "("
    out += in_sig^
    out += "->"
    out += out_sig^
    out += ")"
    if id.byte_length() > 0:
        out += "#"
        out += id^
    return out^


def _row_udf_id_of(sig: String) -> UInt32:
    """The derived `UDF_ID` for an identity string.

    Emitted at or above 10000 so it can NEVER collide with the hand-assigned
    [7000, 9999] range the legacy conformers still occupy — the collision
    this replaces is between two DERIVED ids, and re-introducing one against
    the hand-picked range would be a new bug wearing the old one's clothes.
    """
    return UInt32(10000) + (_fnv1a_32(StringSlice(sig)) % UInt32(4294957295))


def row_map_udf_signature[
    In: AnyType & Copyable & Movable,
    Out: AnyType & Copyable & Movable,
    id: StringLiteral,
]() -> String:
    """The identity string of a row MAP: both row structs, fully qualified."""
    return _row_udf_signature_of(
        String("rowmap"),
        row_type_signature[In](),
        row_type_signature[Out](),
        String(id),
    )


def row_filter_udf_signature[
    In: AnyType & Copyable & Movable, id: StringLiteral
]() -> String:
    """The identity string of a row FILTER.

    ⚠ The output is spelled `bool` LITERALLY, not reflected. A predicate
    returns Mojo's `Bool`, which is NOT a row struct — `reflect[Bool]` has a
    field whose type is not a fixed-width numeric, so running the row-struct
    renderer over it is a COMPILE ERROR (measured; it is how this arm was
    found). The literal is also the honest render: a filter's output is not
    a schema.

    The `rowfilter` kind tag is what keeps a filter and a map over the SAME
    row struct from colliding."""
    return _row_udf_signature_of(
        String("rowfilter"),
        row_type_signature[In](),
        String("bool"),
        String(id),
    )


def assert_row_udf_ids_differ[a: UInt32, b: UInt32, what: StringLiteral]():
    """The comptime half of the collision guard: REFUSE two colliding row UDFs in one
    chain rather than silently computing one of them twice.

    `what` names the pair for the customer. The message names the escape,
    because a refusal the customer cannot act on is just a broken build."""
    comptime assert a != b, (
        "row UDF identity collision in "
        + what
        + ": two row UDFs in this chain derive the SAME UDF_ID. That happens"
        " when two DIFFERENT functions share BOTH row types — comptime cannot"
        " tell `def f(row: A) -> B` from `def g(row: A) -> B`, they are the"
        " same Mojo type. Give one of them an explicit disambiguator:"
        ' `.map[margin, id="margin"]()`. This is a COMPILE error on purpose:'
        " a shared id makes the plan-level recovery check accept the wrong"
        " function, which is a WRONG ANSWER, not a slow one."
    )


# =============================================================================
# §2 — `row_projection[R]` — the contract `_build_row_n`'s binding rests on
# =============================================================================


def row_projection[R: AnyType & Copyable & Movable]() -> List[String]:
    """`R`'s field names, IN DECLARED ORDER — the scan projection a row UDF
    requires.

    This is the other half of `_build_row_n`'s positional binding: pushed
    into the scan, it makes "field k is column k" true by construction
    rather than by hope. ⛔ A driver that does not set this as the
    projection must not call `_build_row_n`.
    """
    comptime r = reflect[R]
    var out = List[String](capacity=r.field_count())
    comptime for k in range(r.field_count()):
        comptime nm = String(r.field_names()[k])
        out.append(nm)
    return out^


# =============================================================================
# §3 — `RowFilterUdf[R, //, f, id]` — a `FilterFn` from a plain `def`
# =============================================================================
#
# The scalar sugar next door deliberately does NOT offer a filter adapter,
# and says why: `FilterFn` refines `Predicate`, so a conformer must supply
# `eval_scalar(batch, i)`, which reads a typed column off a `BatchView`
# through a dtype-dependent accessor (`col_f64(0)` / `col_i64(0)` / …), and
# deriving that needed "a dtype-dispatched column reader".
#
# `_build_row_n` IS that reader. `batch.col_scalar_nonraising[dt](k, i)` is
# dtype-parametric, so one body serves every arity and every fixed-width
# dtype tuple — which is why the filter half arrives here and not there.
#
# ⚠ ZERO FIELDS, ON PURPOSE. The struct carries no state: the function is a
# comptime PARAMETER, not a stored closure. That is what makes the per-worker
# `Copyable` clone free and the dispatch a direct monomorphized call.
#
# ⚠ AND IT MUST NOT FORECLOSE THE STATEFUL CASE. A `thin` fn pointer cannot
# capture; a `capturing` one can but then REJECTS a plain top-level `def`
# (measured). So a UDF that holds a lookup table uses an `@parameter def` in
# the owning scope, or keeps a hand-written struct conformer — both of which
# still conform to `FilterFn` directly and ride the SAME adapters. Nothing
# here narrows that; `FilterFn` remains the trait and this is one conformer
# of it.


@fieldwise_init
struct RowFilterUdf[
    R: AutoKomiraSchema & Deinitable, //,
    f: def(R) thin -> Bool,
    id: StringLiteral = "",
](FilterFn, ImplicitlyCopyable):
    """`FilterFn` over a plain `def(Row) -> Bool`. `R` is INFERRED from `f`.

    Parameters:
        R: the input row struct — inferred from `f`'s own signature.
        f: the customer's predicate.
        id: Identity disambiguator. Supply one only when two DIFFERENT
            predicates share the same row type; see §1.
    """

    comptime InRow = Self.R
    comptime InputSchema = _derive_schema[Self.R]()
    comptime UDF_SIGNATURE = row_filter_udf_signature[Self.R, Self.id]()
    comptime UDF_ID = _row_udf_id_of(Self.UDF_SIGNATURE)

    def keep_row(mut self, row: Self.InRow) -> Bool:
        """The `FilterFn` oracle — a direct, monomorphized call to `f`."""
        return Self.f(row)

    def eval_scalar[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) -> Bool:
        """The `Predicate` surface the Stage's filter slot calls per row.

        Builds `R` from row `i` (field k <- column k, per `row_projection`)
        and forwards to `f`. No fn-ptr, no trampoline: `Self.f` resolves at
        monomorphization."""
        return Self.f(_build_row_n[Self.R, bo](batch, i))


# =============================================================================
# §4 — `RowMapUdf[In, Out, //, m, id]` — the multi-output row map
# =============================================================================
#
# ⚠ THIS IS NOT A `MapFn`, AND CANNOT BE. `MapFn.run_row` returns
# `Scalar[OutType]`; `def margin(row: Order) -> Priced` returns a STRUCT, and
# no `DType` holds one. The multi-output row->row trait already in the tree is
# `RowTransform` (`komira_eval.row_transform`), and this is a conformer
# of the shape its `write_one` describes — but the Stage's projection slot is
# `ProjectsLike`, whose `emit_projected` builds the whole output batch, so the
# executable half lives with the other `ProjectsLike` conformers in
# `komira_engine_operators`. This struct is the CUSTOMER-FACING half: the
# comptime function plus the derived schemas and identity.
#
# It is deliberately NOT a second `MapFn`-family surface. Widening `MapFn` to
# a struct return would ripple through every existing conformer's
# `-> Scalar[OutType]` signature for a case none of them has.


@fieldwise_init
struct RowMapUdf[
    In: AutoKomiraSchema & Deinitable,
    Out: AutoKomiraSchema & Deinitable, //,
    m: def(In) thin -> Out,
    id: StringLiteral = "",
](Copyable, Movable, ImplicitlyCopyable):
    """A row map from a plain `def(InRow) -> OutRow`. BOTH types inferred.

    Parameters:
        In: the input row struct — inferred from `m`.
        Out: the output row struct — inferred from `m`.
        m: the customer's map function.
        id: Identity disambiguator; see §1.

    Comptime members:
        ARITY: the output column count, `reflect[Out].field_count()`.
        InputSchema / OutputSchema: derived from the two row structs —
            column NAMES included, which is the whole point of the row form.
    """

    comptime InRow = Self.In
    comptime OutRow = Self.Out
    comptime ARITY: Int = reflect[Self.Out].field_count()
    comptime InputSchema = _derive_schema[Self.In]()
    comptime OutputSchema = _derive_schema[Self.Out]()
    comptime UDF_SIGNATURE = row_map_udf_signature[Self.In, Self.Out, Self.id]()
    comptime UDF_ID = _row_udf_id_of(Self.UDF_SIGNATURE)

    @staticmethod
    def out_dtype_at[k: Int]() -> DType:
        """Output slot `k`'s DType, from `Out`'s field type."""
        return _row_field_dtype[reflect[Self.Out].field_types()[k]]()

    @always_inline
    def apply[bo: Origin[mut=False]](
        self, batch: BatchView[bo], i: Int
    ) -> Self.Out:
        """Build `In` from row `i` and run `m`. One call per row — the
        `ProjectsLike` adapter stores the results rather than re-running `m`
        once per OUTPUT COLUMN, which is what the arity-1-per-`Out`
        `ProjectList` shape would have forced."""
        return Self.m(_build_row_n[Self.In, bo](batch, i))
