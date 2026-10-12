# =============================================================================
# project_access: projection arms that read inside a value
# =============================================================================
#
# Struct fields (by name and by index), map lookups, `json_extract`, and
# temporal `extract`. Each is one arm of `eval_column._eval_column_expr`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_json_index.json_extract_kernel import extract_column as json_extract_column
from komira_kernels.temporal_extract import (
    TRUNC_DAY,
    TRUNC_HOUR,
    TRUNC_MICROSECOND,
    TRUNC_MILLISECOND,
    TRUNC_MINUTE,
    TRUNC_MONTH,
    TRUNC_QUARTER,
    TRUNC_SECOND,
    TRUNC_WEEK,
    TRUNC_YEAR,
    date_trunc_date32,
    date_trunc_ts,
    extract_day_date32,
    extract_day_index_date32,
    extract_day_index_ts,
    extract_day_ts,
    extract_hour_ts,
    extract_iso_week_date32,
    extract_iso_week_ts,
    extract_minute_ts,
    extract_month_date32,
    extract_month_ts,
    extract_quarter_date32,
    extract_quarter_ts,
    extract_second_ts,
    extract_subday_zero_date32,
    extract_subsecond_ts,
    extract_year_date32,
    extract_year_ts,
)
from komira_plan_expr.expr import (
    EXTRACT_DAY,
    EXTRACT_DAYOFWEEK,
    EXTRACT_DAYOFYEAR,
    EXTRACT_HOUR,
    EXTRACT_ISODOW,
    EXTRACT_ISOYEAR,
    EXTRACT_MICROSECOND,
    EXTRACT_MILLISECOND,
    EXTRACT_MINUTE,
    EXTRACT_MONTH,
    EXTRACT_QUARTER,
    EXTRACT_SECOND,
    EXTRACT_TRUNC_DAY,
    EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MICROSECOND,
    EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MINUTE,
    EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_QUARTER,
    EXTRACT_TRUNC_SECOND,
    EXTRACT_TRUNC_WEEK,
    EXTRACT_TRUNC_YEAR,
    EXTRACT_WEEK,
    EXTRACT_YEAR,
    EXTRACT_YEARWEEK,
    Expr,
    _is_trunc_unit,
)

from .column_decimal import _expr_name_hint, _resolve_temporal_arrow_type
from .eval_column import _eval_column_expr


def _project_struct_field(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_STRUCT_FIELD` arm of `_eval_column_expr`."""
    # STRUCT field — by-name variant.
    # Evaluate the parent (must yield a STRUCT Column), then extract
    # the named child by linear-scanning `_field_names`. Returns a
    # deep-copy of the child Column so the result is independent of
    # the parent's storage lifetime. Column is Movable-not-Copyable,
    # so deep_copy is the only safe shape here (no share/ArcPointer
    # path exists). The cost is one buffer copy per projection per
    # batch; for typical morsel sizes (~64K rows) this is negligible.
    # The typed-DF surface emits EXPR_STRUCT_FIELD_IDX (below) to skip
    # this scan when the schema is known at comptime.
    var parent_col = _eval_column_expr(expr.struct_field_parent_ref(), batch)
    if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRUCT.type_id):
        raise Error(
            "PipelineCompiler: EXPR_STRUCT_FIELD parent must be STRUCT, got type_id="
            + String(Int(parent_col.arrow_type.type_id))
        )
    var field_name = expr.struct_field_name()
    var n_children = parent_col.num_children()
    for i in range(n_children):
        if parent_col.field_name(i) == field_name:
            return parent_col.child_at(i).deep_copy()
    raise Error(
        "PipelineCompiler: STRUCT has no field named '" + field_name + "'"
    )


def _project_struct_field_idx(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_STRUCT_FIELD_IDX` arm of `_eval_column_expr`."""
    # STRUCT field — by-idx variant.
    # The typed DF chain method `df.field[parent, name]` has already
    # resolved `field_idx` at COMPTIME via the typed schema, so the
    # eval arm just type-checks the parent + range-checks the idx and
    # indexes `_children` directly — no `_field_names` scan. Mirrors
    # the EXPR_COL_REF -> EXPR_COL_IDX bound-twin pattern.
    var parent_col = _eval_column_expr(expr.struct_field_idx_parent_ref(), batch)
    if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRUCT.type_id):
        raise Error(
            "PipelineCompiler: EXPR_STRUCT_FIELD_IDX parent must be STRUCT, got type_id="
            + String(Int(parent_col.arrow_type.type_id))
        )
    var field_idx = expr.struct_field_index()
    var n_children = parent_col.num_children()
    if field_idx < 0 or field_idx >= n_children:
        raise Error(
            "PipelineCompiler: EXPR_STRUCT_FIELD_IDX field_idx="
            + String(field_idx) + " out of range (STRUCT has "
            + String(n_children) + " children)"
        )
    return parent_col.child_at(field_idx).deep_copy()


def _project_map_get(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_MAP_GET` arm of `_eval_column_expr`."""
    # MAP[key] lookup.
    #
    # Arrow MAP layout: `list<entries: struct<key, value>>`. The parent
    # column has:
    #   - `_offsets`: N+1 Int32 offsets (offsets[i]..offsets[i+1] is the
    #     range of entries for row i).
    #   - `_children[0]`: the entries STRUCT column with two children
    #     (`_children[0]._children[0]` = key column, `_children[0]._children[1]`
    #     = value column).
    #   - `_keys_sorted`: trust the producer (no runtime validation in
    #     this arm — binary search is a later opt-in if a profile demands).
    #
    # Eval: per row r of the parent, scan its entries [start..end) for
    # the entry whose key equals the row's key value (from the key
    # expression, broadcast or per-row); emit the matching value, or
    # NULL on miss / parent-null.
    #
    # X1b SCOPE: supports STRING keys with STRING or INT64 values
    # (the canonical JSON-shape Map usage).  Other types raise a clear
    # "not yet supported" error — follow-on work covers numeric keys
    # + value types beyond STRING/INT64.  Output column null-marks
    # rows where the key isn't present or the parent row is null.
    var parent_col = _eval_column_expr(expr.map_get_parent_ref(), batch)
    if Int(parent_col.arrow_type.type_id) != Int(ArrowType.MAP.type_id):
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET parent must be MAP, got type_id="
            + String(Int(parent_col.arrow_type.type_id))
        )
    if parent_col.num_children() != 1:
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET MAP column must have exactly"
            " 1 child (entries struct), got "
            + String(parent_col.num_children())
        )
    var key_col = _eval_column_expr(expr.map_get_key_ref(), batch)
    # The entries STRUCT child of MAP carries keys + values as its 2
    # sub-children (Arrow spec).  Audit confirms `MapArray.to_column`
    # always lays this out (`map_array.mojo:336-345`).
    ref entries_col = parent_col.child_at(0)
    if entries_col.num_children() != 2:
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET MAP entries struct must have"
            " 2 children (key, value), got "
            + String(entries_col.num_children())
        )
    ref entry_keys = entries_col.child_at(0)
    ref entry_values = entries_col.child_at(1)
    # Currently support: STRING keys.  Other keys raise.
    if Int(entry_keys.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET only supports STRING keys in"
            " v0.4 X1b (got key type_id="
            + String(Int(entry_keys.arrow_type.type_id))
            + "); follow-on work covers numeric keys"
        )
    if Int(key_col.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET key expression must produce a"
            " STRING column (got type_id="
            + String(Int(key_col.arrow_type.type_id)) + ")"
        )
    # Now scan per-row: linear scan (no binary search on
    # `_keys_sorted=True` yet).
    var n_rows = parent_col.length()
    var keys_sa = entry_keys.as_string()
    var probe_sa = key_col.as_string()
    # Output type comes from the value child.  Two paths: STRING values
    # and INT64 values, the two canonical Map value types.
    var value_type_id = Int(entry_values.arrow_type.type_id)
    if value_type_id == Int(ArrowType.STRING.type_id):
        # String-value output: build a List[String] + validity bitmap.
        var vals_sa = entry_values.as_string()
        var out_strs = List[String](capacity=n_rows)
        var validity = Bitmap.create_all_valid(n_rows)
        var null_count = 0
        for i in range(n_rows):
            if parent_col._validity:
                if not parent_col._validity.value().test(i):
                    out_strs.append(String(""))
                    validity.clear(i)
                    null_count += 1
                    continue
            var start = Int(parent_col._offsets.value().get_typed[Int32](i))
            var end = Int(parent_col._offsets.value().get_typed[Int32](i + 1))
            var probe = probe_sa.get(i)
            var found = False
            for e in range(start, end):
                if keys_sa.get(e) == probe:
                    out_strs.append(vals_sa.get(e))
                    found = True
                    break
            if not found:
                out_strs.append(String(""))
                validity.clear(i)
                null_count += 1
        var out_sa = StringArray.from_strings(out_strs)
        # Attach validity if any nulls.
        if null_count > 0:
            out_sa.validity = validity^
            out_sa.null_count = null_count
        return Column.from_string(out_sa^)
    elif value_type_id == Int(ArrowType.INT64.type_id):
        # Int64-value output: per-row scan, build a PrimitiveArray[int64]
        # + validity bitmap.
        var vals_pa = entry_values.as_primitive[DType.int64]()
        var out_ints = List[Scalar[DType.int64]](capacity=n_rows)
        var validity = Bitmap.create_all_valid(n_rows)
        var null_count = 0
        for i in range(n_rows):
            if parent_col._validity:
                if not parent_col._validity.value().test(i):
                    out_ints.append(Scalar[DType.int64](0))
                    validity.clear(i)
                    null_count += 1
                    continue
            var start = Int(parent_col._offsets.value().get_typed[Int32](i))
            var end = Int(parent_col._offsets.value().get_typed[Int32](i + 1))
            var probe = probe_sa.get(i)
            var found = False
            for e in range(start, end):
                if keys_sa.get(e) == probe:
                    out_ints.append(vals_pa.get(e))
                    found = True
                    break
            if not found:
                out_ints.append(Scalar[DType.int64](0))
                validity.clear(i)
                null_count += 1
        var out_pa = PrimitiveArray[DType.int64].from_list(out_ints)
        if null_count > 0:
            out_pa.validity = validity^
            out_pa.null_count = null_count
        return Column.from_primitive[DType.int64](out_pa^)
    else:
        raise Error(
            "PipelineCompiler: EXPR_MAP_GET only supports STRING or INT64"
            " value types in v0.4 X1b (got value type_id="
            + String(value_type_id) + ")"
        )


def _project_json_extract(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_JSON_EXTRACT` arm of `_eval_column_expr`."""
    # json_extract + SQL `->` / `->>`.
    # Evaluate the parent (must yield a STRING Column of JSON text),
    # then dispatch to the stage-2-skip walker in
    # komira_json_index/json_extract_kernel.mojo (a path-aware fast path).
    # The kernel ships bytes-correct output; the extension-metadata
    # attachment for `->` (`ARROW:extension:name = "komira.ext.json"`)
    # lives at the Field level — here the bit is surfaced on the Column
    # via the kernel's `preserve_extension_metadata` flag, and Field-level
    # kv-metadata round-trip is the SDK layer's job. The byte content of the
    # two operators is identical for non-string scalars; the diff
    # `->` returns raw JSON text including quotes).
    #
    # ⚠ WITH ONE EXCEPTION: the JSON LITERAL `null`. "Identical for
    # non-string scalars" holds for numbers and for
    # `true`/`false`; for `null` the two operators DIVERGE — `->`
    # keeps the three-byte JSON text and `->>` returns **SQL NULL**,
    # because a JSON null has no VARCHAR form. DuckDB v1.5.3 and
    # Postgres `jsonb ->>` both do this. The kernel's scalar arm makes the distinction;
    # nothing here changes.
    var parent_col = _eval_column_expr(expr.json_extract_parent_ref(), batch)
    if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
        raise Error(
            "PipelineCompiler: EXPR_JSON_EXTRACT parent must be STRING,"
            " got type_id=" + String(Int(parent_col.arrow_type.type_id))
        )
    var path_segs = expr.json_extract_path_segments()
    var out_type = expr.json_extract_output_type()
    var preserve = expr.json_extract_preserve_extension_metadata()
    return json_extract_column(parent_col, path_segs^, out_type, preserve)


def _project_extract(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_EXTRACT` arm of `_eval_column_expr`."""
    # temporal field
    # extraction (year / month / day / hour / minute / second /
    # quarter) and date_trunc(unit).  Dispatch on (unit, child_arrow_type).
    var child_col = _eval_column_expr(expr.extract_child_ref(), batch)
    var unit = expr.extract_unit()
    # ⚠ THE TYPE COMES FROM `_resolve_temporal_arrow_type`, NOT FROM
    # `child_col.arrow_type`, AND THAT ONE LINE IS WHAT MAKES THIS NODE
    # REACHABLE OVER A PARQUET SCAN AT ALL. The reader hands back a
    # PHYSICALLY-stamped column (INT32 for a DATE32, INT64 for a
    # TIMESTAMP_*) and carries the logical type on the schema FIELD; the
    # bare stamp read here before refused every one of them.
    var src_at = _resolve_temporal_arrow_type(
        child_col, batch, _expr_name_hint(expr.extract_child_ref())
    )
    var is_date32 = src_at == ArrowType.DATE32
    var is_ts = (
        src_at == ArrowType.TIMESTAMP
        or src_at == ArrowType.TIMESTAMP_S
        or src_at == ArrowType.TIMESTAMP_MS
        or src_at == ArrowType.TIMESTAMP_US
        or src_at == ArrowType.TIMESTAMP_NS
    )
    if not (is_date32 or is_ts):
        raise Error(
            "PipelineCompiler: EXPR_EXTRACT child must be DATE32 or"
            " TIMESTAMP_*, got type_id="
            + String(Int(child_col.arrow_type.type_id))
            + " and the batch schema does not declare it temporal either"
        )
    # --- date_trunc family ---
    if _is_trunc_unit(unit):
        # Map the IR EXTRACT_TRUNC_* tag onto the kernel TRUNC_* tag.
        # Kernel uses a tight 0..9 encoding (TRUNC_YEAR=0 ...
        # TRUNC_MICROSECOND=9); IR uses 16..25.
        var k_unit: UInt8 = TRUNC_YEAR
        if unit == EXTRACT_TRUNC_YEAR:
            k_unit = TRUNC_YEAR
        elif unit == EXTRACT_TRUNC_QUARTER:
            k_unit = TRUNC_QUARTER
        elif unit == EXTRACT_TRUNC_MONTH:
            k_unit = TRUNC_MONTH
        elif unit == EXTRACT_TRUNC_WEEK:
            k_unit = TRUNC_WEEK
        elif unit == EXTRACT_TRUNC_DAY:
            k_unit = TRUNC_DAY
        elif unit == EXTRACT_TRUNC_HOUR:
            k_unit = TRUNC_HOUR
        elif unit == EXTRACT_TRUNC_MINUTE:
            k_unit = TRUNC_MINUTE
        elif unit == EXTRACT_TRUNC_SECOND:
            k_unit = TRUNC_SECOND
        elif unit == EXTRACT_TRUNC_MILLISECOND:
            k_unit = TRUNC_MILLISECOND
        elif unit == EXTRACT_TRUNC_MICROSECOND:
            k_unit = TRUNC_MICROSECOND
        if is_date32:
            var arr32 = child_col.as_primitive[DType.int32]()
            var out32 = date_trunc_date32(arr32, k_unit)
            var col_out = Column.from_primitive[DType.int32](out32)
            col_out.arrow_type = ArrowType.DATE32
            return col_out^
        # TIMESTAMP_* input — output keeps the same unit (kernel
        # value stays in src ticks).
        var arr64 = child_col.as_primitive[DType.int64]()
        var out64 = date_trunc_ts(arr64, src_at, k_unit)
        var col_out_ts = Column.from_primitive[DType.int64](out64)
        col_out_ts.arrow_type = src_at
        return col_out_ts^
    # --- Field extracts (output INT64) ---
    #
    # ★★ INT64, NOT INT32, AND THE CHANGE CLOSED A DIVERGENCE
    # BETWEEN THIS EXECUTOR AND THE ROW ONE. `row_streaming_segment`
    # translates the same EXPR_EXTRACT into `EXPR_EXTRACT_I64` and sizes
    # its output cell in the default INT64 family, so before this line the
    # SAME PLAN answered `year(d)` as INT32 here and INT64 there —
    # decided by whether the projection happened to be row-servable.
    # DuckDB v1.5.3 answers BIGINT (measured over `duckdb_functions` and
    # by evaluation), which is the row path, so this path moved.
    if is_date32:
        var arr32 = child_col.as_primitive[DType.int32]()
        if unit == EXTRACT_YEAR:
            return Column.from_primitive[DType.int64](extract_year_date32(arr32))
        elif unit == EXTRACT_MONTH:
            return Column.from_primitive[DType.int64](extract_month_date32(arr32))
        elif unit == EXTRACT_DAY:
            return Column.from_primitive[DType.int64](extract_day_date32(arr32))
        elif unit == EXTRACT_QUARTER:
            return Column.from_primitive[DType.int64](extract_quarter_date32(arr32))
        elif (
            unit == EXTRACT_HOUR
            or unit == EXTRACT_MINUTE
            or unit == EXTRACT_SECOND
            # `millisecond(DATE ...)` and
            # `microsecond(DATE ...)` are 0 too (measured v1.5.3) — the
            # SAME constant, so they join this arm rather than getting a
            # kernel of their own to disagree with it.
            or unit == EXTRACT_MILLISECOND
            or unit == EXTRACT_MICROSECOND
        ):
            # ★★ ZERO, AND IT USED TO BE A REFUSAL. A DATE32
            # has no sub-day component, and the question is what to ANSWER
            # rather than whether one exists. DuckDB v1.5.3 answers 0 for
            # all three (`hour` = 0 :: BIGINT,
            # measured), so `SELECT hour(order_date)` was a query DuckDB
            # answers and this engine raised on. NULL still propagates —
            # the kernel clones validity, so a NULL date is a NULL hour
            # and not an hour of zero.
            #
            # ⚠ THE ROW EXECUTOR DEMOTES THIS COMBINATION RATHER THAN
            # DUPLICATING IT (`row_streaming_segment._translate_value_node`
            # returns -1 for DATE32 + HOUR/MINUTE/SECOND), so a plan in
            # that shape falls back HERE and gets this same answer. Do not
            # "complete" the row path by adding a second zero-filling site;
            # two implementations of a constant is two chances to disagree.
            return Column.from_primitive[DType.int64](
                extract_subday_zero_date32(arr32)
            )
        elif (
            unit == EXTRACT_DAYOFWEEK
            or unit == EXTRACT_ISODOW
            or unit == EXTRACT_DAYOFYEAR
        ):
            # A DATE32 IS the day
            # count, so all three are defined on it with no widening — and
            # unlike hour/minute/second there is no "no sub-day component"
            # question to answer. MEASURED v1.5.3: `dayofweek(DATE
            # '')` = 0 (a Sunday), `isodow` = 7, `dayofyear` = 74.
            return Column.from_primitive[DType.int64](
                extract_day_index_date32(arr32, unit)
            )
        elif (
            unit == EXTRACT_WEEK
            or unit == EXTRACT_ISOYEAR
            or unit == EXTRACT_YEARWEEK
        ):
            # ⛔ `isoyear` here is
            # NOT the DATE32's civil year: `isoyear(DATE '2021-01-01')` =
            # 2020 (measured v1.5.3), because that Friday is in ISO week 53
            # of 2020. Routing it to `extract_year_date32` would be right on
            # ~362 days a year.
            return Column.from_primitive[DType.int64](
                extract_iso_week_date32(arr32, unit)
            )
        else:
            raise Error(
                "PipelineCompiler: EXPR_EXTRACT — unsupported unit on DATE32: "
                + String(Int(unit))
            )
    # TIMESTAMP_* path
    var arr64 = child_col.as_primitive[DType.int64]()
    if unit == EXTRACT_YEAR:
        return Column.from_primitive[DType.int64](extract_year_ts(arr64, src_at))
    elif unit == EXTRACT_MONTH:
        return Column.from_primitive[DType.int64](extract_month_ts(arr64, src_at))
    elif unit == EXTRACT_DAY:
        return Column.from_primitive[DType.int64](extract_day_ts(arr64, src_at))
    elif unit == EXTRACT_QUARTER:
        return Column.from_primitive[DType.int64](extract_quarter_ts(arr64, src_at))
    elif unit == EXTRACT_HOUR:
        return Column.from_primitive[DType.int64](extract_hour_ts(arr64, src_at))
    elif unit == EXTRACT_MINUTE:
        return Column.from_primitive[DType.int64](extract_minute_ts(arr64, src_at))
    elif unit == EXTRACT_SECOND:
        return Column.from_primitive[DType.int64](extract_second_ts(arr64, src_at))
    elif (
        unit == EXTRACT_DAYOFWEEK
        or unit == EXTRACT_ISODOW
        or unit == EXTRACT_DAYOFYEAR
    ):
        # ⚠ `src_at`, NOT A CONSTANT. The kernel floor-divides the tick
        # count by THIS unit's ticks-per-day to recover the civil day; the
        # four TIMESTAMP_* units share one INT64 storage family, so a
        # hard-coded microsecond assumption answers a day 1000x away over a
        # millisecond column and is green on every fixture written in one
        # unit.
        return Column.from_primitive[DType.int64](
            extract_day_index_ts(arr64, src_at, unit)
        )
    elif (
        unit == EXTRACT_WEEK
        or unit == EXTRACT_ISOYEAR
        or unit == EXTRACT_YEARWEEK
    ):
        return Column.from_primitive[DType.int64](
            extract_iso_week_ts(arr64, src_at, unit)
        )
    elif unit == EXTRACT_MILLISECOND or unit == EXTRACT_MICROSECOND:
        # the seconds are FOLDED IN (30123 / 30123456 for
        # `...:30.123456`, measured). ⛔ This is NOT the fractional part.
        return Column.from_primitive[DType.int64](
            extract_subsecond_ts(arr64, src_at, unit)
        )
    raise Error(
        "PipelineCompiler: EXPR_EXTRACT — unsupported unit on TIMESTAMP_*: "
        + String(Int(unit))
    )
