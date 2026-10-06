# =============================================================================
# auto_schema.mojo — DerivedSchemaRow: comptime-reflected SchemaDescriptor
# =============================================================================
#
# The ergonomic, ADDITIVE alternative to the
# hand-written `schema_of[...]()` / `schema_of_strict[...]()` builders in
# `typed_schema.mojo`. Instead of spelling out every `(name, dtype-tag)` pair,
# a user declares a row struct and derives the schema from its declared fields
# via comptime reflection:
#
#     @fieldwise_init
#     struct Lineitem(DerivedSchemaRow):
#         var l_orderkey: Int64
#         var l_discount: Float64
#         var l_quantity: Float64
#         var l_extendedprice: Float64
#         var l_shipdate: Int32
#
#     comptime LineitemSchema = Lineitem.schema()   # auto-derived SchemaDescriptor
#
# The resulting `SchemaDescriptor` is byte-for-byte equal (field name + dtype
# tag) to what the hand-written `schema_of["l_orderkey", Int64Col, ...]()`
# builder produces — see `tests/test_auto_schema.mojo` (the auto-vs-hand
# equality acceptance test).
#
# This sits ALONGSIDE the hand-written builders — it does NOT replace them. The
# hand-written `schema_of` / `schema_of_strict` path remains the canonical way
# to declare a *subset* schema (declare fewer columns than the file has) or to
# attach STRUCT / MAP / nullability metadata that a flat struct can't express.
# `DerivedSchemaRow` is the ergonomic option for the common case: a row struct
# whose fields ARE the full flat schema.
#
# Validated POC: the poc_auto_schema_ergonomics probe (§1, GREEN on Mojo
# 1.0.0b1). The POC proved `reflect[T]()` enumerates field names + types at
# comptime. This module productionizes that shape against the real 6-field
# `ColDescriptor` (name, dtype, nullable, struct_fields, map_key_dtype,
# map_value_dtype) rather than the POC's minimal 2-field mirror.
# =============================================================================


from komira_plan_expr.typed_schema import (
    SchemaDescriptor,
    ColDescriptor,
    TYPE_UNKNOWN,
    TYPE_INT8,
    TYPE_INT16,
    TYPE_INT32,
    TYPE_INT64,
    TYPE_UINT8,
    TYPE_UINT16,
    TYPE_UINT32,
    TYPE_UINT64,
    TYPE_FLOAT32,
    TYPE_FLOAT64,
    TYPE_BOOL,
    TYPE_STRING,
    TYPE_DECIMAL128,
)


# =============================================================================
# `_dtype_tag_for[T]()` — map a Mojo field type to a TYPE_* tag.
# =============================================================================
# Comptime type-equality dispatch (mirrors the POC's `_dtype_tag_for`). Only the
# scalar leaf types a flat row struct can declare are handled; nested STRUCT /
# MAP columns are not expressible as a single Mojo field type, so they stay on
# the hand-written `schema_of[...]` + `_NS` / `_NM` path. Date / Timestamp
# columns are stored as their underlying integer Mojo type in a row struct
# (TPC-H DATE is Int32 days-since-epoch), so they map to the integer tag here;
# if a caller needs the Date32 / Timestamp *tag* specifically, they declare it
# via the hand-written builder.
#
# ⛔ DECIMAL128 IS NO LONGER ON THAT LIST (2026-09-22), AND THE SENTENCE THAT
# PUT IT THERE WAS COSTING CELLS. It read "Date / Timestamp / Decimal columns
# ... map to the integer tag here", and three other files quoted it as the
# reason a decimal column has no admissible declaration on the `DerivedSchemaRow`
# path at all: `komira_pplan/dtype_compat.mojo`'s header ("`DerivedSchemaRow`
# cannot express DECIMAL128, so a TPC-H `l_extendedprice` stored as a decimal
# has NO admissible declaration") and `//src/cmd/plan_matrix_typed_rig`'s
# `_type_absence_reason`, which charged 10 cross-surface corpus cells to this
# module.
#
# ⚠ AND "maps to the integer tag" WOULD HAVE BEEN A WRONG ANSWER, NOT A
# NARROWER ONE. A decimal declared `Int64` reads the LOW 8 BYTES of a 16-byte
# two's-complement cell and erases the scale — `decimal128(12,2)/40.00` comes
# back `4000` — which is why `pplan_storage_type_of` deliberately maps
# DECIMAL128 to ITSELF rather than to any integer. So the arm below is a
# SEPARATE tag, not a reuse of the integer one.
# =============================================================================


def _dtype_tag_for[T: AnyType]() -> Int:
    """Map a Mojo type to a TYPE_* tag via comptime type equality.

    Returns TYPE_UNKNOWN for any type a flat row struct can't faithfully carry
    as a single declared scalar field (STRUCT / MAP / Date32 / Timestamp).
    Those stay on the hand-written `schema_of[...]` path.

    ⛔ AND `TYPE_UNKNOWN` IS NOT A REFUSAL — MEASURED 2026-09-22, AND IT IS THE
    REASON THE `Int128` ARM BELOW IS A SEPARATE TAG RATHER THAN A FALLTHROUGH.
    `typed_schema.arrow_type_of` ends in a bare `return ArrowType.INT64`, so an
    unmapped field type comes out of this function as TYPE_UNKNOWN and out of
    `arrow_type_of` as **int64** — and
    `komira_pplan.dtype_compat.pplan_dtype_is_compatible(int64, INT64 footer)`
    is then `True`. An unrecognised declaration is therefore silently ADMITTED
    over an int64 column. That hazard is OUT OF SCOPE here (the fallthrough is
    in `komira_plan_expr`, read by far more than this module) and is recorded rather
    than papered over; do not "fix" it by making this function raise, which
    would change the documented STRUCT/MAP story at the same time.
    """
    comptime if (T == Float64):
        return TYPE_FLOAT64
    elif (T == Float32):
        return TYPE_FLOAT32
    elif (T == Int64):
        return TYPE_INT64
    elif (T == Int32):
        return TYPE_INT32
    elif (T == Int16):
        return TYPE_INT16
    elif (T == Int8):
        return TYPE_INT8
    elif (T == UInt64):
        return TYPE_UINT64
    elif (T == UInt32):
        return TYPE_UINT32
    elif (T == UInt16):
        return TYPE_UINT16
    elif (T == UInt8):
        return TYPE_UINT8
    elif (T == Bool):
        return TYPE_BOOL
    elif (T == String):
        return TYPE_STRING
    # ★★ DECIMAL128, VIA `Int128` — the corpus's `decimal128_12_2` column, and
    # the one corpus type on the `mojo_typed` door whose blocker was THIS
    # MODULE rather than a rig recompile (10 cells at one commit:
    # `filter`/`decimal128_12_2` x 5 variants and `filter_project` likewise).
    #
    # ⛔ WHY `Int128` AND NOT A PRECISION/SCALE-CARRYING TYPE. `ColDescriptor`
    # has SIX fields and none of them is a precision or a scale, so a
    # `Decimal128[p, s]` field type would carry two values this schema cannot
    # store and would DROP them at derive time — a declaration that silently
    # loses information is worse than one that never claimed it. The
    # hand-written builder has had exactly this shape since the tag existed:
    # `Decimal128Col` is `TYPE_DECIMAL128` with no (p, s) either, and the
    # precision/scale come from the FOOTER. This arm makes the reflected path
    # agree with the hand-written one instead of inventing a second convention.
    #
    # ⛔ AND WHY THE TAG IS DECIMAL128 RATHER THAN AN INTEGER ONE. Arrow has no
    # int128 primitive: DECIMAL128 *is* the 16-byte two's-complement integer
    # type, `Decimal128Array` stores it as `N x 16` bytes, and
    # `Decimal128Array.get_i128` hands it back as `SIMD[DType.int128, 1]` —
    # i.e. `Int128` IS this column's storage type in Mojo, exactly as `Int32`
    # is DATE32's. MEASURED, all three with a local
    # `mojo run` probe: `arrow_type_of(TYPE_DECIMAL128)` is `decimal128`,
    # `pplan_storage_type_of(DECIMAL128)` is `decimal128` (itself, on purpose),
    # and `pplan_dtype_is_compatible(decimal128, DECIMAL128 footer)` is `True`
    # — so this one arm is SUFFICIENT for the declared-vs-footer handshake to
    # admit the column. Before it, the same declaration came out int64 and the
    # handshake REFUSED with a message naming a type the caller never wrote.
    elif (T == Int128):
        return TYPE_DECIMAL128
    else:
        return TYPE_UNKNOWN


# =============================================================================
# `derive_schema[T]()` — the reflection-driven SchemaDescriptor builder.
# =============================================================================
# Walks `T`'s declared fields via `reflect[T]()`, emitting one `ColDescriptor`
# per field with `(field_name, dtype_tag, nullable=False)`. The output is
# comptime-computable when `T` is concrete (the names + types are comptime).
# A non-STRUCT / non-MAP descriptor: `struct_fields` is empty, the map slots
# are TYPE_UNKNOWN — matching the 6-arg `ColDescriptor` shape that `schema_of`'s
# `_NN` helper produces, so the auto-derived descriptor compares equal to the
# hand-written one.
# =============================================================================


def derive_schema[T: AnyType & Copyable & Movable]() -> SchemaDescriptor:
    """Auto-derive a `SchemaDescriptor` from `T`'s declared fields via
    `reflect[T]()`. Each field becomes a non-nullable `ColDescriptor` whose
    dtype tag comes from `_dtype_tag_for[field_type]()`.

    The `strict` flag is False (subset-allowed semantics, matching `schema_of`;
    use `schema_of_strict[...]` if you need extras-rejection).

    Examples:
        ```mojo
        from komira_sdk.auto_schema import derive_schema
        # a plain @fieldwise_init struct is enough — no schema_of[...] by hand
        @fieldwise_init
        struct Row(Copyable, Movable):
            var id: Int64
            var amount: Float64
        comptime RowSchema = derive_schema[Row]()   # {id: Int64, amount: Float64}
        ```
    (LIFT bench/engine/tpch/q1.mojo:54 — LineitemQ1Row(DerivedSchemaRow))
    """
    comptime r = reflect[T]
    comptime ts = r.field_types()
    var cols = List[ColDescriptor]()
    comptime for i in range(r.field_count()):
        comptime nm = String(r.field_names()[i])
        comptime tag = _dtype_tag_for[ts[i]]()
        cols.append(
            ColDescriptor(
                nm,
                tag,
                False,
                List[ColDescriptor](),
                TYPE_UNKNOWN,
                TYPE_UNKNOWN,
            )
        )
    return SchemaDescriptor(cols^, False)


# =============================================================================
# `DerivedSchemaRow` trait — the user-facing ergonomic surface.
# =============================================================================
# A row struct whose schema is auto-derived from its declared fields. The
# conformer adds NO body:
#
#     @fieldwise_init
#     struct Lineitem(DerivedSchemaRow):
#         var l_orderkey: Int64
#         ...
#
# `Lineitem.schema()` returns the auto-derived `SchemaDescriptor`. The trait
# carries a default-implementation `schema()` static method (validated GREEN in
# the POC), so conformers inherit it for free.
# =============================================================================


trait DerivedSchemaRow(Copyable, Movable):
    """A row struct whose `SchemaDescriptor` is auto-derived from its declared
    fields via comptime reflection.

    Default-method `schema()` returns a runtime `SchemaDescriptor` mirroring the
    conformer's flat field layout (name + dtype tag, nullable=False, strict=
    False). Conformers add NO body — `@fieldwise_init struct Foo(DerivedSchemaRow):
    var ...` is the full declaration.

    This is the ergonomic, additive alternative to the hand-written
    `schema_of[...]()` builders in `typed_schema.mojo`; both produce an
    equal `SchemaDescriptor` for a flat schema (see `tests/test_auto_schema.mojo`).

    Examples:
        ```mojo
        from komira_sdk.auto_schema import DerivedSchemaRow
        # the row struct passed to ctx.read_file_typed[..., Row]
        @fieldwise_init
        struct LineitemQ1Row(DerivedSchemaRow):
            var l_returnflag: String
            var l_linestatus: String
            var l_quantity: Float64
        # LineitemQ1Row.schema() is auto-derived — no hand-written schema_of
        ```
    (LIFT bench/engine/tpch/q1.mojo:53-62)
    """

    @staticmethod
    def schema() -> SchemaDescriptor:
        return derive_schema[Self]()
