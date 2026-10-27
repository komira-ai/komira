# =============================================================================
# bulk_fields.mojo — the dynamic-mapping state of the `_bulk` translator
# =============================================================================
#
# The per-field accumulators, the staged fields of a candidate document and the
# typed RecordBatch builder that `ndjson_bulk_to_docbatch` (bulk.mojo) drives.
# A pure value layer: plain Lists of String / Float64 / Bool / Int64, no
# pointers.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_json import (
    JsonValue,
    JSON_STRING,
    JSON_NUMBER,
)

from .bulk_columns import str_col_nullable, i64_col_nullable, f64_col_nullable


# -----------------------------------------------------------------------------
# Inferred-field type codes (the v1 dynamic-mapping set).
# -----------------------------------------------------------------------------
#
# The translator infers ONLY these three Arrow types (the set the SearchSink
# classifier reliably keeps as fast-fields): STRING (keyword), INT64 (long),
# FLOAT64 (double). bool/null/object/array do NOT produce a fast-field column.
comptime INFER_STRING: Int = 0
comptime INFER_INT64: Int = 1
comptime INFER_FLOAT64: Int = 2


struct FieldAccum(Copyable, Movable, Deinitable):
    """A per-inferred-field accumulator (P1.6 pass-2 state). One per UNION-schema
    field name; the values List is positionally aligned to the COMMITTED-doc
    index (a committed doc that omits the field contributes a null cell).

    Copyable (synthesized): every field is ImplicitlyCopyable (String + List of
    String/Int64/Float64/Bool) so the accumulator can live in a `List[FieldAccum]`
    (Mojo: `List[T]` requires `T: Copyable`).
    never a byte-slab element.

    The inferred Arrow type is fixed by the FIRST committed non-null occurrence. A later value either fits (stored), coerces (int->FLOAT64), or
    rejects the candidate doc (P1.7: the candidate is excluded, NOT raised).

    Storage: a string field keeps its values in `str_vals` + `valid`; a numeric
    field keeps its values in `f64_vals` (FLOAT64) or `i64_vals` (INT64) + `valid`.
    Only the List matching `inferred` is populated. All are plain stack Lists —
   

    Fields:
      name:      the field name (the Arrow column name).
      inferred:  INFER_STRING / INFER_INT64 / INFER_FLOAT64.
      str_vals:  per-committed-doc string values (INFER_STRING).
      i64_vals:  per-committed-doc int values (INFER_INT64).
      f64_vals:  per-committed-doc float values (INFER_FLOAT64).
      valid:     per-committed-doc validity (True = present non-null; False = null)."""

    var name: String
    var inferred: Int
    var str_vals: List[String]
    var i64_vals: List[Int64]
    var f64_vals: List[Float64]
    var valid: List[Bool]

    def __init__(out self, var name: String, inferred: Int):
        self.name = name^
        self.inferred = inferred
        self.str_vals = List[String]()
        self.i64_vals = List[Int64]()
        self.f64_vals = List[Float64]()
        self.valid = List[Bool]()

    def _pad_to(mut self, doc_index: Int):
        """Back-fill null cells for committed docs [len(valid), doc_index) that
        did not carry this field (it was first seen at a later committed doc, or
        skipped earlier). Keeps the value Lists positionally aligned to the
        committed-doc index."""
        while len(self.valid) < doc_index:
            self.valid.append(False)
            if self.inferred == INFER_STRING:
                self.str_vals.append(String(""))
            elif self.inferred == INFER_INT64:
                self.i64_vals.append(Int64(0))
            else:
                self.f64_vals.append(Float64(0.0))


struct StagedField(Copyable, Movable, Deinitable):
    """A per-candidate-doc staged field (P1.7 pass-1 output). The (name, inferred
    kind, EAGERLY-EXTRACTED value) for a single fast-fieldable scalar field of a
    candidate doc — staged in phase 1 so phase 2 can resolve the union schema
    with per-doc conflict EXCLUSION (a conflict drops the whole candidate, so the
    per-doc fields must be applied atomically, after the no-conflict check).

    Copyable (synthesized): String + Int + Int64 + Float64 — all
    ImplicitlyCopyable. NOTE: a `JsonValue` field would BREAK Copyable synthesis
    (Mojo: JsonValue is explicitly-copyable, NOT ImplicitlyCopyable), so
    the scalar is extracted EAGERLY during phase 1 into the typed slot matching
    `kind`.

    Only the slot matching `kind` is populated (str_val for INFER_STRING,
    i64_val for INFER_INT64, f64_val for INFER_FLOAT64). The int->FLOAT64 widen
    at commit reads `i64_val` as a float.

    Fields:
      name:    the field name.
      kind:    the per-value inferred kind (INFER_STRING/INT64/FLOAT64).
      str_val: the string value (INFER_STRING; empty otherwise).
      i64_val: the int value (INFER_INT64; 0 otherwise).
      f64_val: the float value (INFER_FLOAT64; 0.0 otherwise)."""

    var name: String
    var kind: Int
    var str_val: String
    var i64_val: Int64
    var f64_val: Float64

    def __init__(
        out self,
        var name: String,
        kind: Int,
        var str_val: String,
        i64_val: Int64,
        f64_val: Float64,
    ):
        self.name = name^
        self.kind = kind
        self.str_val = str_val^
        self.i64_val = i64_val
        self.f64_val = f64_val


struct PendingDoc(Copyable, Movable, Deinitable):
    """A candidate good doc staged by phase 1 (P1.7). It cleared per-pair
    validation (an `index` action + a present non-string-checked text field + no
    nested/array/reserved-key field). It still must clear phase-2 type-conflict
    resolution to be COMMITTED.

    Copyable (synthesized): String + List[StagedField].

    Fields:
      item_index: the index into the NDJSON-order BulkItem list this doc owns
                  (so phase 2 can flip that item to a failure on a conflict).
      client_id:  the action `_id` / minted ordinal (the item echo).
      text_value: the (already-unescaped) text-field value -> the body column.
      source_line: the VERBATIM source line -> the _source blob.
      staged:     this doc's fast-fieldable fields (name, kind, value)."""

    var item_index: Int
    var client_id: String
    var text_value: String
    var source_line: String
    var staged: List[StagedField]

    def __init__(
        out self,
        item_index: Int,
        var client_id: String,
        var text_value: String,
        var source_line: String,
        var staged: List[StagedField],
    ):
        self.item_index = item_index
        self.client_id = client_id^
        self.text_value = text_value^
        self.source_line = source_line^
        self.staged = staged^


def arrow_type_for_infer(inferred: Int) -> ArrowType:
    if inferred == INFER_STRING:
        return ArrowType.STRING
    elif inferred == INFER_INT64:
        return ArrowType.INT64
    else:
        return ArrowType.FLOAT64


def infer_kind_for_value(value_kind: Int, value: JsonValue) -> Int:
    """Map a (non-null, fast-fieldable) JSON value's kind to an INFER_* code.
    Returns -1 for a value that is NOT fast-fieldable (a nested object/array) —
    the caller fails the ITEM (P1.7) rather than raising.

    string -> INFER_STRING; integer number -> INFER_INT64; fractional/exponent
    number -> INFER_FLOAT64. A bool/null is handled BEFORE this (no column). A
    nested object/array -> -1 (the item is rejected)."""
    if value_kind == JSON_STRING:
        return INFER_STRING
    if value_kind == JSON_NUMBER:
        if value.is_integral_number():
            return INFER_INT64
        return INFER_FLOAT64
    # JSON_OBJECT / JSON_ARRAY reach here (bool/null filtered by the caller).
    return -1


def infer_name(inferred: Int) -> StaticString:
    if inferred == INFER_STRING:
        return "keyword(string)"
    elif inferred == INFER_INT64:
        return "long(int64)"
    else:
        return "double(float64)"


def kind_fits(established: Int, this_kind: Int) -> Bool:
    """True iff a value of `this_kind` fits a field already established as
    `established` under the first-wins + int->FLOAT64-widen policy:
      * exact type match -> fits.
      * int arriving at a FLOAT64 field -> fits (widened, lossless).
      * anything else -> a conflict."""
    if this_kind == established:
        return True
    if established == INFER_FLOAT64 and this_kind == INFER_INT64:
        return True
    return False


def append_staged(mut acc: FieldAccum, sf: StagedField):
    """Append a staged (non-null) value to an accumulator. The caller has proved
    the staged kind fits `acc.inferred` (a net-new accumulator is created with
    the staged field's own kind; an established accumulator passed the
    `kind_fits` dry check). The ONE coercion: a staged INT64 at a FLOAT64
    accumulator widens to float (lossless)."""
    acc.valid.append(True)
    if acc.inferred == INFER_STRING:
        acc.str_vals.append(sf.str_val)
    elif acc.inferred == INFER_INT64:
        acc.i64_vals.append(sf.i64_val)
    else:
        # FLOAT64 accumulator: a staged FLOAT64 stores f64_val; a staged INT64
        # (the widen case) reads i64_val as a float.
        if sf.kind == INFER_INT64:
            acc.f64_vals.append(Float64(sf.i64_val))
        else:
            acc.f64_vals.append(sf.f64_val)


def build_doc_batch(
    text_field: String,
    text_values: List[String],
    source_values: List[String],
    fields: List[FieldAccum],
) raises -> RecordBatch:
    """Build the N-column DocBatch (P1.6):
        {<text_field>: STRING non-null,
         _source: STRING non-null,
         <field_1>: <inferred type> nullable, ...}
    The text + _source columns are non-nullable (SearchSink
    .init_sink raises if the _source col is absent). Each inferred field is a
    NULLABLE typed column with per-doc null cells. Column order matches schema
    order (init_sink resolves text/_source by NAME, so the inferred columns may
    follow in any order —)."""
    var ta = StringArray.from_strings(text_values)
    var sa = StringArray.from_strings(source_values)
    var sb = SchemaBuilder()
    sb.add_field(Field(text_field, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    for fi in range(len(fields)):
        sb.add_field(
            Field(
                fields[fi].name,
                arrow_type_for_infer(fields[fi].inferred),
                True,
            )
        )
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2 + len(fields))
    rb.add_column(Column.from_string(ta^))
    rb.add_column(Column.from_string(sa^))
    for fi in range(len(fields)):
        ref f = fields[fi]
        if f.inferred == INFER_STRING:
            rb.add_column(str_col_nullable(f.str_vals, f.valid))
        elif f.inferred == INFER_INT64:
            rb.add_column(i64_col_nullable(f.i64_vals, f.valid))
        else:
            rb.add_column(f64_col_nullable(f.f64_vals, f.valid))
    return rb.build(schema^)
