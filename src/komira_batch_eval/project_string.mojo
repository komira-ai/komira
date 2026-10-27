# =============================================================================
# project_string: projection arms for string predicates and functions
# =============================================================================
#
# The fixed-pattern string operators, regular expressions, `substring` and the
# unary string functions. Each is one arm of `eval_column._eval_column_expr`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import expr_resolves_to_column, resolve_col_index
from komira_column_kernels.digest_functions import md5_hex_bytes, sha1_hex_bytes, sha256_hex_bytes
from komira_column_kernels.regexp_functions import (
    compile_full_match_program,
    eval_regexp_count,
    eval_regexp_extract,
    eval_regexp_extract_all,
    eval_regexp_full_match,
    eval_regexp_instr,
    eval_regexp_like,
    eval_regexp_match,
    eval_regexp_replace,
    eval_regexp_split_to_array,
    eval_regexp_substr,
    regexp_escape_bytes,
    split_g_flag,
)
from komira_column_kernels.regexp_nfa import RegexProgram
from komira_column_kernels.rxcensus import (
    RXC_ARM_CALLS,
    RXC_ARM_DICT,
    RXC_PROG_COMPILES,
    rxcensus_add,
)
from komira_column_kernels.unicode_case import unicode_lower_bytes, unicode_upper_bytes
from komira_plan_expr.expr import (
    Expr,
    REGEXP_COUNT,
    REGEXP_EXTRACT,
    REGEXP_EXTRACT_ALL,
    REGEXP_FULL_MATCH,
    REGEXP_INSTR,
    REGEXP_LIKE,
    REGEXP_MATCH,
    REGEXP_REPLACE,
    REGEXP_SPLIT_TO_ARRAY,
    REGEXP_SUBSTR,
    STRFN_ASCII,
    STRFN_BIN,
    STRFN_BIT_LENGTH,
    STRFN_HEX,
    STRFN_LENGTH,
    STRFN_LOWER,
    STRFN_LTRIM,
    STRFN_MD5,
    STRFN_REGEXP_ESCAPE,
    STRFN_REVERSE,
    STRFN_RTRIM,
    STRFN_SHA1,
    STRFN_SHA256,
    STRFN_STRLEN,
    STRFN_TRIM,
    STRFN_UNICODE,
    STRFN_UPPER,
    STRFN_URL_DECODE,
    STRFN_URL_ENCODE,
    string_fn_returns_int,
)

from .eval_column import _eval_column_expr
from .eval_dict import _materialize_dict_to_string
from .eval_predicate import (_eval_predicate)
from .predicate_logic import (_eval_string_op_on_column)
from .string_bytes import (
    _bin_string_bytes,
    _hex_string_bytes,
    _reverse_codepoints_bytes,
    _sql_substring_bytes,
    _url_decode_bytes,
    _url_encode_bytes,
    string_array_of,
    try_share_string_col_ref,
)
from .string_metrics import _trim_space_bytes, _utf8_char_count, _utf8_first_codepoint


def _project_string_op(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_STRING_OP` arm of `_eval_column_expr`."""
    # ★ `contains` / `starts_with` / `ends_with` / `like` IN PROJECTION
    # CONTEXT.
    #
    # ⚠ THIS IS NOT A THEORETICAL SHAPE. It is reached (a) whenever CSE
    # hoists a duplicated `LIKE` / `starts_with` subtree into a synthetic
    # projection — the same route that made `EXPR_IN_LIST` need this arm
    # in — and (b) by any `SELECT starts_with(s, 'x')`, which
    # the SQL binder can now write.
    #
    # Delegates to the SAME kernel the predicate context uses, so the two
    # cannot disagree about which rows MATCH.
    #
    # ★ A COMPUTED OPERAND (`lower(s) LIKE 'a%'`, SQL `ILIKE`;
    # is materialized ONCE here and both the match bits and the
    # validity below are read off that one column — calling
    # `_eval_predicate` and then re-deriving the validity would evaluate
    # the operand twice.
    if not expr_resolves_to_column(expr.string_op_child_ref()):
        var sop_computed = _eval_column_expr(expr.string_op_child_ref(), batch)
        var sop_cba = _eval_string_op_on_column(
            sop_computed, expr.string_op_type(), expr.string_op_pattern()
        )
        if sop_computed._validity:
            for r in range(batch.num_rows()):
                if not sop_computed._validity.value().test(r):
                    sop_cba._set_null(r)
        return Column.from_boolean(sop_cba^)
    var sop_ba = _eval_predicate(expr, batch)

    # ⛔ BUT THE TWO CONTEXTS DISAGREE ABOUT NULL, AND ONLY ONE OF THEM IS
    # ALLOWED TO. The pattern kernels take `(length, offsets, data)` and
    # never see a validity bitmap, so a NULL row is matched as the EMPTY
    # STRING — which answers FALSE for `starts_with(NULL,'he')` and TRUE
    # for `starts_with(NULL,'')`.
    #
    # In a PREDICATE that is right: under SQL 3VL an UNKNOWN does not
    # select, so false-for-null is the correct row set either way. In a
    # PROJECTION it is a WRONG ANSWER — DuckDB v1.5.3 returns NULL for
    # both (measured: `starts_with('hello',NULL)` and
    # `starts_with(NULL,'he')` are both NULL) — and `starts_with(NULL,'')`
    # is the case where the divergence flips the value rather than merely
    # narrowing it.
    #
    # So the projection arm re-imposes the child's validity. This is not a
    # second kernel and cannot drift from the first: the DATA bits are
    # whatever `_eval_predicate` produced, and only the VALIDITY is added.
    var sop_idx = resolve_col_index(expr.string_op_child_ref(), batch.schema)
    ref sop_col = batch.column_at(sop_idx)
    if sop_col._validity:
        var sop_rows = batch.num_rows()
        for r in range(sop_rows):
            if not sop_col._validity.value().test(r):
                sop_ba._set_null(r)
    return Column.from_boolean(sop_ba^)


def _project_regexp(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_REGEXP` arm of `_eval_column_expr`."""
    # regexp_like (-> Bool column) /
    # regexp_extract (-> Utf8 column) / regexp_match /
    # regexp_split_to_array / regexp_extract_all (-> List<Utf8> column).
    # regexp_replace has its own arm.  The pattern is a plan-literal; we
    # compile the NFA once here per batch (once per plan is a later step —
    # see the breadcrumb in regexp_functions.mojo).  The child resolves
    # to a STRING / DICTIONARY column via `resolve_col_index` (handles
    # both EXPR_COL_REF and EXPR_COL_IDX — same dance as the
    # EXPR_STRING_OP predicate arm).
    var rop = expr.regexp_op()
    var col_idx = resolve_col_index(expr.regexp_child_ref(), batch.schema)
    ref col_ptr = batch.column_at(col_idx)
    var src_at = col_ptr.arrow_type
    # RXCENSUS: per-BATCH, not per-row. What was
    # never written down is HOW MANY batches this arm sees, which is the
    # denominator of both "compile once per plan" and "widen the memo".
    rxcensus_add(RXC_ARM_CALLS, 1)
    if src_at == ArrowType.DICTIONARY:
        rxcensus_add(RXC_ARM_DICT, 1)
    if src_at != ArrowType.STRING and src_at != ArrowType.DICTIONARY:
        raise Error("PipelineCompiler: regexp_* require a STRING or DICTIONARY column, got " + String(src_at))
    var sarr: StringArray[HeapRegion]
    if src_at == ArrowType.DICTIONARY:
        sarr = _materialize_dict_to_string(col_ptr)
    else:
        # Lane G: `as_string`'s values, Arc-shared where it can be.
        sarr = string_array_of(col_ptr)
    # `g` (replace-all) is not a pattern flag — split it out before
    # compiling.  It is only meaningful for regexp_replace; for the other
    # ops it is harmless to strip (and `RegexProgram.compile` would accept
    # it anyway).
    var gsplit = split_g_flag(expr.regexp_flags())
    var pattern_flags = gsplit[0]
    var replace_all = gsplit[1]
    # `regexp_full_match` wraps the user pattern in `\A(?:...)\z` (the RE2
    # `FullMatch` desugaring); every other op compiles the pattern as-is.
    var prog: RegexProgram
    rxcensus_add(RXC_PROG_COMPILES, 1)
    if rop == REGEXP_FULL_MATCH:
        prog = compile_full_match_program(expr.regexp_pattern(), pattern_flags)
    else:
        prog = RegexProgram.compile(expr.regexp_pattern(), pattern_flags)
    if rop == REGEXP_LIKE:
        return Column.from_boolean(eval_regexp_like(sarr, prog))
    elif rop == REGEXP_FULL_MATCH:
        return Column.from_boolean(eval_regexp_full_match(sarr, prog))
    elif rop == REGEXP_EXTRACT:
        # By-name extract: `regexp_extract(s, pattern, group="name")` — the
        # pattern is only compiled here (execution time), so the name→index
        # resolution happens now.  An unknown name is a hard error (matches
        # DuckDB rejecting a bad named-group reference).
        var gname = expr.regexp_group_name()
        if gname.byte_length() > 0:
            var gidx = prog.group_index_for_name(gname)
            if gidx < 0:
                raise Error("PipelineCompiler: regexp_extract: no named capture group '" + gname + "' in pattern \"" + expr.regexp_pattern() + "\"")
            return Column.from_string(eval_regexp_extract(sarr, prog, gidx))
        return Column.from_string(eval_regexp_extract(sarr, prog, expr.regexp_group()))
    elif rop == REGEXP_SUBSTR:
        return Column.from_string(eval_regexp_substr(sarr, prog))
    elif rop == REGEXP_REPLACE:
        return Column.from_string(eval_regexp_replace(sarr, prog, expr.regexp_replacement(), replace_all))
    elif rop == REGEXP_COUNT:
        return Column.from_primitive[DType.int64](eval_regexp_count(sarr, prog))
    elif rop == REGEXP_INSTR:
        return Column.from_primitive[DType.int64](eval_regexp_instr(sarr, prog))
    elif rop == REGEXP_MATCH:
        return Column.from_list(eval_regexp_match(sarr, prog))
    elif rop == REGEXP_SPLIT_TO_ARRAY:
        return Column.from_list(eval_regexp_split_to_array(sarr, prog))
    elif rop == REGEXP_EXTRACT_ALL:
        return Column.from_list(eval_regexp_extract_all(sarr, prog, expr.regexp_group()))
    else:
        raise Error("PipelineCompiler: unsupported regexp op " + String(Int(rop)))


def _project_substring(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_SUBSTRING` arm of `_eval_column_expr`."""
    # Substring: `substring(s, start, length)` over a
    # STRING / DICTIONARY child -> a STRING column. The child is evaluated
    # recursively (so a bare col-ref OR a nested string expr both work), then
    # each row's value is sliced per SQL semantics; NULL input -> NULL output.
    # Lane G L2: a column-reference child is read in place (see the
    # `EXPR_STRING_FN` arm below and `try_share_string_col_ref`).
    var sarr: StringArray[HeapRegion]
    var sub_shared = try_share_string_col_ref(expr.substring_child_ref(), batch)
    if sub_shared:
        sarr = sub_shared.take()
    else:
        var child_col = _eval_column_expr(expr.substring_child_ref(), batch)
        var src_at = child_col.arrow_type
        if src_at != ArrowType.STRING and src_at != ArrowType.DICTIONARY:
            raise Error("PipelineCompiler: substring() requires a STRING or DICTIONARY column, got " + String(src_at))
        if src_at == ArrowType.DICTIONARY:
            sarr = _materialize_dict_to_string(child_col)
        else:
            sarr = string_array_of(child_col)
    var start = expr.substring_start()
    var length = expr.substring_length()
    var n = batch.num_rows()
    # ⚠ `List[List[UInt8]]` + `from_byte_lists`, NOT `List[String]` +
    # `from_strings`. This arm USED the latter and that is one of the
    # three defects `_sql_substring_bytes` fixes: the round trip through
    # `String` re-encodes every byte >= 0x80. See that kernel's docstring.
    var out_bytes = List[List[UInt8]](capacity=n)
    var validity = Bitmap.create_all_valid(n)
    var null_count = 0
    for i in range(n):
        if sarr.is_null(i):
            # A NULL ROW STILL APPENDS A SLOT — the offset buffer is built
            # from this list, so skipping the append shifts every later
            # row. The validity bit is what makes the row null.
            out_bytes.append(List[UInt8]())
            validity.clear(i)
            null_count += 1
            continue
        out_bytes.append(_sql_substring_bytes(sarr.get(i), start, length))
    var out_sa = StringArray.from_byte_lists(out_bytes)
    if null_count > 0:
        out_sa.validity = validity^
        out_sa.null_count = null_count
    return Column.from_string(out_sa^)


def _project_string_fn(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_STRING_FN` arm of `_eval_column_expr`."""
    # the unary scalar string functions over a
    # STRING / DICTIONARY child. The child is evaluated recursively (so a
    # bare col-ref OR a nested string expr both work); NULL in -> NULL out,
    # which is DuckDB's answer for every member of this family.
    #
    # ⭐ A COLUMN-REFERENCE CHILD IS READ IN PLACE. The child
    # used to go through `_eval_column_expr` -> `copy_column` and then
    # `as_string` — two full copies of `url` on cbq27 to feed a kernel
    # that only reads it. `try_share_string_col_ref` returns an Arc share
    # of the batch column exactly where that pair is provably equal to one
    # (its docstring lists the gate); anything else takes the old path.
    var sfn_sa: StringArray[HeapRegion]
    var sfn_shared = try_share_string_col_ref(
        expr.string_fn_child_ref(), batch
    )
    if sfn_shared:
        sfn_sa = sfn_shared.take()
    else:
        var sfn_child = _eval_column_expr(expr.string_fn_child_ref(), batch)
        var sfn_at = sfn_child.arrow_type
        if sfn_at != ArrowType.STRING and sfn_at != ArrowType.DICTIONARY:
            raise Error(
                "PipelineCompiler: string function requires a STRING or"
                + " DICTIONARY column, got " + String(sfn_at)
            )
        if sfn_at == ArrowType.DICTIONARY:
            sfn_sa = _materialize_dict_to_string(sfn_child)
        else:
            sfn_sa = string_array_of(sfn_child)
    var sfn_op = expr.string_fn_op()
    var sfn_n = batch.num_rows()

    # ★ THE INT64-RETURNING MEMBERS LEAVE HERE, BEFORE THE BYTE BUILDER.
    # `string_fn_returns_int` is the single place that answers "what type
    # does this op emit" (`expr.mojo`), and it is read HERE, in
    # `_infer_expr_field`, in `compiler_helpers.field_for_expr` and in
    # `compute_project._is_string_fn_output`. Branching on the OP rather
    # than assuming the family's Utf8 default is what lets `length` ride
    # this tag at all; assuming it would emit a STRING column holding a
    # decimal rendering of the count, which is a wrong ANSWER and a wrong
    # TYPE at once.
    if string_fn_returns_int(sfn_op):
        # ⚠ FIVE MEMBERS, AND THE THREE LENGTH-SHAPED ONES ARE THREE
        # DIFFERENT FUNCTIONS. MEASURED on DuckDB v1.5.3 over `'héllo'`:
        # `length` = 5 (CHARACTERS), `strlen` = 6 (BYTES), `bit_length` =
        # 48 (bytes * 8). All three agree on every ASCII input, so the
        # arms below are only distinguishable by a non-ASCII fixture.
        if (
            sfn_op != STRFN_LENGTH
            and sfn_op != STRFN_ASCII
            and sfn_op != STRFN_UNICODE
            and sfn_op != STRFN_STRLEN
            and sfn_op != STRFN_BIT_LENGTH
        ):
            raise Error(
                "PipelineCompiler: string function op "
                + String(Int(sfn_op))
                + " is declared INT64-returning by string_fn_returns_int"
                + " but has no kernel arm"
            )
        # ⭐ THE VALIDITY DECISION IS MADE ONCE, NOT ONCE PER ROW, AND
        # A NON-NULLABLE INPUT PRODUCES A COLUMN WITH NO BITMAP AT ALL.
        # This is the same contract the `EXPR_SUBSTRING` arm 40 lines
        # above already keeps (`if null_count > 0: out_sa.validity = ...`)
        # — an output carries a validity buffer only when a null actually
        # reached it. The INT64 arm did not, and the cost was FOUR
        # separate whole-column memory passes per chunk for a column that
        # can never hold a null:
        #
        #   1. `allocate_nullable` -> `buf.zero` over 8 * rows bytes
        #      (a dead store: the loop below writes every element), plus
        #      `Bitmap.create_all_valid` over rows/8 bytes;
        #   2. per row, `sfn_sa.is_null(i)` -- an `Optional[Bitmap]` test
        #      and a bitmap read;
        #   3. per row, `PrimitiveArray.set` -> `if self.validity` ->
        #      `is_null(index)` (a SECOND bitmap read) -> `_set_valid`
        #      (a bitmap read-MODIFY-WRITE) -- setting a bit that
        #      `create_all_valid` had already set;
        #   4. `Column.from_primitive`, which MEMCPYS the whole 8 * rows
        #      data buffer and the bitmap into fresh buffers.
        #
        # MEASURED on ClickBench Q27 (`avg(length(url))` over
        # 99,929,734 rows, `sample` profile): `PrimitiveArray::_set_valid` alone carried
        # 2,352 of ~33,000 non-idle samples -- 7.1% of every working
        # CPU-second the query spends -- and `_eval_column_expr` (which
        # inlines the two `is_null`s and the row loop) carried 10,693,
        # the largest working symbol in the profile by 1.6x.
        #
        # ⚠ THE GATE IS THE PRESENCE OF A BITMAP, NOT `null_count == 0`.
        # A stale `null_count` on an input that does carry cleared bits
        # would silently turn SQL NULLs into values; `Bool(validity)` can
        # only ever cost us the fast path, never correctness. Parquet's
        # dense BYTE_ARRAY decode attaches no bitmap at all when
        # `all_pages_all_valid` (`column_decoder.mojo:2107`), which is why
        # this gate fires on a zero-null OPTIONAL column.
        var sfn_in_nullable = Bool(sfn_sa.validity)
        var len_arr: PrimitiveArray[DType.int64]
        if sfn_in_nullable:
            len_arr = PrimitiveArray[DType.int64].allocate_nullable(sfn_n)
        else:
            # Every branch of every op ladder below writes element `i`
            # unconditionally when the input is non-nullable, so the fill
            # is total and `allocate_uninitialized`'s contract holds.
            len_arr = PrimitiveArray[
                DType.int64
            ].allocate_uninitialized(sfn_n)
        var len_nulls = 0
        # ⭐ THE OP DISPATCH IS HOISTED OUT OF THE ROW LOOP, AND NO ARM
        # BUILDS A `String`. Both halves matter and the second is the one
        # that was worth 40% of ClickBench Q27:
        #
        #   * `sfn_sa.get(i)` returns an OWNING `String` — per row, a
        #     `List[UInt8]` heap allocation, a byte-at-a-time
        #     `ByteView.copy_to`, a null terminator, a SECOND heap
        #     allocation + memcpy inside `String(unsafe_from_utf8_ptr=)`,
        #     then two frees. Over 99,929,734 rows of `url` (7.43 GB
        #     uncompressed) that copies the whole column TWICE to read each
        #     byte once.
        #   * `sfn_sa.get_span(i)` is the zero-copy companion
        #     (`string_array.mojo`): a BORROWED `Span[UInt8]` over the
        #     Arrow data buffer, compiler-tracked origin, no allocation.
        #     It is the same move the `regexp_*` kernels and the mixed agg
        #     fold make.
        #
        # Over the 100M-row ClickBench hits fixture, `sum(strlen(url))` minus
        # `count(*) WHERE url <> ''` — the String construction with the
        # arithmetic controlled away, since `strlen` is O(1) once the
        # `String` exists — cost about 1.4 s; DuckDB's same delta is a few
        # ms, because its `string_t` points into the Parquet page it
        # already decompressed and is never copied.
        if sfn_op == STRFN_STRLEN or sfn_op == STRFN_BIT_LENGTH:
            # ⛔ THE BYTE COUNT, NEVER `_utf8_char_count`. The whole point
            # of these two members is that they are BYTES where `length`
            # is CHARACTERS (measured on DuckDB v1.5.3: `strlen('héllo')`
            # = 6, `length('héllo')` = 5, `bit_length('héllo')` = 48).
            # They agree on every ASCII input, so a fixture without a
            # multi-byte codepoint cannot separate the implementations.
            #
            # ⭐ AND THE BYTE COUNT IS `offsets[i+1] - offsets[i]`, so
            # `get_length` answers it WITHOUT TOUCHING THE DATA BUFFER AT
            # ALL — no span, no read, no cache line. This arm is now pure
            # offset arithmetic.
            var bl_scale = Int64(1)
            if sfn_op == STRFN_BIT_LENGTH:
                bl_scale = Int64(8)
            for i in range(sfn_n):
                if sfn_in_nullable and sfn_sa.is_null(i):
                    len_arr.validity.value().clear(i)
                    len_nulls += 1
                else:
                    len_arr.set(
                        i, bl_scale * Int64(sfn_sa.get_length(i))
                    )
        elif sfn_op == STRFN_LENGTH:
            for i in range(sfn_n):
                if sfn_in_nullable and sfn_sa.is_null(i):
                    len_arr.validity.value().clear(i)
                    len_nulls += 1
                else:
                    len_arr.set(
                        i, Int64(_utf8_char_count(sfn_sa.get_span(i)))
                    )
        elif sfn_op == STRFN_ASCII or sfn_op == STRFN_UNICODE:
            # ⚠ THE TWO DISAGREE ON THE EMPTY STRING AND NOWHERE ELSE.
            # MEASURED: `ascii('')` = 0, `unicode('')` = -1. Folding them
            # into one arm is correct precisely because that one value is
            # the entire difference, and it is passed in.
            var cp_empty = 0
            if sfn_op == STRFN_UNICODE:
                cp_empty = -1
            for i in range(sfn_n):
                if sfn_in_nullable and sfn_sa.is_null(i):
                    len_arr.validity.value().clear(i)
                    len_nulls += 1
                else:
                    len_arr.set(
                        i,
                        Int64(
                            _utf8_first_codepoint(
                                sfn_sa.get_span(i), cp_empty
                            )
                        ),
                    )
        else:
            # ⚠ UNREACHABLE — the membership guard above already refused
            # any other op by name. Restated here so the hoisted ladder is
            # exhaustive on its own terms rather than by reading upward.
            raise Error(
                "PipelineCompiler: string function op "
                + String(Int(sfn_op))
                + " is declared INT64-returning by string_fn_returns_int"
                + " but has no kernel arm"
            )
        len_arr.null_count = len_nulls
        # ⭐ `_shared` CONSUMES `len_arr` AND ARC-SHARES ITS BUFFERS; the
        # borrowing `from_primitive` MEMCPYS them. `len_arr` is a fresh
        # local built three lines up and never read again, which is
        # exactly the caller shape `from_primitive_shared` documents. Over
        # cbq27's 99,929,734 rows that copy is 800 MB of pointless DRAM
        # traffic per pass (read + write), on top of the `buf.zero` the
        # `allocate_uninitialized` above already retires.
        return Column.from_primitive_shared[DType.int64](len_arr^)
    # ⚠ `List[List[UInt8]]`, NOT `List[String]`. `StringArray.from_strings`
    # round-trips every value through a `String` and expands any byte
    # >= 0x80 into a multi-byte UTF-8 sequence; `from_byte_lists` is the
    # byte-faithful companion. The SUBSTRING arm above was the standing
    # counter-example when this comment was written — it used
    # `from_strings` and corrupted non-ASCII — and it was converted to
    # this same pairing so both arms agree now.
    var sfn_out = List[List[UInt8]](capacity=sfn_n)
    var sfn_validity = Bitmap.create_all_valid(sfn_n)
    var sfn_nulls = 0
    for i in range(sfn_n):
        if sfn_sa.is_null(i):
            # ⚠ A NULL ROW STILL APPENDS A VALUE. `StringArray.from_strings`
            # builds the offset buffer from this list, so skipping the
            # append would shift every later row's offsets by one and
            # produce a column whose NON-null values are wrong — the
            # validity bit is what makes the row NULL, not the absence of
            # a slot. Same shape as the SUBSTRING arm above.
            sfn_out.append(List[UInt8]())
            sfn_validity.clear(i)
            sfn_nulls += 1
            continue
        if sfn_op == STRFN_UPPER:
            sfn_out.append(unicode_upper_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_LOWER:
            sfn_out.append(unicode_lower_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_TRIM:
            sfn_out.append(
                _trim_space_bytes(sfn_sa.get(i), True, True)
            )
        elif sfn_op == STRFN_LTRIM:
            sfn_out.append(
                _trim_space_bytes(sfn_sa.get(i), True, False)
            )
        elif sfn_op == STRFN_RTRIM:
            sfn_out.append(
                _trim_space_bytes(sfn_sa.get(i), False, True)
            )
        elif sfn_op == STRFN_REVERSE:
            sfn_out.append(_reverse_codepoints_bytes(sfn_sa.get(i)))
        # -- The byte-transform members.
        # ⚠ EXACT against DuckDB v1.5.3 on non-ASCII too, unlike the four
        # case/whitespace members above, because DuckDB defines these on
        # the UTF-8 BYTES as well. See the kernels for the measurements.
        elif sfn_op == STRFN_HEX:
            sfn_out.append(_hex_string_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_BIN:
            sfn_out.append(_bin_string_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_URL_ENCODE:
            sfn_out.append(_url_encode_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_URL_DECODE:
            # ⚠ THE ONLY RAISING KERNEL IN THIS LADDER. DuckDB raises on a
            # decode that yields invalid UTF-8 and so does this; emitting
            # the bytes anyway would put an unexportable value in a STRING
            # column.
            sfn_out.append(_url_decode_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_REGEXP_ESCAPE:
            sfn_out.append(regexp_escape_bytes(sfn_sa.get(i)))
        # -- Digests: LOWERCASE hex over the UTF-8 BYTES.
        # ⛔ LOWERCASE, where `STRFN_HEX` five lines up is UPPERCASE — the
        # two families share this ladder and nothing else. The three
        # widths (32 / 40 / 64 characters) differ, so a mis-dispatch here
        # cannot produce a plausible value of the right shape.
        elif sfn_op == STRFN_MD5:
            sfn_out.append(md5_hex_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_SHA1:
            sfn_out.append(sha1_hex_bytes(sfn_sa.get(i)))
        elif sfn_op == STRFN_SHA256:
            sfn_out.append(sha256_hex_bytes(sfn_sa.get(i)))
        else:
            # ⚠ REFUSED BY NAME, never defaulted to a neighbour. An op
            # that reaches here is one `string_fn_returns_int` classified
            # as Utf8-returning and that has no kernel — a wiring gap, and
            # the only safe answer is to say so.
            raise Error(
                "PipelineCompiler: unsupported string function op "
                + String(Int(sfn_op))
            )
    var sfn_arr = StringArray.from_byte_lists(sfn_out)
    if sfn_nulls > 0:
        sfn_arr.validity = sfn_validity^
        sfn_arr.null_count = sfn_nulls
    return Column.from_string(sfn_arr^)
