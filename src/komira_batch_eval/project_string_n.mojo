# =============================================================================
# project_string_n: projection arms for n-ary string functions and UDF calls
# =============================================================================
#
# The string functions with more than one argument, and the arm that reads a
# UDF call's output column. Each is one arm of `eval_column._eval_column_expr`.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import copy_column
from komira_plan_expr.expr import (
    Expr,
    STRFNN_CONCAT,
    STRFNN_CONCAT_WS,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
    STRFNN_JACCARD,
    STRFNN_JARO,
    STRFNN_JARO_WINKLER,
    STRFNN_LEVENSHTEIN,
    STRFNN_LPAD,
    STRFNN_REPEAT,
    STRFNN_REPLACE,
    STRFNN_RPAD,
    STRFNN_STRPOS,
    STRFNN_TRANSLATE,
    STRING_FN_N_REPEAT_MAX_BYTES,
    string_fn_n_arity,
    string_fn_n_arity_ok,
    string_fn_n_name,
    string_fn_n_returns_float,
    string_fn_n_returns_int,
)
from komira_plan_ir.expr_udf_sites import udf_call_column_key

from .string_bytes import (
    _pad_bytes,
    _repeat_bytes,
    _replace_bytes,
    _sfnn_count_arg,
    _sfnn_string_arg,
    _strpos_chars,
    _translate_chars,
)
from .string_metrics import (
    _damerau_levenshtein_bytes,
    _hamming_bytes,
    _jaccard_bytes,
    _jaro_bytes,
    _jaro_winkler_bytes,
    _levenshtein_bytes,
)


def _project_string_fn_n(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_STRING_FN_N` arm of `_eval_column_expr`."""
    # the MULTI-ARGUMENT string functions.
    # Every argument is an ordinary expression evaluated to a full column,
    # so `concat(upper(a), lit('-'), b)` composes with no special case.
    #
    # ⛔ THE THREE NULL RULES ARE NOT SHARED. `concat` SKIPS nulls and
    # never returns one; `concat_ws` propagates a null SEPARATOR and skips
    # null VALUES; everything else propagates any null. Each is applied in
    # its own block below — do not hoist a common "any arg null -> null"
    # pre-pass over this arm, which is the refactor that would silently
    # make `concat('a',NULL)` NULL instead of `'a'`.
    var sfnn_op = expr.string_fn_n_op()
    var sfnn_nargs = expr.string_fn_n_num_args()
    if not string_fn_n_arity_ok(sfnn_op, sfnn_nargs):
        # ⚠ REFUSED AGAINST `string_fn_n_arity`, THE ONE TABLE, rather
        # than against a count written here. The binder, the SDK surface
        # and the wire decoder all check the same table; this is the
        # backstop that makes a node any of them mis-built LOUD.
        raise Error(
            "PipelineCompiler: "
            + string_fn_n_name(sfnn_op)
            + "() got " + String(sfnn_nargs)
            + " argument(s); string_fn_n_arity says "
            + String(string_fn_n_arity(sfnn_op))
            + " (negative = variadic floor, 0 = unknown op)"
        )
    var sfnn_rows = batch.num_rows()

    # ---- LPAD / RPAD / REPEAT: slot 1 is a COUNT, not a string --------
    #
    # ⚠ THE THREE ARE SPLIT INTO TWO BLOCKS BY ARITY, NOT MERGED BEHIND A
    # `has_pad` FLAG. Merging needs a placeholder `StringArray` for the
    # pad `repeat` does not have, and constructing an empty one is a
    # raising call that exists only to be ignored — a value carried solely
    # so a branch can avoid being written.
    if sfnn_op == STRFNN_REPEAT:
        var rp_subj = _sfnn_string_arg(expr, 0, batch)
        var rp_cnt = _sfnn_count_arg(expr, 1, sfnn_op, batch)
        var rp_out = List[List[UInt8]](capacity=sfnn_rows)
        var rp_validity = Bitmap.create_all_valid(sfnn_rows)
        var rp_nulls = 0
        for i in range(sfnn_rows):
            if rp_subj.is_null(i) or rp_cnt.is_null(i):
                # ⚠ A NULL ROW STILL APPENDS A VALUE — the offset buffer
                # is built from this list, so skipping the append shifts
                # every later row's offsets and corrupts the NON-null
                # values. The validity bit is what makes a row NULL.
                rp_out.append(List[UInt8]())
                rp_validity.clear(i)
                rp_nulls += 1
                continue
            rp_out.append(
                _repeat_bytes(
                    rp_subj.get(i),
                    Int(rp_cnt.get(i)),
                    STRING_FN_N_REPEAT_MAX_BYTES,
                )
            )
        var rp_arr = StringArray.from_byte_lists(rp_out)
        if rp_nulls > 0:
            rp_arr.validity = rp_validity^
            rp_arr.null_count = rp_nulls
        return Column.from_string(rp_arr^)

    if sfnn_op == STRFNN_LPAD or sfnn_op == STRFNN_RPAD:
        var pd_subj = _sfnn_string_arg(expr, 0, batch)
        var pd_cnt = _sfnn_count_arg(expr, 1, sfnn_op, batch)
        var pd_pad = _sfnn_string_arg(expr, 2, batch)
        var pd_out = List[List[UInt8]](capacity=sfnn_rows)
        var pd_validity = Bitmap.create_all_valid(sfnn_rows)
        var pd_nulls = 0
        for i in range(sfnn_rows):
            if (
                pd_subj.is_null(i)
                or pd_cnt.is_null(i)
                or pd_pad.is_null(i)
            ):
                pd_out.append(List[UInt8]())
                pd_validity.clear(i)
                pd_nulls += 1
                continue
            # ⛔ `_pad_bytes` RAISES on an empty pad that is actually
            # NEEDED, which is DuckDB's `Insufficient padding in LPAD.`
            # verbatim. It is a REFUSAL and not a pass-through; see the
            # kernel's four measured corners.
            pd_out.append(
                _pad_bytes(
                    pd_subj.get(i),
                    Int(pd_cnt.get(i)),
                    pd_pad.get(i),
                    sfnn_op == STRFNN_LPAD,
                )
            )
        var pd_arr = StringArray.from_byte_lists(pd_out)
        if pd_nulls > 0:
            pd_arr.validity = pd_validity^
            pd_arr.null_count = pd_nulls
        return Column.from_string(pd_arr^)

    # ---- Everything else: every argument is a STRING -------------------
    var sfnn_args = List[StringArray[HeapRegion]](capacity=sfnn_nargs)
    for ai in range(sfnn_nargs):
        sfnn_args.append(_sfnn_string_arg(expr, ai, batch))

    if string_fn_n_returns_float(sfnn_op):
        # THE FLOAT64-RETURNING MEMBERS LEAVE
        # HERE, the exact shape of the INT64 arm directly below.
        #
        # ⛔ THIS ARM IS FIRST, AND THAT IS DELIBERATE RATHER THAN
        # ARBITRARY: `walk_expr_field` asks `returns_int` first and
        # `returns_float` second, so if the two ever disagreed about an op
        # the SCHEMA and the DATA would pick different types. They cannot —
        # `string_fn_n_type_is_coherent` says no op is named by both, and
        # `test_string_fn_n_float_family.mojo` asserts it over the whole
        # declared range — but putting the arms in the OPPOSITE order here
        # is what makes a violation loud (a declared-vs-actual type
        # mismatch the projection test catches) instead of quiet (both
        # sites happening to agree on int).
        #
        # ⚠ A MEMBER DECLARED FLOAT64 AND GIVEN NO ARM IS REFUSED BY NAME,
        # never dropped into the byte builder — the same rule the INT64 arm
        # states: a wrong TYPE is worse than a failed query.
        if (
            sfnn_op != STRFNN_JARO
            and sfnn_op != STRFNN_JARO_WINKLER
            and sfnn_op != STRFNN_JACCARD
        ):
            raise Error(
                "PipelineCompiler: "
                + string_fn_n_name(sfnn_op)
                + "() is declared FLOAT64-returning by"
                + " string_fn_n_returns_float but has no kernel arm"
            )
        var sim_arr = PrimitiveArray[DType.float64].allocate_nullable(
            sfnn_rows
        )
        var sim_nulls = 0
        for i in range(sfnn_rows):
            if sfnn_args[0].is_null(i) or sfnn_args[1].is_null(i):
                # ⚠ THE NULL ROW IS NOT LENGTH-CHECKED, and that matters
                # for `jaccard` alone — it RAISES on an empty operand, and
                # a row with nothing to compare has no length to be too
                # short. Checking first would turn `jaccard(v, NULL)` into
                # a failed query where DuckDB answers NULL (measured).
                sim_arr.validity.value().clear(i)
                sim_nulls += 1
            elif sfnn_op == STRFNN_JARO:
                sim_arr.set(
                    i,
                    _jaro_bytes(
                        sfnn_args[0].get(i), sfnn_args[1].get(i)
                    ),
                )
            elif sfnn_op == STRFNN_JARO_WINKLER:
                sim_arr.set(
                    i,
                    _jaro_winkler_bytes(
                        sfnn_args[0].get(i), sfnn_args[1].get(i)
                    ),
                )
            else:
                sim_arr.set(
                    i,
                    _jaccard_bytes(
                        sfnn_args[0].get(i), sfnn_args[1].get(i)
                    ),
                )
        # ⚠ `null_count` IS SET UNCONDITIONALLY AND THE VALIDITY BITMAP IS
        # KEPT EVEN AT ZERO NULLS — byte-for-byte the INT64 arm's
        # convention below. A "drop the bitmap when nothing is null"
        # optimisation here would be a SECOND opinion about what an
        # all-valid nullable column looks like, in the one family where two
        # arms build the same shape.
        sim_arr.null_count = sim_nulls
        return Column.from_primitive[DType.float64](sim_arr)

    if string_fn_n_returns_int(sfnn_op):
        # ★ THE INT64-RETURNING MEMBERS LEAVE HERE, BEFORE THE BYTE
        # BUILDER — the `STRFN_LENGTH` shape one family up.
        #
        # ⚠ FOUR MEMBERS NOW, NOT ONE, AND THE BRANCH IS ON
        # `string_fn_n_returns_int` RATHER THAN ON `== STRFNN_STRPOS`.
        # That is the same single-source-of-truth the unary family uses:
        # a member declared INT64-returning and given no arm here must be
        # REFUSED BY NAME rather than fall through into the byte builder,
        # which would hand the caller a Utf8 column where the schema
        # promised an INT64 — a wrong TYPE, not merely a wrong value.
        if (
            sfnn_op != STRFNN_STRPOS
            and sfnn_op != STRFNN_LEVENSHTEIN
            and sfnn_op != STRFNN_DAMERAU_LEVENSHTEIN
            and sfnn_op != STRFNN_HAMMING
        ):
            raise Error(
                "PipelineCompiler: "
                + string_fn_n_name(sfnn_op)
                + "() is declared INT64-returning by"
                + " string_fn_n_returns_int but has no kernel arm"
            )
        var sp_arr = PrimitiveArray[DType.int64].allocate_nullable(
            sfnn_rows
        )
        var sp_nulls = 0
        for i in range(sfnn_rows):
            if sfnn_args[0].is_null(i) or sfnn_args[1].is_null(i):
                # ⚠ A NULL ROW IS NOT LENGTH-CHECKED, and that matters for
                # `hamming` alone: it RAISES on unequal lengths, and a row
                # with nothing to compare has no length to disagree about.
                # Checking first would turn `hamming(v, NULL)` into a
                # failed query where DuckDB answers NULL.
                sp_arr.validity.value().clear(i)
                sp_nulls += 1
            elif sfnn_op == STRFNN_STRPOS:
                sp_arr.set(
                    i,
                    Int64(
                        _strpos_chars(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        )
                    ),
                )
            elif sfnn_op == STRFNN_LEVENSHTEIN:
                sp_arr.set(
                    i,
                    Int64(
                        _levenshtein_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        )
                    ),
                )
            elif sfnn_op == STRFNN_DAMERAU_LEVENSHTEIN:
                sp_arr.set(
                    i,
                    Int64(
                        _damerau_levenshtein_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        )
                    ),
                )
            else:  # STRFNN_HAMMING — the only member that can RAISE
                sp_arr.set(
                    i,
                    Int64(
                        _hamming_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        )
                    ),
                )
        sp_arr.null_count = sp_nulls
        return Column.from_primitive[DType.int64](sp_arr)

    var sfnn_out = List[List[UInt8]](capacity=sfnn_rows)
    var sfnn_validity = Bitmap.create_all_valid(sfnn_rows)
    var sfnn_nulls = 0
    for i in range(sfnn_rows):
        if sfnn_op == STRFNN_CONCAT:
            # ⛔ NO NULL CHECK, AND THAT IS THE SEMANTICS. Measured on
            # DuckDB v1.5.3: `concat('a',NULL,'c')` = 'ac' and
            # `concat(NULL,NULL)` = '' — the EMPTY STRING, not NULL. A
            # null argument contributes nothing and the row stays valid.
            var cc = List[UInt8]()
            for ai in range(sfnn_nargs):
                if sfnn_args[ai].is_null(i):
                    continue
                var piece = sfnn_args[ai].get(i).as_bytes()
                for j in range(len(piece)):
                    cc.append(piece[j])
            sfnn_out.append(cc^)
            continue

        if sfnn_op == STRFNN_CONCAT_WS:
            # TWO rules in one function: a NULL SEPARATOR nulls the row,
            # a NULL VALUE is skipped ALONG WITH ITS SEPARATOR — measured
            # `concat_ws('-','a',NULL,'c')` = 'a-c' (ONE dash).
            if sfnn_args[0].is_null(i):
                sfnn_out.append(List[UInt8]())
                sfnn_validity.clear(i)
                sfnn_nulls += 1
                continue
            var sep = sfnn_args[0].get(i).as_bytes()
            var cw = List[UInt8]()
            var wrote = False
            for ai in range(1, sfnn_nargs):
                if sfnn_args[ai].is_null(i):
                    continue
                if wrote:
                    for j in range(len(sep)):
                        cw.append(sep[j])
                var piece2 = sfnn_args[ai].get(i).as_bytes()
                for j in range(len(piece2)):
                    cw.append(piece2[j])
                wrote = True
            sfnn_out.append(cw^)
            continue

        # REPLACE — and every future member whose rule is "any null in,
        # null out". The check is written here rather than hoisted so the
        # two blocks above keep their own, different, rules.
        var any_null = False
        for ai in range(sfnn_nargs):
            if sfnn_args[ai].is_null(i):
                any_null = True
                break
        if any_null:
            sfnn_out.append(List[UInt8]())
            sfnn_validity.clear(i)
            sfnn_nulls += 1
            continue
        if sfnn_op == STRFNN_REPLACE:
            sfnn_out.append(
                _replace_bytes(
                    sfnn_args[0].get(i),
                    sfnn_args[1].get(i),
                    sfnn_args[2].get(i),
                )
            )
        elif sfnn_op == STRFNN_TRANSLATE:
            # ⛔ CHARACTER-based, unlike `replace` one line up, which is
            # byte-based. Both are 3-ary and both take the null rule
            # above; they agree on nothing else.
            sfnn_out.append(
                _translate_chars(
                    sfnn_args[0].get(i),
                    sfnn_args[1].get(i),
                    sfnn_args[2].get(i),
                )
            )
        else:
            # ⚠ REFUSED BY NAME, never defaulted onto a neighbour. An op
            # reaching here is one `string_fn_n_returns_int` classified as
            # Utf8-returning that has no kernel — a wiring gap, and saying
            # so is the only safe answer.
            raise Error(
                "PipelineCompiler: unsupported multi-argument string"
                + " function op " + String(Int(sfnn_op))
                + " (" + string_fn_n_name(sfnn_op) + ")"
            )
    var sfnn_arr = StringArray.from_byte_lists(sfnn_out)
    if sfnn_nulls > 0:
        sfnn_arr.validity = sfnn_validity^
        sfnn_arr.null_count = sfnn_nulls
    return Column.from_string(sfnn_arr^)


def _project_udf_call(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_UDF_CALL` arm of `_eval_column_expr`."""
    # READ the UDF's output, which the SDK has
    # already materialized onto this batch. This arm calls no thunk and
    # touches no registry.
    #
    # ★ WHY THE EVALUATOR DOES NOT RUN THE UDF ITSELF. The thunk lives in
    # `UdfRegistry` (`komira_engine_operators`), and that package DEPENDS
    # on this one — so reaching it from here is a package CYCLE, measured
    # off the build graph. The SDK, which can see both, runs every
    # UDF call in the tree and appends its output under a name BOTH sides
    # derive from `udf_call_column_key`. Neither side spells the name.
    #
    # ⛔ A MISSING COLUMN IS A REFUSAL, NEVER A FALLBACK. If the producer
    # missed this node the lookup fails here and says so. That is the whole
    # reason the producer is allowed to be a hand-written walk: its
    # incompleteness surfaces as a loud error, not a wrong value. Do NOT
    # "fix" this arm by evaluating the child and passing it through — the
    # UDF would silently become the identity function.
    var udf_key = udf_call_column_key(expr)
    var udf_found = -1
    for ui in range(batch.schema.num_columns()):
        if batch.schema.field_name(ui) == udf_key:
            udf_found = ui
            break
    if udf_found < 0:
        raise Error(
            "PipelineCompiler: the UDF `"
            + expr.udf_call_name()
            + "` was not materialized onto this batch. ⛔ This means the"
            + " plan reached an evaluator through a route that does not"
            + " run the SDK's UDF pre-pass"
            + " (`udf_expr_execution.materialize_udf_columns`) — NOT that"
            + " the UDF is wrong. Every route that can carry an"
            + " EXPR_UDF_CALL must run it first"
        )
    return copy_column(batch, udf_found)
