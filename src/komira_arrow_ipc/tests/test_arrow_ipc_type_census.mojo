# =============================================================================
# test_arrow_ipc_type_census.mojo — ★★ THE TWO IPC DISPATCHERS DO NOT COVER THE
#                                      SAME TYPES, AND THIS TEST SAYS WHICH.
# =============================================================================
#
# `komira_arrow_ipc/ipc_encoder_dispatch.mojo` holds TWO independent
# type cascades and they disagree:
#
#   BODY    `encode_column`               — which columns' BUFFERS can be written
#   SCHEMA  `_write_type_for_arrow_type`  — which columns' FIELDS can be declared
#
# A type needs BOTH to leave this process. The intersection is the real
# capability, and this file is where a test can contradict a claim about it.
#
# ============================ WHAT THIS TEST IS FOR ==========================
#
# ★ IT IS RED IN BOTH DIRECTIONS, AND THE SECOND DIRECTION IS THE POINT.
#   * a type that STOPS encoding      -> RED (the classic)
#   * a type that STARTS encoding     -> RED on GOOD NEWS
# The second is what keeps the numbers in `ipc_encoder_dispatch.mojo`'s header
# TRUE. A gate that only fires when a claim is too strong lets the tree improve
# past its own scoreboard in silence.
#
# ⚠ WHY A ROUND-TRIP OR FAN-OUT TEST DOES NOT COVER THIS:
#
#   * a body round-trip test never touches `encode_schema_message`, so the
#     binding leg is untested by it.
#   * `test_arrow_ipc_flatbuf_type_arms_fanout.mojo` exercises low-level
#     writers the schema cascade does not necessarily REACH. A fan-out over
#     unreachable writers is the vacuous-gate class: every arm passes and no
#     column can use any of them.
#
# ================== HOW EACH LEG IS MEASURED (and why it is safe) ============
#
# BODY. A LENGTH-0 probe column carrying the tag under test, built through
# `Column.from_primitive_with_arrow_type` — the same factory the engine uses for
# the storage-shaped-but-logically-distinct types. Every arm is then reached
# with zero rows, so the verdict is read off the ERROR, not off the data:
#
#     "... not yet wired in the IPC column encoder"  -> NO ARM (the catch-all)
#     "View-type encode ..."          -> REFUSED BY NAME
#     anything else, incl. success    -> AN ARM RAN
#
# ⚠ THE PROBE CANNOT CRASH, AND THAT WAS CHECKED ARM BY ARM RATHER THAN HOPED.
# `child_at(0)` is the one unguarded index in the dispatch driver, and every arm
# that precedes it (`encode_list` / `encode_large_list` / `encode_map` /
# `encode_fixed_size_list`) RAISES on `num_children() != 1` before the driver
# recurses; STRUCT and both UNIONs loop over `num_children()` and see zero. The
# var-len and nested-offsets emitters raise on a missing `_offsets` buffer.
#
# SCHEMA. `encode_schema_message` over a ONE-FIELD schema — the PUBLIC entry
# point, not the private cascade, so this exercises the binding
# (`write_field` + `DictionaryEncoding`) and not merely the type table.
#
# ================= ★ WHY TWO PROBES ARE ENOUGH FOR THREE PATHS ===============
#
# `encode_column` is the SINGLE body oracle: the staged uncompressed path, the
# two-pass STREAMING path (dry-run and wet-run) and the COMPRESSED path
# (`ipc_body_compression.mojo`) all dispatch through it. None of them carries
# a per-`ArrowType` refusal of its own — the compressed path's raises are
# about zero columns, row-count parity and buffer sizes. So a per-type
# verdict taken here is a verdict for all three.
#
# ⚠ AND THE CONSTRUCTIBLE SET IS NOT NARROWER THAN THE ENCODABLE ONE, which was
# an open question worth settling because a YES would have made the 36 an
# overclaim. `ipc_encoder_dispatch.mojo`'s view-type raise says *"no
# `Column.from_*_view` factory exists"* — that is true of the four `*_VIEW`
# layouts SPECIFICALLY, and they are exactly the four refused by name. Every
# other covered type has a factory: `Column.from_primitive_with_arrow_type`
# stamps an arbitrary tag on a primitive-backed column (the engine's own route
# for TIME32/64_*, DURATION_*, INTERVAL_YEAR_MONTH / _DAY_TIME), plus
# `from_union`, `from_interval_mdn`, `from_decimal128` / `_256`,
# `from_fixed_size_binary` / `_list`, `from_list` / `_struct` / `_map`. On the
# schema side `Field(name, arrow_type, nullable)` accepts ANY `ArrowType` at
# all, which is also why this file can probe ids 50-255.
#
# ⚠ AND A REFUSAL MUST NAME THE TYPE. Both legs assert that the error carries
# the numeric type id. "encodable OR refused-with-a-named-reason" is the claim;
# a bare raise satisfies neither half and is reported as its own verdict.
#
# ================== ★ THE CATCH-ALL IS REACHABLE, AND THAT IS PINNED =========
#
# `ArrowType.__init__` VALIDATES NOTHING, so ids 50-255 are constructible and
# land in the body catch-all. The pin below keeps that catch-all from being
# mistaken for dead code.
#
# ============== ⛔ AND THAT SAME FACT MADE THE ID-SPACE GUARD VACUOUS =========
#
# Because `__init__` validates nothing, an assertion such as
#
#     assert_equal(Int(ArrowType(ARROW_TYPE_ID_MAX + 1).type_id), 50)
#
# is `50 == 50`: `ARROW_TYPE_ID_MAX` is 49 and is declared IN THIS FILE, and
# the constructor stores the byte and hands it straight back, so NO state of
# the production tree could move it. The "50 ArrowType constants" claim
# (restated in this header and in `ipc_encoder_dispatch.mojo`'s header) needs
# a falsifier against the set GROWING — every census below iterates
# `range(ARROW_TYPE_COUNT)`, so a 51st constant would otherwise be measured by
# nothing. A fake `comptime FAKE51 = ArrowType(50)` added to
# `arrow_types.mojo`, with its `write_to` arm, leaves such a tautology GREEN.
#
# The id space is guarded by TWO oracles, which fail on DIFFERENT mistakes and
# are deliberately not merged into one:
#
#   test_declared_arrow_type_constants_are_50_contiguous_ids
#       reads the SHIPPED `arrow_types.mojo` (declared test data, opened from
#       the test's data directory) and counts the `comptime … = ArrowType(<n>)`
#       bindings: COUNT / CEILING / COVERAGE / UNIQUENESS. Catches a constant
#       added WITHOUT a `write_to` arm.
#   test_every_declared_id_is_named_and_no_id_past_the_max_is
#       every declared id must RENDER as a name, and id 50 must still render as
#       `unknown(50)`. Needs no test data, so the id space stays guarded from
#       one side even if the staging is ever dropped. Catches a `write_to` arm
#       added WITHOUT a constant.
#
# ========================= ★ AND THE TIMEZONE, AT THE BYTES ==================
#
# `test_timestamp_timezone_*` guards the TIMESTAMP arms: an arm that writes the
# literal `""` sends a tz-carrying column to every foreign consumer TZ-NAIVE.
# It asserts on the RAW FRAME BYTES — no decoder is involved — because a
# Mojo-decodes-Mojo round-trip is exactly the symmetric shape that agrees with
# such a bug. A pyarrow read of the shipped binary's output is the FOREIGN
# half; this is the unit half.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.ipc_body_sink import AlignedBufferBodySink
from komira_arrow_ipc.ipc_encoder_dispatch import (
    encode_column,
    encode_schema_message,
    encode_footer_message,
)
from komira_arrow_ipc.ipc_flatbuf import Block, BufferDescriptor, FieldNode
from komira_buffer.heap_region import HeapRegion


# ---------------------------------------------------------------------------
# THE STATED SETS. Everything else in this file is derived from the tree.
# ---------------------------------------------------------------------------

# `ArrowType` ids run 0 (NULL) .. 49 (LARGE_LIST_VIEW), contiguous. Asserted below
# against the named constants rather than trusted.
comptime ARROW_TYPE_ID_MAX: Int = 49
comptime ARROW_TYPE_COUNT: Int = ARROW_TYPE_ID_MAX + 1

# Verdicts, shared by both legs.
comptime V_ENCODABLE: Int = 0  # an arm ran / a Field was written
comptime V_REFUSED_NAMED: Int = 1  # refused, and the message names the id
comptime V_ABSENT_NAMED: Int = 2  # fell through to the catch-all, id named
comptime V_UNNAMED: Int = 3  # refused WITHOUT naming the id — a contract bug


def _schema_writable_ids() -> List[Int]:
    """The 38 ids `_write_type_for_arrow_type` is STATED to write.

    Hand-written on purpose: this is the CLAIM. The test derives the same set
    from the encoder and compares, so an edit to either side is red.

    DECIMAL128 (18) and DECIMAL256 (29) are the two ids on this list whose
    Field carries PARAMETERS the type table cannot default. See
    `_probe_field` — a decimal is writable IFF its Field states a precision,
    and a Field that does not state one is still REFUSED. Both halves are
    pinned below, because a "wire the arm" change that invented a precision
    would pass the first half alone.
    """
    var out = List[Int]()
    out.append(0)  # NULL
    out.append(1)  # BOOL
    for i in range(2, 10):  # INT8..UINT64
        out.append(i)
    for i in range(10, 13):  # FLOAT16/32/64
        out.append(i)
    out.append(13)  # STRING
    out.append(14)  # BINARY
    out.append(15)  # DATE32
    out.append(16)  # DATE64
    out.append(17)  # TIMESTAMP (legacy us)
    out.append(19)  # DICTIONARY
    for i in range(22, 26):  # TIMESTAMP_S/MS/US/NS
        out.append(i)
    out.append(26)  # LARGE_STRING
    out.append(27)  # LARGE_BINARY
    for i in range(30, 34):  # TIME32_S/MS, TIME64_US/NS
        out.append(i)
    for i in range(34, 38):  # DURATION_S/MS/US/NS
        out.append(i)
    for i in range(38, 41):  # INTERVAL_YM / DT / MDN
        out.append(i)
    out.append(18)  # DECIMAL128 — parameterised; see `_probe_field`
    out.append(29)  # DECIMAL256 — parameterised; see `_probe_field`
    return out^


def _body_view_refused_ids() -> List[Int]:
    """The 4 ids `encode_column` refuses BY NAME (the *_VIEW layouts)."""
    var out = List[Int]()
    out.append(46)  # BINARY_VIEW
    out.append(47)  # UTF8_VIEW
    out.append(48)  # LIST_VIEW
    out.append(49)  # LARGE_LIST_VIEW
    return out^


def _body_absent_ids() -> List[Int]:
    """The declared ids with NO arm in `encode_column` — the catch-all's
    population inside the named space. None today: every declared id has an
    arm or a refusal by name, and only ids past the space reach the catch-all
    (`test_catch_all_is_reachable_ids_50_to_255_are_constructible`).
    """
    return List[Int]()


def _body_encodable_only_ids() -> List[Int]:
    """The 8 that encode a BODY and have NO Field.

    A column of any of these writes its buffers and then cannot be declared, so
    the STREAM refuses. All eight are NESTED or FIXED-WIDTH-BINARY shapes,
    whose Fields need CHILDREN rather than two integers. (The decimals are
    not here: without a DECIMAL Field, `plan_exec --format ipc` over a decimal
    result answers `PLAN_ENDPOINT_UNSUPPORTED_ARROW_TYPE(16)` with NO STREAM
    AT ALL, so a decimal column cannot even be SELECTED.)
    """
    var out = List[Int]()
    out.append(20)  # LIST
    out.append(21)  # STRUCT
    out.append(28)  # MAP
    out.append(41)  # UNION_SPARSE
    out.append(42)  # UNION_DENSE
    out.append(43)  # LARGE_LIST
    out.append(44)  # FIXED_SIZE_BINARY
    out.append(45)  # FIXED_SIZE_LIST
    return out^


def _contains(haystack: List[Int], needle: Int) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


# ---------------------------------------------------------------------------
# THE TWO PROBES
# ---------------------------------------------------------------------------


def _body_verdict(type_id: Int) raises -> Int:
    """Ask `encode_column` whether it has an arm for `type_id`.

    Length-0 probe column; see the header for why every arm is reachable
    without a crash. The verdict is read off the DISPATCH DRIVER's own two
    refusal messages, so an arm that runs and then complains about the probe's
    empty buffers still counts as PRESENT — which is the question being asked.
    """
    var arr = PrimitiveArray[DType.int64].allocate(0)
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        arr^, ArrowType(type_id)
    )
    var sink = AlignedBufferBodySink(64)
    var buffers = List[BufferDescriptor]()
    var nodes = List[FieldNode]()
    try:
        _ = encode_column[AlignedBufferBodySink](col, sink, 0, buffers, nodes)
        return V_ENCODABLE
    except e:
        var msg = String(e)
        var names_it = msg.find("ArrowType " + String(type_id)) >= 0
        if msg.find("not yet wired in the IPC column encoder") >= 0:
            return V_ABSENT_NAMED if names_it else V_UNNAMED
        if msg.find("View-type encode") >= 0:
            return V_REFUSED_NAMED if names_it else V_UNNAMED
        # An arm ran. It raised about the probe's missing offsets / child /
        # inner-size, which is a statement about THIS column and not about the
        # type's coverage.
        return V_ENCODABLE


def _probe_field(type_id: Int) raises -> Field:
    """The one-field probe the schema leg is measured over.

    ⭐ NOT ALWAYS THE BARE 3-ARG `Field`, AND THE EXCEPTION IS THE POINT. A
    Field is the only place a per-field PARAMETER can live, and for two ids the
    Arrow type table has no defensible default for one:

        DECIMAL128 / DECIMAL256 — `Decimal{precision, scale, bitWidth}`. Arrow
        has NO default precision; `pa.decimal128()` takes it positionally. A
        bare `Field("c", ArrowType.DECIMAL128, True)` carries precision 0,
        which is not a decimal at all.

    So for those two the probe is the FACTORY (`Field.decimal128`), which is
    what the parquet reader calls and therefore
    what a real result column carries. Probing them bare would measure "can the
    encoder write a MALFORMED decimal", answer "no", and report that as "the
    engine cannot write decimals" — the same sentence for two different facts.

    ⚠ THE BARE-FIELD CASE IS NOT DROPPED, IT IS ITS OWN TEST:
    `test_decimal_field_with_no_precision_is_refused_not_defaulted` pins that a
    precision-less decimal is still REFUSED, so the census's move from REFUSED
    to ENCODABLE here cannot be bought by defaulting a precision.
    """
    if type_id == Int(ArrowType.DECIMAL128.type_id):
        return Field.decimal128("c", 10, 4, True)
    if type_id == Int(ArrowType.DECIMAL256.type_id):
        return Field.decimal256("c", 40, 4, True)
    return Field("c", ArrowType(type_id), True)


def _schema_verdict(type_id: Int) raises -> Int:
    """Ask `encode_schema_message` whether a one-field schema of `type_id`
    produces a Schema frame.

    The PUBLIC entry, so the `write_field` binding is on the path too — that
    binding is what a body round-trip test never touches.
    """
    var schema = Schema.from_fields_1(_probe_field(type_id))
    try:
        var frame = encode_schema_message(schema)
        var n = frame.len()
        _ = frame^
        # A zero-byte frame is a silent failure, not a success.
        return V_ENCODABLE if n > 0 else V_UNNAMED
    except e:
        var msg = String(e)
        if msg.find("ArrowType type_id " + String(type_id)) >= 0:
            return V_REFUSED_NAMED
        return V_UNNAMED


def _frame_contains(
    ref frame: SharedAlignedBuffer[HeapRegion], needle: String
) raises -> Bool:
    """Does `frame` hold `needle`'s bytes, anywhere? No decoder involved."""
    var n = frame.len()
    var nb = needle.as_bytes()
    var m = len(nb)
    if m == 0 or m > n:
        return False
    for i in range(n - m + 1):
        var hit = True
        for j in range(m):
            if frame.read_u8_at(i + j) != nb[j]:
                hit = False
                break
        if hit:
            return True
    return False


# ---------------------------------------------------------------------------
# THE CENSUS
# ---------------------------------------------------------------------------


def test_arrow_type_id_space_is_contiguous_0_to_49() raises:
    """The enumeration this whole file iterates. If a constant is added
    without extending `ARROW_TYPE_ID_MAX`, every count below would silently be
    taken over a SHORT range — so the range is asserted first, against the
    named constants at both ends and at the two seams that moved historically.

    ⛔ A GUARD OF THE FORM

        assert_equal(Int(ArrowType(ARROW_TYPE_ID_MAX + 1).type_id), 50)

    IS A TAUTOLOGY. `ARROW_TYPE_ID_MAX` is 49 and is declared IN THIS FILE,
    so that is `ArrowType(50).type_id == 50`. `ArrowType.__init__` validates
    nothing — it stores the byte and hands it back — so the expression is
    `50 == 50` for every possible state of the production tree. Adding a 51st
    constant could not move it. Neither could deleting forty-nine.

    The claim it would defend is load-bearing: "50 ArrowType constants" is
    restated in this module's header and in `ipc_encoder_dispatch.mojo`'s
    header, and every census below iterates `range(ARROW_TYPE_COUNT)`, so a
    51st constant would be counted by NOTHING.

    The subject is the DECLARATION SITE — see
    `test_declared_arrow_type_constants_are_50_contiguous_ids`, which reads the
    real `arrow_types.mojo` and counts what it declares. This function keeps
    the cheap end-and-seam pins, which are not tautologies (they read named
    constants the production file must actually define)."""
    assert_equal(Int(ArrowType.NULL.type_id), 0)
    # The two ids most recently appended; a new constant lands after these.
    assert_equal(Int(ArrowType.LARGE_LIST_VIEW.type_id), ARROW_TYPE_ID_MAX)
    assert_equal(Int(ArrowType.FIXED_SIZE_LIST.type_id), 45)


def _declared_arrow_type_ids(src: String) raises -> List[Int]:
    """Every id declared as `comptime <NAME> = ArrowType(<digits>)` in `src`,
    in source order.

    ⚠ THE `comptime` PREFIX IS REQUIRED, not decoration: `ArrowType(` appears
    all over that file inside `from_dtype`, `parse_format_string` and friends,
    and those are CONVERSIONS, not declarations. Only a `comptime` binding adds
    a member to the id space this file's censuses iterate.
    """
    var out = List[Int]()
    var needle = String("= ArrowType(")
    var lines = src.split("\n")
    for li in range(len(lines)):
        var raw = String(lines[li])
        # Strip leading whitespace — the constants are indented inside `struct`.
        var b = raw.as_bytes()
        var s = 0
        while s < len(b) and (b[s] == 32 or b[s] == 9):
            s += 1
        if s >= len(b):
            continue
        var line = String(raw[byte=s:])
        if not line.startswith(String("comptime ")):
            continue
        var at = line.find(needle)
        if at < 0:
            continue
        var i = at + needle.byte_length()
        var lb = line.as_bytes()
        var val = 0
        var digits = 0
        while i < len(lb) and lb[i] >= 48 and lb[i] <= 57:
            val = val * 10 + Int(lb[i]) - 48
            digits += 1
            i += 1
        # `ArrowType(SOMETHING_ELSE)` — a comptime alias built from another
        # expression — is not a numeric declaration and is reported, not
        # silently skipped, by leaving it out of the returned ids: the COUNT
        # assertion below is what notices.
        if digits > 0 and i < len(lb) and lb[i] == UInt8(ord(")")):
            out.append(val)
    return out^


comptime _ARROW_TYPES_SRC: StaticString = (
    "src/komira_arrow/arrow_types.mojo"
)

comptime _DECLARED_ARROW_TYPE_CONSTANTS: Int = 50
"""★ THE HEADLINE NUMBER, and the one the documentation restates.

`ipc_encoder_dispatch.mojo`'s header and this file's header say 50. This is
the only place a test can contradict them.

⚠ CHANGE IT ONLY WITH THE DECLARATION. Editing this literal to buy a green is
the failure mode — a 51st `ArrowType` constant means `_body_absent_ids`, the
schema-writable set and all four census totals in this file must be re-derived,
and the point of this pin is to make that re-derivation MANDATORY rather than
optional. It is not a config value; it is a claim about the tree."""


def test_declared_arrow_type_constants_are_50_contiguous_ids() raises:
    """★ THE DECLARATION-SITE ORACLE.

    Reads the REAL `arrow_types.mojo` (declared test data, opened from the
    test's data directory) and counts the `comptime … = ArrowType(<n>)` bindings.
    A fixture restating the ids would answer a question about the fixture; the
    shipped source is the only text whose growth this test must notice.

    FOUR assertions. THREE of them are independent; the fourth is a cheap
    restatement:

      CEILING      any declared id exceeds ARROW_TYPE_ID_MAX -> RED, naming it
      COVERAGE     every id in 0..MAX is declared            -> RED (a deletion)
      UNIQUENESS   no id is declared twice                   -> RED (an alias
                   silently shadowing a real member)
      COUNT        a 51st constant appears anywhere          -> RED, first, with
                   the message that says what to re-derive

    ⚠ COUNT IS IMPLIED BY THE OTHER THREE AND IS KEPT FOR ITS MESSAGE, NOT FOR
    ITS COVERAGE. `seen` is sized `ARROW_TYPE_COUNT` and every declared id is
    counted into it, so `sum(seen) == len(ids)` always. CEILING then confines
    every id to `0..MAX`, and the `seen[v] == 1` loop pins each of those 50
    slots to exactly one declaration — so `len(ids) == 50` FOLLOWS, and no state
    of `arrow_types.mojo` can fail COUNT while passing the other three. Its
    value is that it fires FIRST and its message names the re-derivation the
    other three do not mention.

    ⚠ WHAT IS STILL TRUE, AND IS THE REASON CEILING IS A SEPARATE ASSERTION:
    deleting one constant and adding another at id 50 keeps the count at 50
    while moving the space — and every `range(ARROW_TYPE_COUNT)` loop below
    would then skip the new member and iterate a hole. COUNT cannot see that
    edit at all; CEILING is what catches it, and it is the one that fires on the
    ordinary "append a new type" edit once COUNT is out of the way.
    """
    var src: String
    with open(String(_ARROW_TYPES_SRC), "r") as f:
        src = f.read()
    assert_true(
        src.byte_length() > 0,
        String(
            "arrow_types.mojo was staged EMPTY. This test's whole subject is"
            " the shipped declaration text; an empty read would make every"
            " assertion below vacuous, so it is refused here rather than"
            " passing four times over nothing."
        ),
    )

    var ids = _declared_arrow_type_ids(src)

    # --- COUNT -------------------------------------------------------------
    assert_equal(
        len(ids),
        _DECLARED_ARROW_TYPE_CONSTANTS,
        String(
            "arrow_types.mojo declares "
            + String(len(ids))
            + " `comptime … = ArrowType(<n>)` constants; this file, "
            + "and ipc_encoder_dispatch.mojo's header both claim "
            + String(_DECLARED_ARROW_TYPE_CONSTANTS)
            + ". ⚠ DO NOT EDIT THE LITERAL TO MATCH. Every census in this file"
            " iterates range(ARROW_TYPE_COUNT); a constant added outside that"
            " range is measured by nothing while the documentation keeps stating"
            " the old number. Re-derive _body_absent_ids, the"
            " schema-writable set and all four totals, then move BOTH."
        ),
    )

    # --- CEILING + UNIQUENESS + COVERAGE -----------------------------------
    var seen = List[Int]()
    for _ in range(ARROW_TYPE_COUNT):
        seen.append(0)
    for k in range(len(ids)):
        var v = ids[k]
        assert_true(
            v >= 0 and v <= ARROW_TYPE_ID_MAX,
            String(
                "arrow_types.mojo declares a constant with id "
                + String(v)
                + ", which is outside 0.."
                + String(ARROW_TYPE_ID_MAX)
                + ". ⚠ THIS IS THE 'RED ON GOOD NEWS' DIRECTION: the id space"
                " GREW and every count in this file was taken over the SHORT"
                " range. Raise ARROW_TYPE_ID_MAX, then re-derive the censuses."
            ),
        )
        seen[v] = seen[v] + 1

    for v in range(ARROW_TYPE_COUNT):
        assert_equal(
            seen[v],
            1,
            String(
                "ArrowType id "
                + String(v)
                + " is declared "
                + String(seen[v])
                + " times in arrow_types.mojo; the id space must be a"
                " bijection over 0.."
                + String(ARROW_TYPE_ID_MAX)
                + ". 0 means a member was deleted and the censuses now iterate"
                " a hole; 2 means an alias is shadowing a real member and one"
                " of the two is unreachable by name."
            ),
        )


def test_every_declared_id_is_named_and_no_id_past_the_max_is() raises:
    """The SECOND, independent oracle — production-side, no test data.

    `ArrowType.write_to` is a 50-arm cascade ending in `unknown(<id>)`. So the
    id space has a witness the test can read without parsing anything: a
    DECLARED id renders as a name, an UNDECLARED one renders as `unknown(n)`.

    ⚠ IT IS NOT A DUPLICATE OF THE DECLARATION COUNT, and the difference is the
    reason both exist. The declaration oracle sees a constant added WITHOUT a
    `write_to` arm (the count moves, the cascade does not). This one sees a
    `write_to` arm added WITHOUT a constant, and it needs no test data at
    all — so if the source staging is ever dropped, the id space is still
    guarded from one side rather than from neither.
    """
    var unknown = String("unknown(")
    for type_id in range(ARROW_TYPE_COUNT):
        var rendered = String(ArrowType(type_id))
        assert_false(
            rendered.startswith(unknown),
            String(
                "ArrowType.write_to renders declared id "
                + String(type_id)
                + " as '"
                + rendered
                + "' — it fell through to the catch-all, so the cascade has no"
                " arm for a member the id space contains. Every declared id"
                " must have a name; an unnamed one reaches every error message"
                " and every debug print as a bare integer."
            ),
        )

    # ★ RED ON GOOD NEWS, and this time it can actually fire. The first id past
    # the space must still be anonymous. Give id 50 a `write_to` arm — which is
    # what adding a 51st ArrowType constant properly entails — and this is RED.
    var past = String(ArrowType(ARROW_TYPE_ID_MAX + 1))
    assert_equal(
        past,
        String("unknown(") + String(ARROW_TYPE_ID_MAX + 1) + String(")"),
        String(
            "ArrowType id "
            + String(ARROW_TYPE_ID_MAX + 1)
            + " renders as '"
            + past
            + "', not as the catch-all. The id space has GROWN past"
            " ARROW_TYPE_ID_MAX and every census in this file is being taken"
            " over a short range."
        ),
    )


def test_body_leg_census_46_arms_4_named_refusals_0_absent() raises:
    """`encode_column`'s dispatch table, id by id.

    46 arms / 4 refused-by-name / 0 absent. Every id is asserted individually,
    so a change reports WHICH type moved and in which direction — a bare count
    would report only that something did.
    """
    var views = _body_view_refused_ids()
    var absent = _body_absent_ids()
    var n_arm = 0
    var n_named_refusal = 0
    var n_absent = 0

    for type_id in range(ARROW_TYPE_COUNT):
        var got = _body_verdict(type_id)
        assert_true(
            got != V_UNNAMED,
            String(
                "encode_column refused ArrowType "
                + String(type_id)
                + " without naming it. 'encodable OR refused with a NAMED"
                " reason' is the contract; a bare raise is neither, and a"
                " caller cannot re-code it (plan_exec's"
                " UNSUPPORTED_ARROW_TYPE(16) door reads the message)."
            ),
        )
        if _contains(views, type_id):
            assert_equal(
                got,
                V_REFUSED_NAMED,
                String(
                    "ArrowType "
                    + String(type_id)
                    + " is a *_VIEW layout: it must be refused BY NAME"
                    " ('View-type encode ...'), not silently absent"
                    " and not encoded. ⚠ IF IT NOW ENCODES, THIS IS GOOD NEWS"
                    " AND THE COUNTS IN ipc_encoder_dispatch.mojo's header"
                    " ARE STALE — move it here, not around this"
                    " assertion."
                ),
            )
            n_named_refusal += 1
        elif _contains(absent, type_id):
            assert_equal(
                got,
                V_ABSENT_NAMED,
                String(
                    "ArrowType "
                    + String(type_id)
                    + " is expected to have NO arm in encode_column and to"
                    " land in the catch-all. It did not."
                ),
            )
            n_absent += 1
        else:
            assert_equal(
                got,
                V_ENCODABLE,
                String(
                    "ArrowType "
                    + String(type_id)
                    + " has no arm in encode_column any more — a column of"
                    " this type can no longer be written into a RecordBatch"
                    " body."
                ),
            )
            n_arm += 1

    assert_equal(n_arm, 46)
    assert_equal(n_named_refusal, 4)
    assert_equal(n_absent, 0)
    assert_equal(n_arm + n_named_refusal + n_absent, ARROW_TYPE_COUNT)


def test_schema_leg_census_38_writable_12_refused() raises:
    """`encode_schema_message`'s type cascade, id by id. 38 / 12.

    The two DECIMAL ids are writable: see `_probe_field` for why they are
    probed through `Field.decimal128` / `.decimal256` rather than the bare
    3-arg ctor, and
    `test_decimal_field_with_no_precision_is_refused_not_defaulted` for the
    half of the claim that keeps this honest.
    """
    var writable = _schema_writable_ids()
    assert_equal(len(writable), 38)

    var n_ok = 0
    var n_refused = 0
    for type_id in range(ARROW_TYPE_COUNT):
        var got = _schema_verdict(type_id)
        assert_true(
            got != V_UNNAMED,
            String(
                "encode_schema_message refused ArrowType "
                + String(type_id)
                + " without naming the type id (or produced a ZERO-byte"
                " frame). ⚠ The plan-exec IPC door's stderr is matched on"
                " `_write_type_for_arrow_type` precisely so a blanket"
                " re-code cannot pass as a narrow one; an unnamed refusal"
                " breaks that chain at the source."
            ),
        )
        if _contains(writable, type_id):
            assert_equal(
                got,
                V_ENCODABLE,
                String(
                    "ArrowType "
                    + String(type_id)
                    + " can no longer be DECLARED in an Arrow IPC Schema"
                    " message, so no column of it can leave this process."
                ),
            )
            n_ok += 1
        else:
            assert_equal(
                got,
                V_REFUSED_NAMED,
                String(
                    "ArrowType "
                    + String(type_id)
                    + " is now writable by the SCHEMA encoder. ⚠ RED ON GOOD"
                    " NEWS — add it to `_schema_writable_ids`, drop it from"
                    " `_body_encodable_only_ids` if it is there, and"
                    " re-derive the 38 in ipc_encoder_dispatch.mojo's"
                    " header."
                ),
            )
            n_refused += 1

    assert_equal(n_ok, 38)
    assert_equal(n_refused, 12)
    assert_equal(n_ok + n_refused, ARROW_TYPE_COUNT)


def test_stream_writable_is_the_intersection_and_it_is_38() raises:
    """★ THE NUMBER THAT MATTERS. A type leaves this process only if BOTH legs
    take it; the intersection is the capability, and neither leg alone is.
    """
    var n_both = 0
    var n_body_only = 0
    var n_schema_only = 0
    var expect_body_only = _body_encodable_only_ids()

    for type_id in range(ARROW_TYPE_COUNT):
        var body_ok = _body_verdict(type_id) == V_ENCODABLE
        var schema_ok = _schema_verdict(type_id) == V_ENCODABLE
        if body_ok and schema_ok:
            n_both += 1
        elif body_ok:
            n_body_only += 1
            assert_true(
                _contains(expect_body_only, type_id),
                String(
                    "ArrowType "
                    + String(type_id)
                    + " encodes a BODY but has no FIELD, and it is not in the"
                    " stated eight. Either an arm was added to encode_column"
                    " without one in _write_type_for_arrow_type, or the list"
                    " is stale."
                ),
            )
        elif schema_ok:
            n_schema_only += 1

    assert_equal(
        n_schema_only,
        0,
        String(
            "★ A type is DECLARABLE in a Schema message but its column cannot"
            " be written into a RecordBatch. That produces a stream a foreign"
            " reader OPENS and then dies inside — the failure mode"
            " plan_exec_main._write_ipc_stream is structured to avoid (it"
            " encodes every frame before writing any). This direction must"
            " stay empty."
        ),
    )
    assert_equal(n_body_only, 8)
    assert_equal(len(expect_body_only), 8)
    assert_equal(n_both, 38)
    # And the three add up over the whole space, with the 4 the body refuses.
    assert_equal(n_both + n_body_only, 46)


def test_catch_all_is_reachable_ids_50_to_255_are_constructible() raises:
    """⚠ THE CATCH-ALL IS NOT DEAD CODE — an earlier measurement said it was.

    `ArrowType.__init__` validates nothing, so any UInt8 is an ArrowType. Ids
    past the named space reach the body catch-all and the schema refusal, both
    naming the id. This is also the wire-safety statement the plan codec's
    `_arrow_type_from_wire` exists to make: an unknown id must REFUSE, never be
    narrowed into a neighbouring type's layout.
    """
    var probes = List[Int]()
    probes.append(50)  # one past the named space
    probes.append(99)
    probes.append(255)  # UInt8 max
    for i in range(len(probes)):
        var type_id = probes[i]
        assert_equal(
            _body_verdict(type_id),
            V_ABSENT_NAMED,
            String(
                "ArrowType "
                + String(type_id)
                + " must reach encode_column's catch-all and be named there."
            ),
        )
        assert_equal(
            _schema_verdict(type_id),
            V_REFUSED_NAMED,
            String(
                "ArrowType "
                + String(type_id)
                + " must be refused by the Schema encoder, by name."
            ),
        )


# ---------------------------------------------------------------------------
# ★ THE TIMEZONE
# ---------------------------------------------------------------------------


def _timestamp_schema(arrow_type: ArrowType, tz: String) raises -> Schema:
    return Schema.from_fields_1(Field.timestamp("t", arrow_type, tz, True))


def test_timestamp_timezone_reaches_the_schema_frame_all_five_slots() raises:
    """★ THE FIX FOR A WRONG-ANSWER CLASS, ASSERTED AT THE BYTES.

    `_write_type_for_arrow_type` must write the Field's own tz in all four
    TIMESTAMP arms. Passing the literal `""` (a function that takes an
    `ArrowType` and NO field index has no way to ask which field's tz to
    write) while `Schema.field_tz` holds one — and the parquet reader sets
    `tz="UTC"` for `isAdjustedToUTC` — sends a tz-carrying column to every
    foreign consumer NAIVE: an instant silently re-read as wall-clock.

    ⚠ ASSERTED ON THE RAW FRAME BYTES, NOT THROUGH A DECODER. A Mojo encoder
    and a Mojo decoder that share the mistake agree with each other — the
    symmetric-error shape that a green IPC round-trip suite cannot see.
    `America/New_York` is 16
    bytes that cannot appear in a flatbuffer for any other reason.

    FIVE slots, FOUR arms: TIMESTAMP (legacy) shares the microsecond arm with
    TIMESTAMP_US, and a fix that touched three arms of four must be red.
    """
    var slots = List[ArrowType]()
    slots.append(ArrowType.TIMESTAMP)
    slots.append(ArrowType.TIMESTAMP_S)
    slots.append(ArrowType.TIMESTAMP_MS)
    slots.append(ArrowType.TIMESTAMP_US)
    slots.append(ArrowType.TIMESTAMP_NS)

    for i in range(len(slots)):
        var t = slots[i]
        var frame = encode_schema_message(_timestamp_schema(t, "America/New_York"))
        assert_true(
            _frame_contains(frame, "America/New_York"),
            String(
                "the Schema frame for "
                + String(t)
                + " does not carry its field's TIMEZONE. Every downstream"
                " instant is then wrong by the UTC offset, silently, with no"
                " error anywhere."
            ),
        )
        _ = frame^


def test_naive_timestamp_stays_naive_all_five_slots() raises:
    """★ THE CONTROL THAT REFUTES A HARDCODED FIX.

    Writing `"UTC"` unconditionally would satisfy a "does the tz survive" test
    and would be a NEW wrong-answer class: a naive TIMESTAMP relabelled as an
    instant. Arrow's sentinel for "no timezone" is the ABSENT string, so an
    empty `_tz` must leave no timezone bytes in the frame at all.
    """
    var slots = List[ArrowType]()
    slots.append(ArrowType.TIMESTAMP)
    slots.append(ArrowType.TIMESTAMP_S)
    slots.append(ArrowType.TIMESTAMP_MS)
    slots.append(ArrowType.TIMESTAMP_US)
    slots.append(ArrowType.TIMESTAMP_NS)

    for i in range(len(slots)):
        var t = slots[i]
        var frame = encode_schema_message(_timestamp_schema(t, ""))
        assert_false(
            _frame_contains(frame, "UTC"),
            String(
                "a NAIVE "
                + String(t)
                + " field produced a frame containing 'UTC'. A timezone"
                " nobody asked for is the same wrong-answer class as a"
                " timezone that was dropped, pointing the other way."
            ),
        )
        assert_false(
            _frame_contains(frame, "America/New_York"),
            "a naive timestamp frame carries a timezone string",
        )
        _ = frame^


def test_footer_schema_carries_the_timezone_too() raises:
    """The Arrow FILE format re-emits the Schema inside the Footer, and pyarrow
    compares the two. A timezone written in the stream's Schema message but not
    in the Footer's copy is an INCONSISTENT file rather than a merely lossy
    one — so `encode_footer_message` must call the type writer the same way.
    """
    var schema = _timestamp_schema(ArrowType.TIMESTAMP_US, "America/New_York")
    var dicts = List[Block]()
    var batches = List[Block]()
    var tail = encode_footer_message(schema, dicts^, batches^)
    assert_true(
        _frame_contains(tail, "America/New_York"),
        String(
            "the Arrow FILE Footer's re-emitted Schema dropped the timezone"
            " the stream's Schema message carries. The two must agree"
            " bit-for-bit on every Field parameter."
        ),
    )
    _ = tail^


# ---------------------------------------------------------------------------
# ★ DECIMAL — THE PARAMETERS, AT THE BYTES
# ---------------------------------------------------------------------------


def _push_u32_le(mut out: List[UInt8], v: Int):
    """Append `v` as four little-endian bytes."""
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 24) & 0xFF))


def _frame_contains_bytes(
    ref frame: SharedAlignedBuffer[HeapRegion], needle: List[UInt8]
) raises -> Bool:
    """Does `frame` hold `needle`'s bytes, contiguously, anywhere?

    The numeric sibling of `_frame_contains`. Same reason for existing: a
    decimal's parameters are INTEGERS, so there is no string to look for, and a
    Mojo decoder reading back a Mojo encoder's mistake agrees with it.
    """
    var n = frame.len()
    var m = len(needle)
    if m == 0 or m > n:
        return False
    for i in range(n - m + 1):
        var hit = True
        for j in range(m):
            if frame.read_u8_at(i + j) != needle[j]:
                hit = False
                break
        if hit:
            return True
    return False


def _decimal_type_table_bytes(precision: Int, scale: Int, bit_width: Int) -> List[UInt8]:
    """The twelve bytes a `Decimal` type table's inline data must contain.

    `Schema.fbs` `Decimal` is `{0: precision:int, 1: scale:int, 2: bitWidth:int}`
    and `end_table` places present fields in DECLARATION order at their natural
    alignment (see `end_table` in `ipc_flatbuf.mojo`) — three 4-byte fields, no padding
    between them — so the three words are CONTIGUOUS and little-endian.

    ⚠ THAT CONTIGUITY IS THE ONLY THING THIS HELPER ASSUMES about the writer,
    and it is a property of `end_table`, not of the Decimal arm. If the table
    layout ever changes, these tests go red pointing HERE rather than silently
    passing on a coincidental byte run.
    """
    var out = List[UInt8]()
    _push_u32_le(out, precision)
    _push_u32_le(out, scale)
    _push_u32_le(out, bit_width)
    return out^


def test_decimal128_precision_and_scale_reach_the_schema_frame() raises:
    """★ A DECIMAL128 RESULT COLUMN MUST BE ABLE TO LEAVE THIS PROCESS.

    Without a DECIMAL arm in `_write_type_for_arrow_type`, any plan whose
    RESULT carries a decimal128 column answers
    `PLAN_ENDPOINT_UNSUPPORTED_ARROW_TYPE(16)` with NO STREAM — not a degraded
    stream, not a widened one: nothing. `select(col('price'))` over a decimal
    column would be a refusal, although the BODY arm (`encode_decimal128`,
    16-byte slabs) exists; only the Field would be missing.

    ⚠ ASSERTED ON THE RAW FRAME BYTES, for the reason `test_timestamp_timezone_*`
    states: a decoder that shares the encoder's mistake agrees with it.
    `precision` and `scale` are the same
    shape of defect — a number that is WRONG rather than absent moves the
    decimal point: the unscaled 1234567 is 123.4567 at scale 4 and 12345.67 at
    scale 2, with no error anywhere.

    Scale 4 is a typical `price` scale (a decimal128(18, 4) column
    is decimal128(18, 4); p=10 here keeps the precision distinct from the
    scale AND from every other small integer in the frame, so a byte-run match
    cannot be a coincidence of two equal words). Its twelve values sum to
    unscaled 123525315 = 12352.5315 exactly, which float64 accumulation answers
    as 12352.531500000001 — the reason widening is the worst available outcome.
    """
    var schema = Schema.from_fields_1(Field.decimal128("price", 10, 4, True))
    var frame = encode_schema_message(schema)
    assert_true(
        _frame_contains_bytes(frame, _decimal_type_table_bytes(10, 4, 128)),
        String(
            "the Schema frame for a DECIMAL128(10, 4) field does not carry"
            " {precision=10, scale=4, bitWidth=128}. Without them a decimal"
            " column has no Field and the whole stream is refused"
            " (PLAN_ENDPOINT_UNSUPPORTED_ARROW_TYPE(16), no bytes at all)."
        ),
    )
    _ = frame^


def test_decimal256_precision_and_scale_reach_the_schema_frame() raises:
    """DECIMAL256 is the same arm with `bitWidth=256`, and it is wired with
    DECIMAL128 deliberately: it is the other non-nested member of the
    body-encodable set, it has a body arm (`encode_decimal256`, 32-byte slabs)
    and a bounds-checking factory (`Field.decimal256`, precision in [1, 76]),
    and leaving it refused would be a seam with no argument behind it.

    ⚠ `bitWidth` IS WHAT DISCRIMINATES THE TWO, and it is the field a
    copy-paste of the 128 arm gets wrong — a 256 column declared `bitWidth=128`
    hands a foreign reader HALF of every value.
    """
    var schema = Schema.from_fields_1(Field.decimal256("wide", 40, 4, True))
    var frame = encode_schema_message(schema)
    assert_true(
        _frame_contains_bytes(frame, _decimal_type_table_bytes(40, 4, 256)),
        String(
            "the Schema frame for a DECIMAL256(40, 4) field does not carry"
            " {precision=40, scale=4, bitWidth=256}."
        ),
    )
    _ = frame^


def test_decimal_scale_zero_is_written_not_treated_as_absent() raises:
    """★ THE CONTROL FOR THE OTHER DIRECTION.

    Scale 0 is a LEGAL decimal — `decimal128(9, 0)` is an exact integer type,
    and it is what a parquet `INT32`-backed decimal with `scale=0` decodes to.
    A `if scale != 0` guard, or a writer that treats 0 as "unset", produces a
    Field whose scale slot is ABSENT; a flatbuffer reader then supplies the
    schema DEFAULT for `scale`, which is also 0 — so this test would pass
    through a decoder and is only falsifiable at the bytes, where the slot
    either exists or does not.
    """
    var schema = Schema.from_fields_1(Field.decimal128("qty", 9, 0, True))
    var frame = encode_schema_message(schema)
    assert_true(
        _frame_contains_bytes(frame, _decimal_type_table_bytes(9, 0, 128)),
        String(
            "the Schema frame for a DECIMAL128(9, 0) field does not carry its"
            " scale slot. Scale 0 is a legal exact-integer decimal, not an"
            " absent parameter."
        ),
    )
    _ = frame^


def test_decimal_field_with_no_precision_is_refused_not_defaulted() raises:
    """⛔ THE HALF THAT KEEPS THE OTHER THREE HONEST.

    `Field("c", ArrowType.DECIMAL128, True)` — the bare 3-arg ctor, which
    bypasses `Field.decimal128`'s [1, 38] enforcement — carries precision 0.
    Arrow has NO default precision (`pa.decimal128()` takes it positionally),
    so `Decimal{precision=0}` is not a decimal: a foreign reader that accepts
    it reads every value at the wrong magnitude.

    ⛔ THE FORBIDDEN FIX IS TO INVENT ONE. Writing `precision=38` when the
    Field states none, or falling through to FLOAT64, buys a stream by
    EGRESSING A WRONG VALUE — the outcome the refusal protects against. This
    is the assertion that makes that fix red.

    The refusal must also keep its two load-bearing substrings: the function
    name (`result_ipc.is_unwritable_type_message` re-codes on it, and the
    plan-exec IPC door's stderr is matched on it) and the numeric type id
    (`_schema_verdict`'s V_REFUSED_NAMED, asserted id-by-id above).
    """
    var schema = Schema.from_fields_1(Field("c", ArrowType.DECIMAL128, True))
    var raised = False
    var msg = String("")
    try:
        var frame = encode_schema_message(schema)
        _ = frame^
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        String(
            "a DECIMAL128 Field carrying NO precision produced a Schema frame."
            " `Decimal{precision=0}` is not a decimal; every value a foreign"
            " reader takes from it is at the wrong magnitude. Refusing is the"
            " correct answer and it must stay the answer."
        ),
    )
    assert_true(
        msg.find("_write_type_for_arrow_type:") >= 0,
        String(
            "the precision refusal does not name `_write_type_for_arrow_type:`,"
            " so `result_ipc.is_unwritable_type_message` hands it to the door"
            " unshaped and plan_exec_ipc_gate LEG 3rb's stderr grep breaks."
            " Got: "
            + msg
        ),
    )
    assert_true(
        msg.find("ArrowType type_id 18") >= 0,
        String(
            "the precision refusal does not name the numeric type id, which is"
            " what `_schema_verdict` reads to tell a NAMED refusal from an"
            " anonymous one. Got: "
            + msg
        ),
    )


def test_decimal_field_with_out_of_range_scale_is_refused() raises:
    """Scale > precision is unrepresentable, and the bare ctor can spell it.

    `Field.decimal128` enforces `0 <= scale <= precision`; the 3-arg ctor plus
    a direct field poke does not, and neither does a Schema arriving over the
    plan wire. Writing `Decimal{precision=4, scale=9}` produces a Field pyarrow
    itself rejects — so the encoder refusing first is a better error at a site
    that can name the field.
    """
    var f = Field("c", ArrowType.DECIMAL128, True)
    f.decimal_precision = 4
    f.decimal_scale = 9
    var schema = Schema.from_fields_1(f)
    var raised = False
    try:
        var frame = encode_schema_message(schema)
        _ = frame^
    except:
        raised = True
    assert_true(
        raised,
        String(
            "a DECIMAL128 Field with scale 9 > precision 4 produced a Schema"
            " frame. That declares a decimal whose fractional digits outnumber"
            " its total digits — pyarrow rejects it, and the values in the"
            " body cannot mean what it says they mean."
        ),
    )


def test_footer_schema_carries_the_decimal_parameters_too() raises:
    """The Arrow FILE Footer re-emits the Schema and pyarrow compares the two.

    `encode_footer_message` calls the same `_write_type_for_arrow_type`, so
    this is red only if a future change gives the footer its own cascade — the
    exact shape `test_footer_schema_carries_the_timezone_too` exists to catch
    for the timezone.
    """
    var schema = Schema.from_fields_1(Field.decimal128("price", 10, 4, True))
    var dicts = List[Block]()
    var batches = List[Block]()
    var tail = encode_footer_message(schema, dicts^, batches^)
    assert_true(
        _frame_contains_bytes(tail, _decimal_type_table_bytes(10, 4, 128)),
        String(
            "the Arrow FILE Footer's re-emitted Schema dropped the decimal"
            " precision/scale the stream's Schema message carries. The two"
            " must agree bit-for-bit on every Field parameter."
        ),
    )
    _ = tail^


def main() raises:
    var suite = TestSuite()

    suite.test[test_arrow_type_id_space_is_contiguous_0_to_49]()
    suite.test[test_declared_arrow_type_constants_are_50_contiguous_ids]()
    suite.test[test_every_declared_id_is_named_and_no_id_past_the_max_is]()
    suite.test[test_body_leg_census_46_arms_4_named_refusals_0_absent]()
    suite.test[test_schema_leg_census_38_writable_12_refused]()
    suite.test[test_stream_writable_is_the_intersection_and_it_is_38]()
    suite.test[test_catch_all_is_reachable_ids_50_to_255_are_constructible]()

    suite.test[test_timestamp_timezone_reaches_the_schema_frame_all_five_slots]()
    suite.test[test_naive_timestamp_stays_naive_all_five_slots]()
    suite.test[test_footer_schema_carries_the_timezone_too]()

    suite.test[test_decimal128_precision_and_scale_reach_the_schema_frame]()
    suite.test[test_decimal256_precision_and_scale_reach_the_schema_frame]()
    suite.test[test_decimal_scale_zero_is_written_not_treated_as_absent]()
    suite.test[test_decimal_field_with_no_precision_is_refused_not_defaulted]()
    suite.test[test_decimal_field_with_out_of_range_scale_is_refused]()
    suite.test[test_footer_schema_carries_the_decimal_parameters_too]()

    suite^.run()
