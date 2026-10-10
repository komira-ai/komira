# =============================================================================
# test_plan_wire_golden_bytes.mojo — ★ THE BYTES, FROZEN.
# =============================================================================
#
# THE PROPERTY THIS FILE EXISTS TO HOLD: these bytes are read by something
# other than the code that wrote them. The work is split, and the split
# matters:
#
#   THIS FILE       freezes the exact BYTES for a small corpus of plans, so a
#                   change to the encoder that alters them is a DELIBERATE act
#                   that updates a checked-in fixture — not silent drift.
#                   Still Mojo->Mojo. It cannot see a SYSTEMATIC error.
#
#   A FOREIGN       `protoc`, which learned the format from `plan.proto` and
#   DECODER         has never seen a line of `plan_wire_codec.mojo`, can read
#                   those same frozen bytes. THAT is the leg that can catch a
#                   symmetric encode/decode defect, and it is only possible
#                   because the bytes are frozen HERE, in a file, rather than
#                   living for a microsecond inside one process. The
#                   `<name>.canonical.hex` fixtures are protoc's own
#                   re-serialization, and LEG D below decodes them.
#
# ⚠ A HASH WOULD NOT DO. A hash tells you something changed. A byte vector
# tells a foreign implementer WHAT TO PRODUCE, and that is the artifact a
# frontend author actually needs — the fixtures are `.hex`, not `.sha256`, and
# not `.bin`, because a binary fixture reviews as "Binary files differ" and the
# whole point is that a byte change must be VISIBLE in the diff that makes it.
#
# ============================ WHAT IS ASSERTED ===============================
#
#   LEG A  FREEZE.   `plan_to_bytes(corpus[i])` equals `<name>.hex`, byte for
#                    byte. Goes RED on any encoder change, including ones that
#                    round-trip perfectly.
#   LEG B  MEANING.  `plan_from_bytes(<name>.hex)` renders as the corpus plan
#                    and carries its `structural_hash` and output schema. LEG A
#                    alone would stay green if the corpus and the fixture were
#                    BOTH replaced with garbage; this leg says the frozen bytes
#                    still MEAN the plan whose name they carry.
#   LEG C  NON-TRIVIAL. Every fixture is longer than the envelope alone. An
#                    encoder that emitted only `format_version` would satisfy
#                    LEG A and LEG B for a corpus of empty plans.
#
# ⚠ WHY THE CORPUS HERE IS SMALL AND READABLE, AND WHY THAT IS NOT A WEAKNESS.
# `test_plan_wire_round_trip_ir.mojo` already drives an ADVERSARIAL
# corpus — every `Field` slot off its default, four distinct pushdown gates, a
# sort whose `nulls_first` deviates from what the render derives — because its
# job is to catch a DROPPED FIELD. This file's job is different: these five
# fixtures are DOCUMENTATION a frontend author reads beside `plan.proto`, and a
# 200-line `.txtpb` full of adversarial padding documents nothing. The two
# corpora are complementary and neither substitutes for the other.
#
# THE CORPUS, and why each member is here:
#   scan               the leaf. Every other fixture contains one.
#   filter_over_scan   one level of node nesting + a binary expression tree.
#   join               TWO leaves, so a codec that encoded `left` twice is red.
#   aggregate          a group-by key and an aggregate with an alias.
#   sort               ★ THE PACKED-REPEATED ARM. `repeated bool descending` /
#                      `nulls_first`, the encoding proto3 makes the DEFAULT for
#                      every other producer and which this package's encoder
#                      does not use. Without it no fixture carries a non-empty
#                      packable repeated field, so LEG D would never feed the
#                      Mojo decoder a packed one — precisely the shape a
#                      decoder that accepts only the unpacked form breaks on.
#   topn               the FUSED sort+limit. A SEPARATE oneof arm carrying the
#                      same packable pair — the codec's arms are hand-written
#                      per node, so `sort` implies nothing about this one.
#   limit              `int64 offset` NON-ZERO. proto3 omits a zero scalar, so
#                      a `LIMIT 5` at offset 0 is byte-identical between a
#                      correct encoder and one that never wrote the field.
#   distinct           the PRESENCE-BOOL idiom (`has_columns` beside `repeated
#                      string columns`), which proto3 forces on every optional
#                      list in this schema and which no fixture had shown.
#   union              a repeated MESSAGE — the framing class that can never be
#                      packed, i.e. the other branch of `read_into_repeated_*`.
#                      Three branches, all different, so a codec that wrote
#                      `children[0]` thrice prints one name three times.
#   window             the richest arm: a THIRD packed `descending`, a repeated
#                      message with CONTENT (three `PartitionExpr`s differing
#                      in every slot), four enum tags all OFF the proto3 zero
#                      so LEG 5 can falsify them, and a NEGATIVE int64.
#   scan_nested        ★ THE WIDEST ARM, and it is not about its node. A STRUCT
#                      + UNION + LIST schema populates `WireField`'s three
#                      repeated scalars, and a `WireField` is in EVERY schema in
#                      EVERY plan — so a packed-decoding defect makes every plan
#                      with one of those column types unreadable REGARDLESS of
#                      node kind. Every other schema here is flat scalar columns,
#                      where all three fields are empty and proto3 omits them.
#   project_exprs      the only arm about EXPRESSIONS rather than plan nodes.
#                      `WireExpr` has many oneof arms; one expr per FAMILY here — alias over cast,
#                      unary_op, in_list, string_op, substring, when, and a
#                      window_fn whose `descending` is the packed class again
#                      but reachable from ANY node.
#   asof_join          the FOURTH and FIFTH packed `descending` sites, on the
#                      four PRE-SORT HINT lists — the one node where a wrong
#                      hint skips a sort that was needed and returns WRONG ROWS
#                      with no error. Every RIGHT-side string slot differs.
#   correlated_subquery ★ a PLAN nested inside an EXPRESSION — the format's only
#                      CYCLE. It is why `WireFilterNode.predicate`/`.child`,
#                      `WireScanNode.filter` and `WireJoinNode.residual` are
#                      `repeated` fields that legally hold EXACTLY ONE element,
#                      and a frontend author needs to see one.
#   topic_live         a REGISTERED-KIND leaf (`komira.broker.topic`): the
#                      binding's kind name, typed params, identity, gate and
#                      the LIVE policy with a zero token, as a context that
#                      registered the kind receives them.
#   index_pinned       the same for `komira.search.index`, pinned by a
#                      `generation` PARAM rather than by `SNAPSHOT_PINNED`.
#
# ============================= HOW TO REGOLD =================================
#
# Every case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block UNCONDITIONALLY, holding
# the bytes it encoded in the canonical `.hex` rendering. Run this test, copy
# the block into `tests/fixtures/golden/<name>.hex`, and re-derive
# `<name>.canonical.hex` with protoc (`--decode` then `--encode`). The blocks
# are printed on PASS as well as on FAIL on purpose: a regold path that only
# works when the test is already red is a regold path nobody can use to
# bootstrap a NEW fixture.
#
# ⚠ REGOLDING IS NOT A FIX. If a `.hex` moved and you did not intend to change
# the format, the diff is the bug report. Read it before you overwrite it.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_AND,
    BIN_GT,
    BIN_LT,
    UN_IS_NOT_NULL,
    STR_ENDS_WITH,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_NEAREST,
    CORR_KIND_EXISTS,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
)
from komira_plan_expr.partition_expr import (
    PartitionExpr,
    PartitionFrame,
    PF_LAG,
    PF_LEAD,
    PF_NTILE,
    PF_SUM,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_FOLLOWING,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_LIVE,
)
from komira_scan_source.scan_params import ScanParams, param_hash_string
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

from komira_plan_wire import plan_to_bytes, plan_from_bytes


# =============================================================================
# THE FIXTURE FILES
# =============================================================================

comptime _FIXTURE_DIR: String = "src/komira_plan_wire/tests/fixtures/golden/"

# Bytes per `.hex` line. 32 keeps a line at 64 characters, which fits a diff
# column without wrapping, so a one-byte change shows as ONE changed line
# rather than reflowing the file.
comptime _HEX_BYTES_PER_LINE: Int = 32


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    """The canonical `.hex` rendering: lowercase, 32 bytes per line, `\\n`
    terminated, no offsets and no ASCII column.

    NO OFFSETS DELIBERATELY. An offset column makes an INSERT reflow every
    subsequent line, so a one-byte insertion reviews as a whole-file rewrite —
    which is exactly the review this fixture exists to make possible."""
    var out = String("")
    for i in range(len(bytes)):
        out += _hex_nibble(bytes[i] >> 4)
        out += _hex_nibble(bytes[i] & 0xF)
        if (i % _HEX_BYTES_PER_LINE) == (_HEX_BYTES_PER_LINE - 1):
            out += "\n"
    if len(bytes) % _HEX_BYTES_PER_LINE != 0:
        out += "\n"
    return out^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error(
        "plan_wire golden: a `.hex` fixture holds a non-hex character (byte "
        + String(Int(c))
        + "). The fixtures are copied from the GOLDEN block this test prints;"
        + " they are not hand-editable."
    )


def _from_hex(text: String) raises -> List[UInt8]:
    """Parse a `.hex` fixture. Whitespace of every kind is skipped, so the
    line width is a REVIEW convention and not part of the format — a reviewer
    may not reflow one, but doing so must not change what the file MEANS."""
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord(" "))
            or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r"))
            or c == UInt8(ord("\t"))
        ):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error(
            "plan_wire golden: a `.hex` fixture has an ODD number of hex"
            + " digits ("
            + String(len(nibbles))
            + "). Half a byte is not a byte."
        )
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> String:
    """Read `tests/fixtures/golden/<name>.hex`.

    The fixture is declared test data, staged at its repository path under the
    test's working directory."""
    var path = _FIXTURE_DIR + name + ".hex"
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        pass
    raise Error(
        "plan_wire golden: fixture `"
        + path
        + "` is MISSING. If this is a NEW corpus member, the GOLDEN block this"
        + " test just printed is its content — write it to that path and"
        + " declare it as test data. If it is not new, something deleted a"
        + " checked-in fixture, and the foreign decode is now covering one"
        + " plan fewer."
    )


# =============================================================================
# THE CORPUS
# =============================================================================
#
# ⚠ EVERY VALUE BELOW IS A PUBLISHED CONSTANT ONCE ITS `.hex` IS CHECKED IN.
# These are not arbitrary test values any more: they are the plan a foreign
# implementer reconstructs when they read the fixture. Changing `"orders"` to
# `"t"` is a fixture change, and the diff will say so.


def _schema() raises -> Schema:
    """Three columns, one per Arrow type class the corpus needs. Small on
    purpose — see the header. `a` carries column metadata because a `Field`
    slot that no fixture populates is a slot the `.txtpb` never shows a
    frontend author, and the metadata pair is the one most likely to be
    mis-mapped (the TABLE-level pair on `Schema` shares its name)."""
    var sb = SchemaBuilder()
    var a = Field("a", ArrowType.INT64, False)
    a._metadata_keys = [String("unit")]
    a._metadata_values = [String("cents")]
    sb.add_field(a^)
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _nested_schema() raises -> Schema:
    """★ THE SCHEMA-LEVEL PACKABLE FIELDS — the widest blast radius in this
    format, and the one no other fixture in this corpus reaches.

    `WireField` carries THREE repeated scalars: `union_type_ids` (int64),
    `child_type_ids` (uint32) and `child_nullables` (bool). A `WireField` is in
    EVERY schema in EVERY plan, so when the Mojo decoder could not read a
    PACKED repeated scalar, any plan whose schema held a STRUCT, MAP, LIST or
    UNION column was unreadable from a standard producer — REGARDLESS of its
    node kinds. That is a strictly larger surface than the sort/topn arms,
    which need a particular node.

    ⚠ AND EVERY OTHER SCHEMA IN THIS CORPUS IS FLAT SCALAR COLUMNS, so all
    three fields are empty in them, and proto3 omits an empty repeated field
    entirely. There is nothing on the wire to be packed, so nine green
    fixtures said nothing about this at all.

    THE VALUES, and why each one:
      st  a STRUCT with THREE children of DIFFERENT types and MIXED
          nullability — `[False, True, True]`. A codec that wrote one bool for
          the list, or that sized `child_nullables` from `child_names` and
          re-derived the values, cannot produce this. Three children also means
          a packed payload longer than one byte.
      u   a UNION_SPARSE with type ids `[3, 7, 11]` — non-contiguous and not
          starting at 0, so an encoder that emitted `range(n)` is a diff. This
          is the `union_type_ids` int64 arm.
      l   a LIST, whose single child is NON-nullable while the list itself is
          nullable. The two flags are adjacent on the wire and swapping them is
          otherwise invisible."""
    var sb = SchemaBuilder()
    var st = Field("st", ArrowType.STRUCT, True)
    st.add_child("k", ArrowType.INT64, False)
    st.add_child("v", ArrowType.STRING, True)
    st.add_child("f", ArrowType.FLOAT64, True)
    sb.add_field(st^)
    var ids: List[Int] = [3, 7, 11]
    sb.add_field(Field.union("u", ArrowType.UNION_SPARSE, ids, False))
    sb.add_field(Field.list_of_string("l", True, item_nullable=False))
    return sb.build()


def _binding(name: String, path: String) raises -> ScanBinding:
    """A `ScanBinding` leaf — the PURE-DATA scan shape every new source kind
    uses. Deliberately NOT a `ParquetSource`: that arm is one of the two
    concrete `SourceVariant` arms, and every new source kind is a binding, so
    a golden should document the binding shape."""
    var p = ScanParams()
    p.put_str(String("path"), String(path))
    p.put_i64(String("stripe_count"), Int64(7))
    p.put_bool(String("has_footer"), True)
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=name,
        params=p^,
        schema=_schema(),
        fingerprint=UInt64(0xDEADBEEF),
        structural_id=UInt64(0xFEEDFACE),
        gate=PushdownGate.conjunctive_comparison(),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(1234567890),
    )


def _scan(name: String, path: String) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=_binding(name, path)),
        _schema(),
    )


def _corpus_scan() raises -> LogicalPlan:
    return _scan(String("orders"), String("/data/orders.orc"))


def _corpus_scan_nested() raises -> LogicalPlan:
    """The leaf again, but over `_nested_schema()` — see that function for why
    this is the widest arm in the corpus rather than a second scan.

    ⚠ THE SCHEMA APPEARS THREE TIMES ON THESE BYTES, and they are NOT equally
    guarded. Flipping one packed `child_nullables` bit in
    `scan_nested.canonical.hex` at each site in turn:

      `scan.schema`                  LEG D RED — this is what the factory
                                     derives the decoded plan's output schema
                                     from.
      `plan.output_schema`           EVERY TEST STAYS GREEN. The envelope's
                                     copy is compared by the codec's
                                     `_check_output_schema`, which renders only
                                     `name:type_id:nullable` — so a nested-child
                                     disagreement between the two copies is
                                     observed by NOTHING, here or in the codec.
                                     Benign (the factory derives from the
                                     other copy and ignores this one) and
                                     written down because "the wire carries it"
                                     and "something checks it" are different
                                     claims.
      `scan.source.binding.schema`   not separately measured.

    That first flip is also what makes `_schema_text`'s strengthening
    load-bearing rather than cosmetic — see its docstring."""
    var p = ScanParams()
    p.put_str(String("path"), String("/data/nested.orc"))
    var binding = ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("nested"),
        params=p^,
        schema=_nested_schema(),
        fingerprint=UInt64(0xDEADBEEF),
        structural_id=UInt64(0xFEEDFACE),
        gate=PushdownGate.conjunctive_comparison(),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(1234567890),
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=binding^),
        _nested_schema(),
    )


def _corpus_filter_over_scan() raises -> LogicalPlan:
    """`(a > 3) AND (b < 9)` over the scan. TWO levels of expression nesting,
    because a nested message inside a nested message is where a length-prefix
    framing defect first becomes visible to a foreign parser."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_AND,
            Expr.binary(
                BIN_GT,
                Expr.col_ref("a"),
                Expr.literal(ScalarValue.from_int64(Int64(3))),
            ),
            Expr.binary(
                BIN_LT,
                Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(9))),
            ),
        ),
        _corpus_scan(),
    )


def _corpus_join() raises -> LogicalPlan:
    """⚠ THE TWO LEAVES DIFFER, BY NAME AND BY PATH. A join over one leaf twice
    would round-trip identically for a codec that encoded `left` twice and
    never read `right` — and would freeze identically too."""
    var lo: List[String] = [String("a")]
    var ro: List[String] = [String("a")]
    return LogicalPlan.join(
        _scan(String("orders"), String("/data/orders.orc")),
        _scan(String("lineitem"), String("/data/lineitem.orc")),
        lo^,
        ro^,
        JOIN_INNER,
        JOIN_ALGO_AUTO,
    )


def _corpus_sort() raises -> LogicalPlan:
    """★ THE FIRST FIXTURE IN THIS CORPUS WITH A NON-EMPTY PACKABLE REPEATED
    FIELD, and that is the whole reason it is here rather than any other arm.

    `WireSortNode` carries `repeated bool descending` and `repeated bool
    nulls_first`. proto3 PACKS a repeated scalar by default, so protoc's
    `<name>.canonical.hex` writes both as ONE length-delimited field — while
    this package's encoder writes one tag per element (`PbEncoder`'s
    `write_*_element`). Both are legal and a conformant reader takes either,
    which is exactly why no Mojo->Mojo test could notice a Mojo DECODER that
    took only one of them.

    ⚠ A DECODER THAT TOOK ONLY THE UNPACKED FORM would refuse a
    `WirePlanEnvelope` carrying a sort, authored as `.txtpb` and encoded by
    protoc — the "a Python frontend sends a plan" case verbatim — with
    `ProtobufError.WIRE_MISMATCH: expected VARINT`. See `komira_proto_codec`'s
    `read_into_repeated_bool`. A corpus of flat scalar columns avoids the
    encoding systematically, because proto3 omits an empty repeated field
    entirely. THIS fixture is what makes LEG D drive the packed path with real
    bytes rather than with a comment.

    THE VALUES, and why each one:
      keys        TWO, of different Arrow types (`s` STRING, `a` INT64), so a
                  packed length prefix covers more than one element.
      descending  [False, True] — MIXED. A codec that wrote one bool for the
                  whole list, or that packed the length rather than the
                  values, cannot produce this.
      nulls_first [False, True] — the exact INVERSE of what
                  `_resolve_nulls_first` derives from `descending`
                  (the DERIVED placement is NULLS LAST in both directions, so
                  the derived list is `[False, False]`). ⚠ THAT DEVIATION IS
                  LOAD-BEARING: a codec
                  that DROPPED `nulls_first` would have the decoder re-derive
                  the default and land on a different list, so the field being
                  carried is asserted rather than assumed. A fixture that
                  froze the derived values would be satisfied by an encoder
                  that never wrote the field at all.
    """
    var keys: List[String] = [String("s"), String("a")]
    var desc: List[Bool] = [False, True]
    var nf: List[Bool] = [False, True]
    return LogicalPlan.sort(keys^, desc^, _corpus_scan(), Optional(nf^))


def _corpus_topn() raises -> LogicalPlan:
    """The FUSED sort+limit — a SEPARATE oneof arm from `sort`, not a spelling
    of it, and it carries the packed-repeated pair a second time.

    ⚠ IT IS NOT REDUNDANT WITH `sort`, and the reason is worth stating: a
    packed-repeated defect is a property of the DECODER'S FIELD READER, so one
    fixture proves that reader works. What a second node carrying the same
    field types proves is that `WireTopNNode`'s arm is WIRED to it — the
    codec's arms are hand-written per node (`plan_wire_codec.mojo` dispatches on
    `tag`), so "sort round-trips" implies nothing about topn.

    `n = 3` is non-zero for the same reason `limit`'s offset is (see below).
    `nulls_first` again DEVIATES: derived from `descending = [True]` would be
    [False]."""
    var keys: List[String] = [String("b")]
    var desc: List[Bool] = [True]
    var nf: List[Bool] = [True]
    return LogicalPlan.topn(keys^, desc^, 3, _corpus_scan(), Optional(nf^))


def _corpus_limit() raises -> LogicalPlan:
    """★ THE OFFSET IS NON-ZERO, AND THAT IS THE ENTIRE POINT OF THE FIXTURE.

    `WireLimitNode` is `int64 n = 1` and `int64 offset = 2`, and proto3 OMITS a
    zero-valued scalar from the wire. `LimitData.offset` defaults to 0, so a
    plain `LIMIT 5` fixture is byte-identical between a correct encoder and one
    that never learned the field exists — and `offset` is the engine's RANGE
    primitive, i.e. the difference between `rows [0,5)` and `rows [2,7)`.

    A fixture frozen at a proto3 default documents nothing to a frontend
    author: they cannot tell from it whether the field is written, and neither
    can this gate."""
    return LogicalPlan.limit(5, _corpus_scan(), 2)


def _corpus_distinct() raises -> LogicalPlan:
    """★ THE PRESENCE-BOOL IDIOM, WHICH proto3 FORCED ON THIS SCHEMA AND WHICH
    NO FIXTURE HAD EVER SHOWN A FRONTEND AUTHOR.

    `DistinctData.columns` is `Optional[List[String]]` and None means DISTINCT
    over the FULL child schema — a different query from `DISTINCT (a)`. proto3
    has no presence on a repeated field, so `WireDistinctNode` carries an
    explicit `bool has_columns` beside `repeated string columns`, and the same
    pair again for `estimated_groups`. Both bools must be TRUE here: at False
    they are proto3 defaults, absent from the wire, and the `.txtpb` a frontend
    author reads would not mention them at all.

    ⚠ `estimated_groups` IS DELIBERATELY *NOT* SET HERE. `has_estimated_groups`
    / `estimated_groups` are
    the second presence pair on this message, and a fixture that populated them
    (via `set_estimated_groups`, the only path — the factory does not take the
    field) is ENCODABLE AND NOT DECODABLE: `plan_to_bytes` writes both, and
    `plan_from_bytes` then raises
    `PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS`.

    That asymmetry is INTENTIONAL and documented in the codec's coverage
    ledger — the hint has no public mutable path after construction, and the
    codec refuses rather than silently dropping it, because losing a
    cardinality hint changes which side of a join builds. It is recorded here
    because the consequence for THIS corpus is structural: no golden `.hex`
    can ever carry `estimated_groups` while the refusal stands, so a foreign
    decode of the corpus cannot cover those two fields, and a reader must not
    infer from a green run that it does. The refusal itself is asserted by name
    in `test_plan_wire_round_trip_ir.mojo`, which is where a refusal
    belongs."""
    var cols: List[String] = [String("a"), String("s")]
    return LogicalPlan.distinct(Optional(cols^), _corpus_scan())


def _corpus_union() raises -> LogicalPlan:
    """★ A REPEATED *MESSAGE*, WHICH IS A DIFFERENT FRAMING CLASS FROM EVERY
    OTHER FIXTURE HERE.

    `sort` and `topn` cover repeated SCALARS, where the packed/unpacked split
    lives. A repeated message can never be packed — it is N separate
    length-delimited occurrences of one tag — so this arm exercises the OTHER
    branch of `read_into_repeated_*`, the one that appends once per
    `next_field()`.

    THREE branches, ALL DIFFERENT (`l`/`m`/`r`, three paths). A codec that
    wrote `children[0]` three times produces a fixture of the SAME SIZE, so
    size cannot see it — the `.txtpb` protoc prints can, because it renders
    three `binding` blocks and a duplicating encoder prints one name thrice.

    ⚠ UNION IS THE ONE FACTORY THAT TAKES ITS OUTPUT SCHEMA rather than
    deriving it, so the schema on the wire is an INPUT here, not a
    derivation."""
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan(String("l"), String("/data/l.orc"))))
    kids.append(OwnedPointer(_scan(String("m"), String("/data/m.orc"))))
    kids.append(OwnedPointer(_scan(String("r"), String("/data/r.orc"))))
    return LogicalPlan.union(kids^, _schema())


def _corpus_asof_join() raises -> LogicalPlan:
    """★ THE FOURTH AND FIFTH PACKED `repeated bool` SITES, and the ONE node
    where getting them wrong produces WRONG ROWS SILENTLY.

    `left_sort_keys` / `left_sort_desc` / `right_sort_keys` / `right_sort_desc`
    are PRE-SORT HINTS — they assert "this side is ALREADY sorted on these
    columns, skip the sort phase". The failure is asymmetric and both
    directions are bad: dropping a hint costs a sort, and INVENTING one on a
    side that is not sorted skips a sort that was needed and emits wrong rows
    with no error anywhere.

    ⚠ EVERY STRING SLOT ON THIS MESSAGE HOLDS A DIFFERENT VALUE, deliberately.
    `right_keys` and `right_sort_keys` are both on the right side, and a codec
    that wrote the equi-key into the pre-sort hint — the "re-derive the hints
    from the keys" mistake — is byte-identical to a correct one if the two hold
    the same string. A repeated field of ONE element and a singular field of
    the same string are also the same bytes, so `right_asof` must differ too.

    `ASOF_NEAREST` (2) and an INT64 tolerance are both off the engine zero:
    `ASOF_BACKWARD` and `ASOF_TOL_NONE` are value 0, which proto3 omits.

    ⚠ EVERY NAME MUST RESOLVE AGAINST `_schema()` — `[a, b, s]` — because the
    decoder refuses an unresolvable reference (`PLAN_WIRE_UNRESOLVED_COLUMN`).
    Three names per side is exactly enough for the property that matters: the
    three RIGHT string slots (`right_keys`, `right_asof`, `right_sort_keys`)
    are pairwise distinct, which is the pairing that is otherwise
    byte-identical.
    `left_sort_keys` reuses `a` in its SECOND position on purpose — it is a
    2-element list against a 1-element `left_keys`, so a re-derivation from the
    equi-keys still lands on a different length."""
    var lk: List[String] = [String("a")]
    var rk: List[String] = [String("b")]
    var lsk: List[String] = [String("s"), String("a")]
    var lsd: List[Bool] = [False, True]
    var rsk: List[String] = [String("s")]
    var rsd: List[Bool] = [True]
    return LogicalPlan.asof_join(
        _scan(String("quotes"), String("/data/quotes.orc")),
        _scan(String("trades"), String("/data/trades.orc")),
        lk^, rk^,
        String("b"), String("a"),
        ASOF_NEAREST, AsofTolerance.int64(Int64(90)),
        lsk^, lsd^, rsk^, rsd^,
    )


def _corpus_correlated_subquery() raises -> LogicalPlan:
    """★ A PLAN NESTED INSIDE AN EXPRESSION — the format's only CYCLE, and the
    one shape in this corpus whose framing is a compiler decision rather than a
    schema one.

    `WireExpr` can hold a `WireCorrelatedSubquery`, which holds a `WirePlan`,
    which holds a `WireExpr`. `protoc-gen-mojo` runs a DFS over the message
    graph and BOXES the back-edges it finds as `List[T]` — so on this format
    `WireFilterNode.predicate`, `WireFilterNode.child`, `WireScanNode.filter`
    and `WireJoinNode.residual` are all `repeated` fields that legally hold
    EXACTLY ONE element. Nothing in the corpus reached the cycle that made them
    that way, so nothing here has ever shown a frontend author what an
    exactly-one `repeated` looks like or why it is one.

    ⚠ `CORR_KIND_EXISTS` IS ENGINE VALUE 0, AND THAT IS THE POINT OF USING IT.
    proto3 cannot tell an absent enum from an explicit zero, and EXISTS is a
    real kind — so `correlated_kind_to_wire` maps it to 1 and RESERVES 0 for
    "the field was not written". A fixture carrying only SCALAR would never
    show that the offset exists, and LEG 5 would have nothing to resolve."""
    var refs: List[String] = [String("a")]
    return LogicalPlan.filter(
        Expr.correlated_subquery(
            LogicalPlan.limit(1, _scan(String("inner"), String("/data/i.orc"))),
            refs^,
            CORR_KIND_EXISTS,
        ),
        _corpus_scan(),
    )


def _corpus_project_exprs() raises -> LogicalPlan:
    """★ THE EXPRESSION FAMILIES. Every fixture above is a PLAN-node story;
    `WireExpr` has 22 oneof arms and this corpus reached THREE of them
    (`col_ref`, `literal`, `binary_op`, all from `filter_over_scan`).

    A `Project` is the cheapest node that can hold an arbitrary expression
    list, so this arm is a project whose exprs are chosen one per FAMILY —
    each is a different `WireExpr` arm with a different payload SHAPE, not a
    different operator within one arm:

      alias(cast(...))  TWO arms nested, and `cast` carries a `DType` through
                        the codec's own `_DT_*` table — the one field with no
                        stable numeric identity in the Mojo stdlib.
      unary_op          a single-child arm. `UN_IS_NOT_NULL`, not `UN_NOT` —
                        `UN_NOT` is engine value 0 and proto3 omits it, so an
                        encoder that never wrote `op` would be byte-identical.
      in_list           ★ a repeated MESSAGE of `WireScalar`s. Three values,
                        all different, so a codec that wrote `values[0]` three
                        times is a diff in the `.txtpb`.
      string_op         an arm carrying a STRING payload beside its child.
                        `STR_ENDS_WITH` (2), again off the zero.
      substring         TWO int payloads on one arm, `start` and `length`, both
                        non-zero and DIFFERENT, so crossing the two slots is a
                        diff.
      when              the CASE arm: a list of (condition, result) pairs plus
                        a default. Two cases, so the pair list is not
                        length-1-degenerate.
      window_fn         ★★ THE ONE THAT MATTERS MOST HERE.
                        `WireWindowFn.descending` is a `repeated bool` — the
                        packed-repeated class again, but on an EXPRESSION,
                        which means ANY node type can carry it. `window` above
                        covers the PLAN-node window; this covers the
                        EXPRESSION one, and they are different messages with
                        different codec arms.

    ⚠ `descending` HAS THREE ELEMENTS AGAINST TWO `partition_by` AND ONE
    `order_by`. The three lists are NOT parallel and a decoder that sized one
    from another lands on a different length.

    ⚠ WHAT LEG D SEES OF IT DEPENDS ON THE RENDER. LEG D's comparison is the
    plan RENDER plus the output schema, and `_infer_expr_field` has no
    EXPR_WINDOW_FN arm, so the schema is blind to `descending`; only a render
    that prints `descending=[T/F..]` lets a flipped bit inside the packed
    payload of `project_exprs.canonical.hex` (`3a 03 01 00 01` ->
    `3a 03 01 01 01`) turn LEG D red. The VALUE of `descending` is asserted
    independently by `test_plan_wire_round_trip_ir.mojo`, which compares a
    hand-written IR rendering rather than the plan's own — the two files
    cover disjoint failures here and neither substitutes for the other."""
    var xs = ExprArray()
    xs.append(Expr.alias(Expr.cast(Expr.col_ref("a"), DType.float64), "a_f"))
    xs.append(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("b")))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(11)))
    vals.append(ScalarValue.from_int64(Int64(22)))
    vals.append(ScalarValue.from_int64(Int64(33)))
    xs.append(Expr.in_list_node(Expr.col_ref("a"), vals^))
    xs.append(Expr.string_op(STR_ENDS_WITH, Expr.col_ref("s"), "xyz"))
    xs.append(Expr.substring(Expr.col_ref("s"), 2, 4))
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(
                BIN_GT,
                Expr.col_ref("a"),
                Expr.literal(ScalarValue.from_int64(Int64(100))),
            ),
            Expr.literal(ScalarValue.from_int64(Int64(1))),
        )
    )
    cases.append(
        WhenCaseData(
            Expr.binary(
                BIN_LT,
                Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(0))),
            ),
            Expr.literal(ScalarValue.from_int64(Int64(2))),
        )
    )
    xs.append(
        Expr.when(cases^, Expr.literal(ScalarValue.from_int64(Int64(-1))))
    )
    var pb: List[String] = [String("a"), String("b")]
    var ob: List[String] = [String("s")]
    var wdesc: List[Bool] = [True, False, True]
    xs.append(
        Expr.window_fn(
            PF_LAG, String("a"), 3, _deviating_frame()
        ).with_window_spec(pb^, ob^, wdesc^)
    )
    return LogicalPlan.project(xs^, _corpus_scan())


def _corpus_window() raises -> LogicalPlan:
    """★ THE WINDOW NODE — `PLAN_PARTITION_BY`, the richest arm in the corpus.

    It is here for four properties no other fixture has, and only the first is
    about packing:

      1. A THIRD packed `repeated bool descending` site, on `order_keys` this
         time. `[True, False]` against `["a", "s"]` — a decoder that sized the
         list from `order_keys` still cannot invent which of the two is which.

      2. A repeated MESSAGE with CONTENT. `union`'s children are three copies
         of one shape; a `WirePartitionExpr` carries a func TAG, a frame, a
         default `WireScalar` and a name, and the three here differ in every
         one of those slots.

      3. ★ ENUM TAGS THAT LEG 5 CAN ACTUALLY FALSIFY. `func`, `frame.units`
         and the two frame bound tags are vocabulary enums, and LEG 5 refuses
         a value protoc cannot NAME. Every value below is deliberately OFF the
         proto3 zero: `RANGE` not ROWS, `PRECEDING` not UNBOUNDED_PRECEDING,
         `FOLLOWING` not CURRENT_ROW — because an enum sitting at member 0 is
         omitted from the wire, and an omitted field is one LEG 5 never sees.

      4. A NEGATIVE int64 (`start_offset = -5`). Every other integer in this
         corpus is positive, and a negative varint is the shape a `uint32`
         slot silently eats.

    The three exprs also cover the two OPTIONAL-payload spellings on the same
    message: `PF_LEAD` has a default value AND `has_default = True`, `PF_NTILE`
    has an empty `ScalarValue` with `has_default = False`, and `PF_SUM` has
    neither a default nor an argument column of the same kind. A codec that
    ignored the presence flag and read the box anyway is a diff on the second.

    ⚠ EVERY KEY NAMED HERE MUST EXIST IN `_schema()` — `[a, b, s]`. The Mojo
    decoder RESOLVES `partition_keys` and `order_keys` against the schema in
    scope and raises `PLAN_WIRE_UNRESOLVED_COLUMN` on a name it cannot find,
    because an unresolved reference that is silently dropped returns WRONG ROWS
    with no error. An order key borrowed from another test's schema (`ts`)
    would make bytes protoc accepts — they ARE a valid `WirePlanEnvelope` —
    and `plan_from_bytes` refuses: protoc is a SCHEMA oracle, and a plan can be
    perfectly well-formed and still name a column that does not exist."""
    var pk: List[String] = [String("b")]
    var ok: List[String] = [String("a"), String("s")]
    var desc: List[Bool] = [True, False]
    var xs = List[PartitionExpr]()
    xs.append(
        PartitionExpr(
            PF_LEAD, String("a"), 4,
            ScalarValue.from_int64(Int64(-77)), True,
            _deviating_frame(), String("lead_with_a_default"),
        )
    )
    xs.append(
        PartitionExpr(
            PF_NTILE, String(""), 7,
            ScalarValue(), False,
            _deviating_frame(), String("ntile7"),
        )
    )
    xs.append(
        PartitionExpr(
            PF_SUM, String("a"), 0,
            ScalarValue(), False,
            _deviating_frame(), String("running_total"),
        )
    )
    return LogicalPlan.partition_by(pk^, ok^, desc^, xs^, _corpus_scan())


def _deviating_frame() -> PartitionFrame:
    """A frame in which ALL FIVE slots differ from the proto3 default AND from
    every frame the engine's own factories build.

    `PartitionFrame.default_ordered()` is (ROWS, UNBOUNDED_PRECEDING, 0,
    CURRENT_ROW, 0) and `default_unordered()` is (ROWS, UNBOUNDED_PRECEDING, 0,
    UNBOUNDED_FOLLOWING, 0) — between them, four of the five slots sit at the
    proto3 zero, where an encoder that never wrote the field emits bytes
    identical to a correct one. A fixture built from either would document
    nothing."""
    return PartitionFrame(
        FRAME_UNITS_RANGE,
        FRAME_BOUND_PRECEDING, Int64(-5),
        FRAME_BOUND_FOLLOWING, Int64(7),
    )


def _corpus_aggregate() raises -> LogicalPlan:
    """`SELECT a, sum(b) AS total FROM orders GROUP BY a`."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("total")))
    )
    return LogicalPlan.aggregate(gb^, ax^, _corpus_scan())

# -----------------------------------------------------------------------------
# THE REGISTERED-KIND LEAVES
#
# A plan that roots at `komira.broker.topic` or `komira.search.index` is the
# first plan whose bytes leave a process to be executed by a context that has
# REGISTERED the kind: a decoded binding is always unbound and resolves at the
# executing context. So these two are frozen as the wire form of the binding
# itself — kind name, params, identity, gate, policy and the LIVE token.
#
# ⚠ BUILT HERE, NOT BY THE KINDS' OWN CONSTRUCTORS, AND THAT IS A LAYERING
# CHOICE. `komira_plan_wire` sits directly above the core packages; importing
# `komira_broker` / `komira_search_runtime` into its welded test would put both
# kinds' closures under the codec's gate. So each case restates, from core
# primitives alone, exactly what the kind's SHIPPING constructor returns for
# the same inputs:
#   topic_live    == `BrokerScanRuntime.build_binding({topic: "orders",
#                    partitions: "0,3", start_offset: 1000})` over a topic
#                    whose config declares `_topic_schema()` minus its last
#                    column — i.e. the relation schema FOLLOWED BY the
#                    `__partition INT64 NOT NULL` column the kind appends.
#                    `build_binding` is the only EXECUTABLE topic binding: the
#                    kind's `open_scan` refuses any binding whose schema does
#                    not end in `__partition` (BROKER_SCAN_NOT_EXECUTABLE_
#                    BINDING), so freezing the bare `broker_topic_binding(p,
#                    <relation schema>)` would freeze bytes no registered
#                    context can run. Canonical param order and identity fold
#                    are `broker_topic_binding`'s (`_broker_fingerprint`,
#                    default isolation, so no isolation fold), which
#                    `build_binding` returns.
#   index_pinned  == `search_scan_binding("docs", "body", "error timeout",
#                    0x5EA2C4, generation=42)` (`komira_search_scan`),
#                    identity `_identity_of`.
# The kind names are the registered names. The LINK from each shipping
# constructor to these bytes belongs in a test that can import the kind:
# `komira_broker`'s `build_binding` (the topic kind) and
# `komira_search_scan`'s `search_scan_binding` each encode their binding
# through `plan_to_bytes` and compare it to the checked-in `.hex`. Those link
# tests sit outside this package so that `komira_plan_wire` keeps no broker or
# search dependency. This file owns the claim that the SHAPE has one frozen
# spelling on the wire; the link tests own the claim that the constructors
# still produce that shape.
#
# ⚠ `komira.logs` IS NOT HERE: no logs scan kind exists in this repository
# yet. When one does, it gets a case in this same shape.
# -----------------------------------------------------------------------------

comptime _TOPIC_KIND: StaticString = "komira.broker.topic"
comptime _INDEX_KIND: StaticString = "komira.search.index"


def _topic_schema() raises -> Schema:
    """The schema `build_binding` emits for the `orders` topic: the relation
    schema its config declares (plain scalar columns: a topic config carries
    name, type and nullability only — no metadata, no children), then the
    `__partition INT64 NOT NULL` column the kind appends and its `open_scan`
    requires last."""
    var sb = SchemaBuilder()
    sb.add_field(Field("order_id", ArrowType.INT64, False))
    sb.add_field(Field("amount", ArrowType.INT64, True))
    sb.add_field(Field("note", ArrowType.STRING, True))
    sb.add_field(Field("__partition", ArrowType.INT64, False))
    return sb.build()


def _corpus_topic_live() raises -> LogicalPlan:
    """`read_topic("orders", partitions=[0, 3], start_offset=1000)`: LIVE, so
    the plan's snapshot token is ZERO. A LIVE token is written only to the
    per-execution copy, never back into a plan, so a non-zero token in these
    bytes would be a cached plan that pinned an offset nobody asked for."""
    var kind = String(_TOPIC_KIND)
    var kid = scan_kind_id(kind)
    var p = ScanParams()
    p.put_str(String("topic"), String("orders"))
    p.put_str(String("partitions"), String("0,3"))
    p.put_i64(String("start_offset"), Int64(1000))
    # The broker identity fold: topic, then each canonical partition. The
    # offset is EXCLUDED — that is what LIVE means.
    var fp = param_hash_string(String("orders"), UInt64(kid))
    fp = (fp ^ UInt64(0)) * UInt64(1099511628211)
    fp = (fp ^ UInt64(3)) * UInt64(1099511628211)
    var binding = ScanBinding(
        kind_id=kid,
        kind_name=kind^,
        name=String("orders"),
        params=p^,
        schema=_topic_schema(),
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        snapshot_policy=SNAPSHOT_LIVE,
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(binding^), _topic_schema()
    )


def _hit_schema() raises -> Schema:
    """`komira_search.source.hit_schema()`, restated: `_score` F64, `_id` I64,
    `_source` STRING, none nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("_score", ArrowType.FLOAT64, False))
    sb.add_field(Field("_id", ArrowType.INT64, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    return sb.build()


def _corpus_index_pinned() raises -> LogicalPlan:
    """`read_index("docs", field="body", query="error timeout",
    generation=42)`: PINNED. The search kind pins by a `generation` PARAM, not
    by `SNAPSHOT_PINNED` — the policy stays LIVE and the token stays zero — so
    the pin is in identity through params, and these bytes freeze that
    spelling rather than a token."""
    var kind = String(_INDEX_KIND)
    var kid = scan_kind_id(kind)
    var p = ScanParams()
    p.put_str(String("index"), String("docs"))
    p.put_str(String("field"), String("body"))
    p.put_str(String("query"), String("error timeout"))
    p.put_u64(String("analyzer_fp"), UInt64(0x5EA2C4))
    p.put_i64(String("generation"), Int64(42))
    var fp = p.hash_into(param_hash_string(kind, UInt64(kid)))
    var binding = ScanBinding(
        kind_id=kid,
        kind_name=kind^,
        name=String("docs"),
        params=p^,
        schema=_hit_schema(),
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        snapshot_policy=SNAPSHOT_LIVE,
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(binding^), _hit_schema()
    )


# =============================================================================
# THE THREE LEGS
# =============================================================================


def _schema_text(s: Schema) raises -> String:
    """The schema rendering LEG B and LEG D compare.

    ⚠ IT RENDERS THE WHOLE `Field`, NOT `name:type`. A rendering of only name,
    type and a `?` would make both legs BLIND to everything a `Field` carries
    beyond those three: nested CHILDREN
    (`child_names`/`child_type_ids`/`child_nullables`), `union_type_ids`, and
    per-column METADATA — which `_schema()` populates on `a` deliberately.

    That blindness is harmless only while every fixture is flat scalar columns
    and the three repeated slots are empty. It stops being harmless the
    moment a fixture carries a STRUCT: LEG D's whole job is to prove the Mojo
    decoder can read the PACKED form protoc emits for those repeated fields,
    and a comparison that cannot see the children would pass over a decoder
    that dropped every one of them. `Field.write_to` already prints
    children and metadata, so this is one call, and it strengthens every arm
    rather than only the nested one."""
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += ", "
        out += String(s.field_at_unchecked(i))
    out += "]"
    return out^


def _assert_frozen(name: String, var plan: LogicalPlan) raises:
    """LEG A + LEG B + LEG C for one corpus member."""
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)

    var bytes = plan_to_bytes(plan)

    # ★ PRINTED UNCONDITIONALLY, PASS OR FAIL. Regolding copies exactly this
    # block, so a NEW corpus member can be bootstrapped in one run — a regold
    # that only works from a red test cannot create a fixture that does not
    # exist yet.
    print("GOLDEN-BEGIN " + name)
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END " + name)

    # --- LEG C: non-trivial -------------------------------------------------
    # `WirePlanEnvelope{format_version:4}` alone is 2 bytes. A corpus of empty
    # plans would satisfy LEG A and LEG B and prove nothing.
    assert_true(
        len(bytes) > 16,
        name
        + ": LEG C — the encoder produced only "
        + String(len(bytes))
        + " bytes. That is at most an envelope with no plan in it, and a"
        + " fixture frozen at that size would freeze the encoder DOING"
        + " NOTHING.",
    )

    # --- LEG A: freeze ------------------------------------------------------
    var want = _from_hex(_read_fixture(name))
    assert_equal(
        len(bytes),
        len(want),
        name
        + ": LEG A — the encoder now produces "
        + String(len(bytes))
        + " bytes; the frozen fixture is "
        + String(len(want))
        + ". A byte-length change is a WIRE FORMAT change. If it was"
        + " deliberate, regold the fixture from the GOLDEN block above and"
        + " commit the diff; if it was not, the diff is the bug report.",
    )
    var first_diff = -1
    for i in range(len(want)):
        if bytes[i] != want[i]:
            first_diff = i
            break
    assert_equal(
        first_diff,
        -1,
        name
        + ": LEG A — the encoder's bytes DIVERGE from the frozen fixture at"
        + " offset "
        + String(first_diff)
        + " (encoder wrote "
        + String(Int(bytes[first_diff if first_diff >= 0 else 0]))
        + ", fixture holds "
        + String(Int(want[first_diff if first_diff >= 0 else 0]))
        + "). Same length, different content — this is the shape a field"
        + " RENUMBERING takes.",
    )

    # --- LEG B: the frozen bytes still MEAN this plan -----------------------
    # ⚠ DECODED FROM THE FIXTURE, NOT FROM `bytes`. Decoding what we just
    # encoded is the Mojo->Mojo round trip the other files already own; this
    # leg is about the bytes ON DISK, which is what the foreign reader gets.
    var back = plan_from_bytes(want^)
    assert_equal(
        String(back),
        text,
        name
        + ": LEG B — the CHECKED-IN bytes decode into a plan that renders"
        + " differently from the corpus plan of the same name. The fixture and"
        + " the corpus have drifted apart; LEG A cannot see this when both"
        + " moved together.",
    )
    assert_equal(
        String(back.structural_hash()),
        String(h),
        name
        + ": LEG B — the decoded plan's TEXT matches but its structural_hash"
        + " does not. The hash is FNV-1a over that text, so this can only mean"
        + " the render has stopped being the sole input to plan identity.",
    )
    assert_equal(
        _schema_text(back.output_schema),
        sch,
        name
        + ": LEG B — the decoded plan promises DIFFERENT output columns. The"
        + " render does not emit output_schema, so the text leg is blind to"
        + " this.",
    )

    # --- LEG D: ★ MOJO READS BYTES MOJO DID NOT WRITE -----------------------
    #
    # THE DIRECTION THE FORMAT RESTS ON. Legs A-C, and every round-trip test,
    # ask whether Mojo can read what Mojo wrote. But frontends in other
    # languages — TypeScript, SQL, Python — are PRODUCERS. If the Mojo decoder can
    # only read the Mojo encoder's dialect, "one language-agnostic
    # serializable plan" is false in the direction that matters most, and no
    # Mojo->Mojo test can see it.
    #
    # `<name>.canonical.hex` is protoc's OWN serialization of the structure
    # protoc decoded out of `<name>.hex`. It is not a re-spelling by us: it is
    # what the reference implementation emits, which is what a `protobuf`
    # Python client or a `prost` Rust client would emit.
    #
    # ⚠ AND IT IS NOT THE SAME BYTES. Over the whole corpus, the Mojo encoding
    # is 40-76% LARGER than protoc's:
    #
    #     scan 430/296 (+45%)   filter_over_scan 660/414 (+59%)
    #     join 1053/726 (+45%)  aggregate        529/365 (+45%)
    #
    # proto3 says a default-valued scalar MAY be omitted; protoc omits them and
    # this encoder writes them explicitly (`nullable: false`,
    # `decimal_precision: 0`, `tz: ""` are all physically on the wire in the
    # `.hex`). Both encodings are legal and a conforming reader accepts either
    # — which is exactly why no Mojo->Mojo test could notice, and exactly why
    # this leg exists.
    var canonical = _from_hex(_read_fixture(name + ".canonical"))
    assert_true(
        len(canonical) > 16,
        name
        + ": LEG D — `"
        + name
        + ".canonical.hex` is empty or a stub. Re-derive it with protoc from"
        + " `" + name + ".hex`.",
    )
    var foreign = plan_from_bytes(canonical^)
    assert_equal(
        String(foreign),
        text,
        name
        + ": ★ LEG D — the Mojo DECODER cannot reconstruct this plan from the"
        + " bytes the REFERENCE protobuf implementation produces for it. A"
        + " Python or TypeScript frontend that writes a plan writes THOSE bytes,"
        + " not ours. This is the sentence 'TypeScript, SQL, Python and Mojo share one"
        + " plan' being false in the producer direction, and no Mojo->Mojo"
        + " round trip can see it.",
    )
    assert_equal(
        String(foreign.structural_hash()),
        String(h),
        name
        + ": ★ LEG D — the plan decoded from the reference implementation's"
        + " bytes renders identically but hashes differently. The hash is the"
        + " engine's plan-compile cache key, so this would mis-key the cache"
        + " for every foreign-produced plan.",
    )
    assert_equal(
        _schema_text(foreign.output_schema),
        sch,
        name
        + ": ★ LEG D — the plan decoded from the reference implementation's"
        + " bytes promises DIFFERENT output columns. The render does not emit"
        + " output_schema, so the leg above is blind to this.",
    )
    _ = plan^


def test_scan_bytes_are_frozen() raises:
    _assert_frozen(String("scan"), _corpus_scan())


def test_filter_over_scan_bytes_are_frozen() raises:
    _assert_frozen(String("filter_over_scan"), _corpus_filter_over_scan())


def test_join_bytes_are_frozen() raises:
    _assert_frozen(String("join"), _corpus_join())


def test_aggregate_bytes_are_frozen() raises:
    _assert_frozen(String("aggregate"), _corpus_aggregate())


def test_sort_bytes_are_frozen() raises:
    _assert_frozen(String("sort"), _corpus_sort())


def test_topn_bytes_are_frozen() raises:
    _assert_frozen(String("topn"), _corpus_topn())


def test_limit_bytes_are_frozen() raises:
    _assert_frozen(String("limit"), _corpus_limit())


def test_distinct_bytes_are_frozen() raises:
    _assert_frozen(String("distinct"), _corpus_distinct())


def test_union_bytes_are_frozen() raises:
    _assert_frozen(String("union"), _corpus_union())


def test_window_bytes_are_frozen() raises:
    _assert_frozen(String("window"), _corpus_window())


def test_scan_nested_bytes_are_frozen() raises:
    _assert_frozen(String("scan_nested"), _corpus_scan_nested())


def test_project_exprs_bytes_are_frozen() raises:
    _assert_frozen(String("project_exprs"), _corpus_project_exprs())


def test_asof_join_bytes_are_frozen() raises:
    _assert_frozen(String("asof_join"), _corpus_asof_join())


def test_correlated_subquery_bytes_are_frozen() raises:
    _assert_frozen(
        String("correlated_subquery"), _corpus_correlated_subquery()
    )


def _assert_kind_leaf(name: String, kind: String, var plan: LogicalPlan) raises:
    """The EXPLAIN half: the plan renders its leaf through the binding's own
    `render()`, so the kind name must be visible in the text LEG B compares.
    A kind-agnostic render would let two kinds with equal params collide in
    every EXPLAIN a human reads."""
    var text = String(plan)
    assert_true(
        text.find(kind) >= 0,
        name + ": the plan text does not name its scan kind `" + kind
        + "`:\n" + text,
    )
    _assert_frozen(name, plan^)


def test_topic_live_bytes_are_frozen() raises:
    _assert_kind_leaf(
        String("topic_live"), String(_TOPIC_KIND), _corpus_topic_live()
    )


def test_index_pinned_bytes_are_frozen() raises:
    _assert_kind_leaf(
        String("index_pinned"), String(_INDEX_KIND), _corpus_index_pinned()
    )


def test_the_fixtures_are_not_all_the_same_bytes() raises:
    """★ THE CONTROL. N `assert_equal(actual, frozen)` legs are all satisfied
    by N fixtures holding the SAME bytes — if the encoder collapsed every plan
    to its envelope, LEG A would pass N times.

    So the fixtures must be pairwise DISTINCT, and that is asserted from the
    FILES rather than from the encoder: a bug that made the encoder emit one
    plan for all of them would otherwise be self-consistent.

    ⚠ EVERY NEW CORPUS MEMBER MUST BE ADDED TO THIS LIST. An arm that is
    frozen but not named here is EXEMPT from the only check that its bytes are
    not some other fixture's bytes — which is the one control a `.hex` freeze
    cannot supply for itself."""
    var names: List[String] = [
        String("scan"),
        String("filter_over_scan"),
        String("join"),
        String("aggregate"),
        String("sort"),
        String("topn"),
        String("limit"),
        String("distinct"),
        String("union"),
        String("window"),
        String("scan_nested"),
        String("project_exprs"),
        String("asof_join"),
        String("correlated_subquery"),
        String("topic_live"),
        String("index_pinned"),
    ]
    var seen = List[String]()
    for i in range(len(names)):
        seen.append(_read_fixture(names[i]))
    for i in range(len(seen)):
        for j in range(i + 1, len(seen)):
            assert_true(
                seen[i] != seen[j],
                "the frozen fixtures for `"
                + names[i]
                + "` and `"
                + names[j]
                + "` hold IDENTICAL bytes. Two different plans cannot have one"
                + " encoding; either the corpus builds the same plan twice or"
                + " the encoder is collapsing them.",
            )


def test_a_fixture_is_longer_than_the_plan_it_nests_inside() raises:
    """★ NESTING IS REAL, MEASURED FROM THE FILES.

    `filter_over_scan` CONTAINS `scan`, and `join` contains TWO scans. If the
    encoder were dropping child plans — the single most damaging silent defect
    a plan codec can have — the containing fixtures would not be strictly
    larger. This reads the checked-in files, so it holds even on a build where
    the encoder is not run at all."""
    var scan = _from_hex(_read_fixture(String("scan")))
    var filt = _from_hex(_read_fixture(String("filter_over_scan")))
    var join = _from_hex(_read_fixture(String("join")))
    assert_true(
        len(filt) > len(scan),
        "filter_over_scan ("
        + String(len(filt))
        + " bytes) is not larger than the scan it nests ("
        + String(len(scan))
        + "). A filter whose child was dropped would look exactly like this.",
    )
    # ⚠ `- 8` IS THE ENVELOPE, NOT A FUDGE FACTOR. A nested `WirePlan` carries
    # the leaf's node bytes but not `scan.hex`'s own `WirePlanEnvelope` header
    # (`format_version` + the outer tag and length). Two leaves must therefore
    # exceed twice the leaf MINUS that header, and `join` is 1063 against a
    # floor of 852.
    #
    # ⚠ WHAT THIS CANNOT SEE, said plainly so the next reader does not
    # over-trust it: a join that encoded `left` TWICE is the same SIZE as one
    # that encoded left and right, because the two leaves are near-identical in
    # length. Size catches a DROPPED child; only content catches a DUPLICATED
    # one, and that is LEG B (the render carries both binding names) and the
    # foreign gate's `.txtpb`, which prints `orders` and `lineitem` where a
    # duplicating encoder would print `orders` twice.
    assert_true(
        len(join) > 2 * (len(scan) - 8),
        "join ("
        + String(len(join))
        + " bytes) is too small to contain TWO scan leaves of "
        + String(len(scan))
        + " bytes. A join that DROPPED `right` is what this size looks like.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_scan_bytes_are_frozen]()
    suite.test[test_filter_over_scan_bytes_are_frozen]()
    suite.test[test_join_bytes_are_frozen]()
    suite.test[test_aggregate_bytes_are_frozen]()
    suite.test[test_sort_bytes_are_frozen]()
    suite.test[test_topn_bytes_are_frozen]()
    suite.test[test_limit_bytes_are_frozen]()
    suite.test[test_distinct_bytes_are_frozen]()
    suite.test[test_union_bytes_are_frozen]()
    suite.test[test_window_bytes_are_frozen]()
    suite.test[test_scan_nested_bytes_are_frozen]()
    suite.test[test_project_exprs_bytes_are_frozen]()
    suite.test[test_asof_join_bytes_are_frozen]()
    suite.test[test_correlated_subquery_bytes_are_frozen]()
    suite.test[test_topic_live_bytes_are_frozen]()
    suite.test[test_index_pinned_bytes_are_frozen]()
    suite.test[test_the_fixtures_are_not_all_the_same_bytes]()
    suite.test[test_a_fixture_is_longer_than_the_plan_it_nests_inside]()
    suite^.run()
