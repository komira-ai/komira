# =============================================================================
# test_plan_wire_hostile_values.mojo — ★ THE VALUE GATE, HELD TO A LEDGER.
# =============================================================================
#
# THE INPUTS ARE FOREIGN AND THEY WERE PRODUCED THE ONLY WAY THAT WORKS: a
# human edited a `.txtpb` and `protoc` encoded it. Every fixture this file
# reads is structurally perfect, is inside every budget `plan_wire_admit.mojo`
# enforces (under 300 bytes, three levels deep, `format_version: 4`), and all
# but two of them say something about a VALUE that their own schema
# contradicts. The two exceptions are CONTROLS, and the corpus is worthless
# without them — see `sort_over_scan_valid` (a plan this build once REFUSED,
# for a reason that had nothing to do with values) and
# `schema_duplicate_column_names` (a defect this build still admits, written
# down rather than fixed).
#
# ⚠ THAT METHOD IS NOT A STYLE CHOICE. A hand-built Mojo `LogicalPlan` CANNOT
# EXPRESS THESE STATES — there is no way to construct one that says
# `col_idx: 999999999` against a three-column schema and then serialise it,
# because the encoder is only ever handed plans this process built. A test
# that only reads bytes this package wrote cannot see the two defects the
# value gate exists for:
#
#   ★ 261 BYTES -> SIGSEGV.        `col_idx: 999999999` in a filter predicate.
#   ★ 273 BYTES -> WRONG ROWS.     an unresolvable column NAME makes the filter
#                                  be DROPPED — six rows out of a six-row
#                                  fixture where four are correct, with no
#                                  error and no warning.
#
# =============================== THE LEDGER ==================================
#
# `_corpus()` records, per fixture, the outcome this build produces. Both
# directions are red:
#
#   a fixture recorded REFUSED that is now ADMITTED   -> RED. The gate regressed
#   a fixture recorded ADMITTED that now REFUSES      -> RED. ★ RED ON GOOD
#                                                       NEWS — change the row to
#                                                       REFUSED and say which
#                                                       gate closed it
#   a fixture that refuses with a DIFFERENT token     -> RED. A refusal that
#                                                       moves has changed what a
#                                                       frontend must do about it
#
# ⚠ THE THIRD RULE IS WHY THE LEDGER NAMES A TOKEN AND NOT JUST "IT RAISED".
# Asserting only that something was refused is satisfied by a gate that maps
# every hostile input to one undifferentiated error, which is precisely the gate
# a frontend in another language cannot use. `PLAN_WIRE_UNRESOLVED_COLUMN` tells
# an author their column list is wrong; `PLAN_WIRE_NEGATIVE_COUNT` tells them
# their serialiser is. Different actions.
#
# ============ ⚠ WHAT A GREEN RUN HERE DOES **NOT** PROVE =====================
#
#   * NOT that the refusal happens before EXECUTION. This file only decodes.
#     A door that refused and then ran the plan anyway would be green here —
#     `komira_plan_endpoint`'s hostile-values test is the leg that closes
#     that, by driving the same bytes through `execute_plan_bytes` and
#     asserting on the endpoint CODE.
#   * NOT that the corpus is complete. The value space is larger than this
#     corpus. What it does prove is that each fixture in it has a NAME, and
#     that a regression in any of them is loud.
#   * NOT that every ADMITTED row is safe. An ADMITTED row is a MEASUREMENT of
#     something this build does not refuse, written down so it is visible. Read
#     the reason on the row.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_wire import (
    plan_from_bytes,
    PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
    PLAN_WIRE_UNRESOLVED_COLUMN,
    PLAN_WIRE_UNSUPPORTED_COL_IDX,
    PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
    PLAN_WIRE_INCONSISTENT_COUNT,
    PLAN_WIRE_NEGATIVE_COUNT,
    PLAN_WIRE_EMPTY_SORT_KEYS,
    PLAN_WIRE_UNCHECKED_VALUE_SITE,
    PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
    PLAN_WIRE_MALFORMED,
    binding_to_bytes,
    scan_params_from_bytes,
)
from komira_arrow.schema import Schema, SchemaBuilder
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SOURCE_VARIANT_BINDING


comptime _FIXTURE_DIR: String = "src/komira_plan_wire/tests/fixtures/hostile/"

# The two sentinel outcomes. Spelled as tokens so a row reads the same way
# whether it names a `PLAN_WIRE_*` refusal or one of these.
comptime _ADMITTED: String = "<ADMITTED>"
"""★ THIS BUILD DECODES THESE BYTES WITHOUT COMPLAINT. Not "allowed" — OBSERVED.
A row carrying it must also carry a reason."""

comptime _REFUSED_UNTOKENED: String = "<REFUSED-UNTOKENED>"
"""Refused, by an `Error` that carries no `PLAN_WIRE_` token — so a caller gets
a named refusal but the DOOR can only classify it by phase, as
`PLAN_ENDPOINT_MALFORMED`. Correct behaviour, coarser code."""


@fieldwise_init
struct _Case(Copyable, Movable, ImplicitlyCopyable):
    var fixture: String
    var expect: String
    var why: String


def _corpus() raises -> List[_Case]:
    """★ THE LEDGER. One row per fixture in `tests/fixtures/hostile/`.

    ⚠ THE COUNT ASSERTED BELOW IS A FLOOR (`len(corpus) >= N`), NOT A
    COMPARISON WITH THE DIRECTORY. A fixture added with no row here would be
    decoded by nothing and this test would stay green. A Mojo test cannot
    close that: it can OPEN a fixture it was told about and cannot ENUMERATE
    the data it was given. Every fixture must therefore be named here AND in
    `komira_plan_endpoint`'s hostile-values test, so that both what the codec
    and what the front DOOR does with it are measured.

    The floor stays as a cheap signal that the ledger has not collapsed."""
    var c = List[_Case]()

    # ---- the two defects the value gate exists for, and the negative sibling
    c.append(_Case(
        String("filter_colidx_out_of_range"),
        PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
        String(
            "★ 261 bytes, SIGSEGV before the value gate. `col_idx: 999999999`"
            " reached `RecordBatch.column_at`, whose body is an unchecked"
            " `self._columns[index]`"
        ),
    ))
    c.append(_Case(
        String("filter_colidx_negative"),
        PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
        String(
            "the same subscript, the other side of zero — a negative index"
            " reads BEFORE the allocation, which is the harder crash to"
            " attribute and the easier one to turn into a read of unrelated"
            " memory"
        ),
    ))
    c.append(_Case(
        String("filter_colidx_in_range"),
        PLAN_WIRE_UNSUPPORTED_COL_IDX,
        String(
            "★★ 257 bytes, SIGSEGV, and the index is IN RANGE. `col_idx: 1`"
            " against the door's own three-column schema — a plan that MEANS"
            " `qty > 25` and is correct in every particular. It went straight"
            " through the bound the two rows above bought, because THE BOUND"
            " WAS NECESSARY AND NOT SUFFICIENT: this engine does not execute"
            " positional references at any index. ⚠ IT IS A DIFFERENT TOKEN"
            " FROM THE TWO ABOVE ON PURPOSE — out-of-range says the producer's"
            " column resolution is wrong, this says the reference is RIGHT and"
            " must be sent as a name. Different fixes, different codes"
        ),
    ))
    c.append(_Case(
        String("filter_colref_unknown_name"),
        PLAN_WIRE_UNRESOLVED_COLUMN,
        String(
            "★ 273 bytes, WRONG ROWS before the value gate. The filter was"
            " DROPPED and all six rows of a six-row fixture came back where"
            " four are correct — the failure a frontend cannot detect"
        ),
    ))

    # ---- the same two defects one node over, and a DIFFERENT gate catches --
    #
    # ★ NOT THE OBVIOUS TOKEN. On a PROJECT the refusal comes from
    # `_check_output_schema` — which runs INSIDE `_plan_from_wire`, before the
    # value gate — because a project's output schema is DERIVED from its
    # expressions, and `_infer_expr_field` answers an unresolvable reference
    # with a placeholder Field ("Column not found -- return a placeholder").
    # The placeholder does not match the schema the message states, so the
    # divergence check fires first.
    #
    # ⚠ THAT IS DEFENCE IN DEPTH, NOT REDUNDANCY, AND THE DIFFERENCE MATTERS:
    # the divergence check only fires because the producer stated a schema that
    # disagrees. A producer that states the PLACEHOLDER schema — which it can,
    # it is a function of the plan — passes the divergence check, and then the
    # value gate is the only thing left. The FILTER rows above are the proof
    # that the value gate itself fires, because a filter's output schema is its
    # child's and no divergence is possible there.
    c.append(_Case(
        String("project_colidx_out_of_range"),
        PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
        String(
            "an index defect is a property of the EXPRESSION, not of the"
            " FILTER — but on a PROJECT the derived-schema check gets there"
            " first. Both are refusals; this row records WHICH, because a"
            " frontend branches on it"
        ),
    ))
    c.append(_Case(
        String("project_colref_unknown_name"),
        PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
        String("the name defect on a PROJECT — same earlier gate, same reason"),
    ))

    # ---- names that are NOT inside an expression ----------------------------
    c.append(_Case(
        String("sort_key_unknown_name"),
        PLAN_WIRE_UNRESOLVED_COLUMN,
        String(
            "a sort key is a bare `String` on the node, not an `Expr` — so an"
            " expression walk alone never sees it"
        ),
    ))
    c.append(_Case(
        String("distinct_column_unknown_name"),
        PLAN_WIRE_UNRESOLVED_COLUMN,
        String("the same shape on DISTINCT's column list"),
    ))
    c.append(_Case(
        String("scan_projection_unknown_name"),
        PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
        String(
            "the scan is the one node whose own schema IS the schema in scope,"
            " and its output schema is DERIVED from its projection — so, like"
            " the two PROJECT rows, the divergence check reaches it before the"
            " value gate. Recorded as observed"
        ),
    ))

    # ---- counts -------------------------------------------------------------
    c.append(_Case(
        String("sort_descending_count_mismatch"),
        PLAN_WIRE_INCONSISTENT_COUNT,
        String(
            "one key, three `descending` flags. `SortData` documents them as"
            " the same arity and enforces nothing"
        ),
    ))
    c.append(_Case(
        String("partition_topn_descending_short"),
        PLAN_WIRE_INCONSISTENT_COUNT,
        String(
            "★★ 246 bytes, SIGSEGV. One sort key and ZERO `descending` flags —"
            " and proto3 omits an empty repeated field entirely, so this is the"
            " CHEAPEST message in the corpus to produce by accident. The"
            " PartitionTopN kernel reads `descending[0]` guarded only by"
            " `len(sort_keys) == 1`. ⚠ THE ENGINE'S PLAN VALIDATOR STATES THIS"
            " INVARIANT — it never fires, because it only runs on plans this"
            " process built. A validator that knows an invariant the untrusted"
            " door does not is a class, not a one-off"
        ),
    ))
    c.append(_Case(
        String("partition_by_descending_short"),
        PLAN_WIRE_INCONSISTENT_COUNT,
        String(
            "the twin, on PartitionBy's `order_keys` (stated by the plan"
            " validator, and read unchecked by the partition-scan kernel)."
            " ⚠ Unchecked, this one does not crash — an unrelated"
            " window-envelope check refuses it first, as EXECUTION_FAILED(20),"
            " whose message tells the author their bytes were VALID. So the"
            " defect here is not a crash but a MISDIRECTION, and one envelope"
            " widening away from being its twin"
        ),
    ))
    c.append(_Case(
        String("union_output_schema_diverges"),
        PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
        String(
            "★ 244 bytes. A UNION over one scan of `[id, qty, name]`"
            " declaring `[id, qty, name, bonus]`. UNION is the one node whose"
            " factory TAKES its output schema instead of deriving it, so"
            " `_check_output_schema` compares the wire's schema with itself —"
            " a tautology; `_check_union_branches` is what refuses it."
            " ⚠ Without that, the engine refuses it for an UNRELATED envelope"
            " reason and tells the caller `the bytes were valid — do not"
            " report this to the plan's author`, which is exactly backwards:"
            " the plan promises a column no branch produces"
        ),
    ))
    c.append(_Case(
        String("limit_negative_n"),
        PLAN_WIRE_NEGATIVE_COUNT,
        String(
            "`LimitData.n` is documented \"Always >= 0\" — a stated invariant"
            " with nothing enforcing it, on a field an adversary sets directly"
        ),
    ))
    c.append(_Case(
        String("topn_negative_n"),
        PLAN_WIRE_NEGATIVE_COUNT,
        String("the same, on TopN's heap size"),
    ))
    c.append(_Case(
        String("scan_negative_row_count"),
        PLAN_WIRE_NEGATIVE_COUNT,
        String(
            "a row count feeds the cardinality estimator and therefore the plan"
            " the optimizer picks"
        ),
    ))
    c.append(_Case(
        String("scan_cloud_path_claims_local_fs"),
        PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
        String(
            "★ A scan whose path is `s3://example-bucket/...` and whose"
            " `fs_is_local` says TRUE. A decoder that checked only the"
            " boolean would admit it, and the boolean is the field a producer"
            " sets from nothing: a producer that assigns `fs_is_local = True`"
            " from the path alone, with no scheme check, emits exactly this"
            " for a cloud path — it is not a hand-forged shape. ⚠ AND IT IS"
            " NOT A DECODE ERROR DOWNSTREAM EITHER: the engine gets a"
            " structurally perfect LOCAL scan of an object-store URI, so a"
            " receiver that happens to hold a local file of that literal name"
            " returns WRONG ROWS rather than failing. The encoder-side twin"
            " cannot cover this — a producer in another language writes the"
            " protobuf directly and never enters `_parquet_to_wire`"
        ),
    ))

    # ---- ★★ lists that AGREE and are EMPTY -----------------------------------
    #
    # The count checks above compare two lengths. These three make both lengths
    # ZERO, which every one of them passes trivially and every name check passes
    # vacuously — so they are the class a gate assembled from "these must agree"
    # cannot see, and they have to be named rather than derived. proto3 omits an
    # empty repeated field entirely, so a producer that forgot to populate
    # `keys` sends exactly these bytes and pays nothing for it.
    #
    # ⚠ THESE ROWS RECORD WHAT THIS BUILD DOES, and ONE of them says ADMITTED.
    # An ADMITTED row is an OBSERVATION written down so it is visible, not a
    # judgement that the state is fine — read the reason on the row, and see
    # `test_a_key_list_that_is_empty_rather_than_short` in the endpoint gate for
    # what the front DOOR then does with it.
    #
    # ★ A ROW HERE CAN ONLY SAY THE BYTES DECODED; IT CANNOT SAY WHAT DECODING
    # THEM COSTS. An admitted empty sort-key list reaches the sort kernel,
    # indexes the empty key list at 0 and ABORTS the process (`index 0 is out
    # of bounds, valid range is 0 to -1`) — which is the argument for keeping a
    # decode ledger and an execution ledger as two files.
    c.append(_Case(
        String("sort_zero_keys"),
        PLAN_WIRE_EMPTY_SORT_KEYS,
        String(
            "a SORT with NO keys — `SortData` carries three empty lists that"
            " AGREE with each other, so `_check_parallel` compares 0 with 0 and"
            " `_check_keys` iterates nothing. ⚠ That is why it needed a token of"
            " its own rather than a wider count rule: this is the class every"
            " count check passes BY CONSTRUCTION. No Mojo caller builds"
            " one; `LogicalPlan.sort` is always given the keys it is sorting by,"
            " so the first producer to reach it is one that is not this process"
        ),
    ))
    c.append(_Case(
        String("topn_zero_keys"),
        PLAN_WIRE_EMPTY_SORT_KEYS,
        String("the same shape on TOP N, where `n` is meaningful and the keys"
               " that would order it are absent. ⚠ SAME TOKEN, DIFFERENT NODE,"
               " and both rows are here because the two crash sites are in"
               " different functions — `_execute_topn_sink` carries two of them"
               " — so a fix to one arm leaves the other message live"),
    ))
    c.append(_Case(
        String("distinct_has_columns_but_none"),
        _ADMITTED,
        String(
            "`has_columns: true` over an EMPTY `columns` list — the one place"
            " in this node where proto3's absent/empty collapse is DELIBERATELY"
            " separated by a presence bit, set to the state it exists to"
            " express and then left empty"
        ),
    ))

    # ---- ★★ THE PACKED CONTROL — the one fixture that MUST be admitted -----
    c.append(_Case(
        String("sort_over_scan_valid"),
        _ADMITTED,
        String(
            "★★ `Sort(qty DESC) over Scan(parquet)` — a CORRECT plan. protoc"
            " PACKS `repeated bool` (the proto3 default), `WireSortNode`"
            " carries two of them, and a decoder that accepted only the"
            " unpacked form would answer"
            " `ProtobufError.WIRE_MISMATCH: expected VARINT`. Five of sixteen"
            " plan node types (Sort, TopN, PartitionBy, PartitionTopN,"
            " AsofJoin) could then not be sent by ANY standard protobuf producer."
            " ⚠ IF THIS ROW EVER READS ANYTHING BUT `<ADMITTED>`, packed"
            " repeated decoding has regressed and the format has stopped being"
            " language-agnostic for every node that carries a repeated scalar."
            " The bytes are protoc's and their `descending` field is wire type"
            " 2 — verifiable with `protoc --decode_raw`"
        ),
    ))

    # ---- ★★ THE PACKED CONTROL'S MISSING HALF ------------------------------
    c.append(_Case(
        String("schema_struct_column_packed"),
        _ADMITTED,
        String(
            "★★ THE PACKED CONTROL'S OTHER HALF, and the one that matters:"
            " `WireField` carries THREE packable repeated fields"
            " (`union_type_ids` int64, `child_type_ids` uint32,"
            " `child_nullables` bool) and a `WireField` is in EVERY schema in"
            " EVERY plan — so without packed decoding any plan whose schema"
            " has a STRUCT, MAP, LIST or UNION column is unreadable from a"
            " standard producer, regardless of its node types."
            " `sort_over_scan_valid` covers only"
            " `WireSortNode`'s two `repeated bool`. This one carries a STRUCT"
            " column with two children and two union type ids, and protoc"
            " PACKED all three: `--decode_raw` renders them"
            " `9: \"\\007\\t\"`, `14: \"\\r\\004\"`, `15:"
            " \"\\001\\000\"` — wire type 2, not varint. ⚠ IF THIS ROW"
            " EVER READS ANYTHING BUT `<ADMITTED>`, packed decoding of"
            " `WireField` has regressed and the format is not"
            " language-agnostic for any plan with a nested column"
        ),
    ))

    # ---- the control: an enum the vocabulary already closes ---------------
    c.append(_Case(
        String("filter_binary_op_undeclared_enum"),
        _REFUSED_UNTOKENED,
        String(
            "★ A CONTROL, AND IT IS IN THE CORPUS BECAUSE IT PASSES."
            " `binary_op_from_wire` tests MEMBERSHIP and raises on `op: 9999`,"
            " so the ENUM leg is closed without the value gate. Its"
            " message carries no `PLAN_WIRE_` token, so the door can only reach"
            " it as MALFORMED — a naming gap, not a hole, and this row is what"
            " keeps it from becoming one"
        ),
    ))

    # ---- observed ADMITTED, and written down for that reason ---------------
    c.append(_Case(
        String("schema_duplicate_column_names"),
        _ADMITTED,
        String(
            "★ NOT CLOSED. Two columns named `qty`, so every by-name reference"
            " resolves to the FIRST and the second is unreachable."
            " `Schema.column_index` returns the first match and this build"
            " admits it. ⚠ REFUSING IT IS NOT OBVIOUSLY RIGHT: `SELECT qty, qty"
            " FROM t` is legal SQL and produces exactly this output schema, so"
            " a refusal at schema-construction time would reject queries that"
            " run correctly today. The defensible check is at RESOLUTION time"
            " — refuse a NAME that matches more than one column — and it is not"
            " implemented here. Recorded rather than fixed, deliberately"
        ),
    ))

    return c^


# =============================================================================
# hex fixtures — the same reader the two sibling corpora use
# =============================================================================


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error(
        "hostile fixture: a `.hex` file holds a non-hex character (byte "
        + String(Int(c)) + ")."
    )


def _from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" ")) or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r")) or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error("hostile fixture: ODD number of hex digits.")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> List[UInt8]:
    """Read a declared test-data fixture by its repository path; same shape
    as the golden corpus's reader."""
    var path = _FIXTURE_DIR + name + ".hex"
    var text = String("")
    var found = False
    try:
        with open(path, "r") as f:
            text = f.read()
        found = True
    except:
        pass
    if not found:
        raise Error(
            "hostile fixture `" + path + "` is MISSING. It must be declared as"
            " test data for this test. The bytes are protoc's encoding of a"
            " hand-authored text message — the encoder cannot produce them, so"
            " they cannot be regenerated from this package."
        )
    var bytes = _from_hex(text)
    if len(bytes) < 16:
        raise Error(
            "hostile fixture `" + path + "` is " + String(len(bytes))
            + " bytes — a stub or a truncated regold. A gate cannot be held to"
            " a fixture that carries no plan."
        )
    return bytes^


# =============================================================================
# The probe
# =============================================================================


def _outcome(name: String) raises -> String:
    """Decode one fixture and return the token it refused with, or one of the
    two sentinels.

    ⚠ THE TOKEN IS TAKEN FROM THE START OF THE MESSAGE, not searched for
    anywhere in it. Every refusal in this format BEGINS with its token — that
    is the contract `plan_endpoint_code_for_wire_token` relies on to classify a
    failure it did not raise — so a `find()` here would pass on a message that
    merely MENTIONED the token in prose and would quietly stop testing the
    contract that matters."""
    var bytes = _read_fixture(name)
    try:
        var _p = plan_from_bytes(bytes^)
    except e:
        var msg = String(e)
        if msg.startswith(PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE):
            return PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE
        if msg.startswith(PLAN_WIRE_UNRESOLVED_COLUMN):
            return PLAN_WIRE_UNRESOLVED_COLUMN
        if msg.startswith(PLAN_WIRE_UNSUPPORTED_COL_IDX):
            return PLAN_WIRE_UNSUPPORTED_COL_IDX
        if msg.startswith(PLAN_WIRE_INCONSISTENT_COUNT):
            return PLAN_WIRE_INCONSISTENT_COUNT
        if msg.startswith(PLAN_WIRE_NEGATIVE_COUNT):
            return PLAN_WIRE_NEGATIVE_COUNT
        if msg.startswith(PLAN_WIRE_UNCHECKED_VALUE_SITE):
            return PLAN_WIRE_UNCHECKED_VALUE_SITE
        if msg.startswith("PLAN_WIRE_"):
            # A `PLAN_WIRE_` refusal this file does not name. Returned VERBATIM
            # up to the first `:` so the ledger diff says which one, instead of
            # collapsing to "some other token".
            var colon = msg.find(":")
            if colon > 0:
                return String(msg[byte=0:colon])
            return msg^
        # ⚠ THE MESSAGE IS PRINTED, NOT SWALLOWED. An untokened refusal is
        # still a refusal, but the DOOR can only classify it by phase — as
        # `PLAN_ENDPOINT_MALFORMED`, i.e. "your producer is broken" — so a
        # reader of this table needs to see what the caller would actually be
        # told. Truncated to one line because some of these are paragraphs.
        var nl = msg.find("\n")
        var head = msg^ if nl < 0 else String(msg[byte=0:nl])
        if head.byte_length() > 160:
            # 1.0.0 refuses `head = String(head[...])`: `head` is borrowed
            # immutably to build the slice while being the construction target
            # of the same call. Construct into an owned temporary first, then
            # move it into place.
            var _head_cut = String(head[byte=0:160]) + "..."
            head = _head_cut^
        print("        (untokened: " + head + ")")
        return _REFUSED_UNTOKENED
    return _ADMITTED


def test_every_hostile_fixture_lands_where_the_ledger_says() raises:
    """★ THE ASSERTION. Every fixture, one line of output, then the ledger.

    The table is printed on PASS as well as fail, deliberately: the value of
    this file to somebody extending the corpus is the table, and a table you
    only get from a red test is a table nobody reads."""
    var corpus = _corpus()
    var refused = 0
    var admitted = 0
    var drift = String("")
    var drifted = 0

    # ⚠ EVERY ROW IS MEASURED BEFORE ANYTHING IS ASSERTED. A loop that
    # `assert`ed inside would stop at the first disagreement and report ONE
    # row per run — which turns "what does this build do to the corpus?" into
    # a question that costs one test run per fixture to answer.
    # The drift is accumulated and raised once, with the whole table above it.
    print("HOSTILE-VALUE CENSUS  (fixture -> outcome)")
    for i in range(len(corpus)):
        ref c = corpus[i]
        var got = _outcome(c.fixture)
        var mark = String("    ")
        if got != c.expect:
            mark = String("  ! ")
            drifted += 1
            drift += (
                "\n  ! " + c.fixture + "\n      recorded: " + c.expect
                + "\n      measured: " + got
                + "\n      the row says: " + c.why
            )
        print(mark + c.fixture + "  ->  " + got)
        if got == _ADMITTED:
            admitted += 1
        else:
            refused += 1

    print(
        "HOSTILE-VALUE CENSUS  " + String(refused) + " refused, "
        + String(admitted) + " admitted, " + String(len(corpus)) + " total"
    )

    assert_equal(
        drifted,
        0,
        "★ THE LEDGER MOVED on " + String(drifted) + " of "
        + String(len(corpus)) + " fixture(s):" + drift
        + "\n ⚠ If a measurement is the IMPROVEMENT — a fixture that used to be"
        " admitted now refuses — change the row and name the gate that closed"
        " it. If it is a regression, the gate is what to fix, never the row.",
    )

    # A corpus that shrank to nothing would make every assertion above
    # vacuously true.
    assert_true(
        len(corpus) >= 23,
        "the ledger has shrunk below the 23 fixtures this corpus holds."
        " A row is deleted only when its FIXTURE is, and a fixture is deleted"
        " only when the state it expresses has become unrepresentable.",
    )


def test_the_two_defects_that_produced_this_corpus_are_named_by_their_tokens(
) raises:
    """★ THE TWO, PINNED SEPARATELY FROM THE LEDGER.

    ⚠ WHY THIS IS NOT REDUNDANT WITH THE CENSUS. The census compares against a
    table, and a table is editable — the same edit that records an improvement
    can record a regression as if it were the new normal. These two rows are the
    reason the value gate exists, so they are asserted against LITERAL tokens
    in the test body, where changing them is a change to the test rather than to
    a data row."""
    assert_equal(
        _outcome(String("filter_colidx_out_of_range")),
        PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
        "★ 261 bytes of protoc-encoded text END THIS PROCESS unchecked. If this"
        " is `<ADMITTED>` the value gate is gone and the SIGSEGV is back; if it"
        " is a different token, the refusal moved and a frontend branching on"
        " the old code no longer sees it.",
    )
    assert_equal(
        _outcome(String("filter_colref_unknown_name")),
        PLAN_WIRE_UNRESOLVED_COLUMN,
        "★ 273 bytes return SIX ROWS WHERE FOUR ARE CORRECT unchecked, with no"
        " error. That is worse than the crash — a frontend has no oracle and"
        " cannot detect it. If this is `<ADMITTED>` the silent wrong answer is"
        " back.",
    )


def test_a_correct_plan_still_decodes() raises:
    """⚠ THE OTHER DIRECTION, AND IT IS THE ONE A FAIL-CLOSED GATE GETS WRONG.

    A value gate that refused everything would make every assertion above pass.
    The plan endpoint's own fixture — the plan its door test EXECUTES, protoc's
    own serialization of a Filter over a parquet Scan — must
    still decode, and it is read from the OTHER corpus so this cannot be
    satisfied by a fixture this file controls."""
    var text = String("")
    var path = String(
        "src/komira_plan_wire/tests/fixtures/endpoint/"
        + "filter_over_parquet.canonical.hex"
    )
    with open(path, "r") as f:
        text = f.read()
    var bytes = _from_hex(text)
    assert_true(
        len(bytes) > 32,
        "the door's canonical fixture is empty or a stub — this leg cannot"
        " prove the gate admits a correct plan if it has no correct plan",
    )
    var p = plan_from_bytes(bytes^)
    assert_true(
        p.output_schema.num_columns() == 3,
        "the door's own plan decoded to a schema of "
        + String(p.output_schema.num_columns())
        + " columns rather than 3 — either the fixture moved or the value gate"
        " is refusing a plan that is correct, which is the failure mode a"
        " fail-closed gate has and a fail-open one does not.",
    )

# =============================================================================
# `scan_params_from_bytes`: THE PARAMS-ONLY REQUEST
# =============================================================================


def _empty_schema() -> Schema:
    var sb = SchemaBuilder()
    return sb.build()


def _params_binding(var p: ScanParams) -> ScanBinding:
    """A binding that carries `p` and leaves every author-refused field at its
    default."""
    return ScanBinding(
        kind_id=UInt32(0),
        kind_name=String(""),
        name=String(""),
        params=p^,
        schema=_empty_schema(),
        fingerprint=UInt64(0),
        structural_id=UInt64(0),
        gate=PushdownGate.reject_all(),
    )


def _params_only(var p: ScanParams) raises -> List[UInt8]:
    """A `WireScanBinding` carrying `p` and nothing an author may not set --
    the request shape `scan_params_from_bytes` reads, built with the codec's
    own encoder."""
    return binding_to_bytes(_params_binding(p^), SOURCE_VARIANT_BINDING)


def _assert_refused_malformed(var bytes: List[UInt8], what: String) raises:
    var raised = False
    try:
        _ = scan_params_from_bytes(bytes^)
    except e:
        raised = True
        assert_true(
            String(PLAN_WIRE_MALFORMED) in String(e),
            what + ": the refusal must carry PLAN_WIRE_MALFORMED, got: "
            + String(e),
        )
    assert_true(raised, what + ": a params request carrying it must be refused")


def test_scan_params_from_bytes_round_trips_every_tag() raises:
    """Every `PARAM_*` tag an author can send comes back as the SAME typed
    value. `start_offset` is the case that matters: the `topic_live` golden
    carries it as `PARAM_I64`, and a reader that widened it to a string would
    author a different binding."""
    var p = ScanParams()
    p.put_str(String("topic"), String("orders"))
    p.put_i64(String("start_offset"), Int64(1000))
    p.put_i64(String("neg"), Int64(-7))
    p.put_u64(String("gen"), UInt64(42))
    p.put_f64(String("ratio"), Float64(0.5))
    p.put_bool(String("flag"), True)
    var want = p.render()
    var got = scan_params_from_bytes(_params_only(p^))
    assert_equal(got.render(), want)
    assert_equal(got.get_i64(String("start_offset")), Int64(1000))
    assert_equal(got.get_i64(String("neg")), Int64(-7))


def test_scan_params_from_bytes_refuses_a_whole_binding() raises:
    """A request that also names a kind is refused by name, never read for its
    params alone: the kind builds `kind_name` / fingerprint / schema, and a
    reader that dropped them silently would let an author believe they were
    honoured."""
    var p = ScanParams()
    p.put_str(String("topic"), String("orders"))
    var b = _params_binding(p^)
    b.kind_id = UInt32(7)
    b.kind_name = String("komira.broker.topic")
    b.name = String("t")
    _assert_refused_malformed(
        binding_to_bytes(b, SOURCE_VARIANT_BINDING), "kind_id + kind_name + name"
    )


def test_scan_params_from_bytes_refuses_each_identity_field() raises:
    """One field at a time, so a reader that checks only `kind_name` (the
    field the whole-binding case happens to set) is red: a fingerprint, a
    structural id or a snapshot token an author supplies is exactly the
    plan-cache input the kind must compute itself."""
    var p = ScanParams()
    p.put_str(String("topic"), String("orders"))
    var fp = _params_binding(p.copy())
    fp.fingerprint = UInt64(9)
    _assert_refused_malformed(
        binding_to_bytes(fp, SOURCE_VARIANT_BINDING), "fingerprint"
    )
    var sid = _params_binding(p.copy())
    sid.structural_id = UInt64(9)
    _assert_refused_malformed(
        binding_to_bytes(sid, SOURCE_VARIANT_BINDING), "structural_id"
    )
    var tok = _params_binding(p.copy())
    tok.snapshot_token = UInt64(9)
    _assert_refused_malformed(
        binding_to_bytes(tok, SOURCE_VARIANT_BINDING), "snapshot_token"
    )


def test_scan_params_from_bytes_refuses_extra_pushdown_columns() raises:
    """`pushdown_extra_cols` widens what the scan reads. It is the kind's to
    state, so an author who sends one is refused rather than ignored."""
    var p = ScanParams()
    p.put_str(String("topic"), String("orders"))
    var b = _params_binding(p^)
    b.pushdown_extra_cols.append(String("secret_col"))
    _assert_refused_malformed(
        binding_to_bytes(b, SOURCE_VARIANT_BINDING), "pushdown_extra_cols"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
