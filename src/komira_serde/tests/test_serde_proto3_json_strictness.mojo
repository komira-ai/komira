# =============================================================================
# test_serde_proto3_json_strictness.mojo — the proto3-JSON decoder REFUSES what
# it cannot name, and ACCEPTS the original `.proto` field name.
# =============================================================================
#
# ⭐⭐ TWO SILENT FAIL-OPENS A proto3-JSON DECODER CAN HAVE, BOTH PINNED HERE.
#
#  1. ACCEPTING ONLY THE proto3 `jsonName` (lowerCamel) KEY SPELLING.
#     Canonical proto3-JSON parsers accept the ORIGINAL `.proto` field name as
#     well. A document written `logical_id` / `depends_on` — copied straight
#     out of the `.proto`, the most natural way for a person or a model to
#     author one — would match no arm, fall into `else: dec.skip()`, and with
#     a no-op `skip` the result is an all-default message and NO error at any
#     layer.
#
#  2. AN UNKNOWN ENUM NAME BECOMING ORDINAL 0. The generated `from_json_name`
#     ends `return Self(0)` (the proto3 unknown-enum contract), so
#     `KIND_SERVERLES_COMPUTE` (one L) is a kind-0 value — and an unknown-KEY
#     guard structurally CANNOT catch it, because the key `kind` is present
#     either way.
#
# WHAT THIS SUITE PINS, and why each leg is here rather than folded into the
# one above it:
#   S1  the `.proto` field name decodes — and the `jsonName` still does
#       (the INVERSION: a decoder that accepted everything would pass S1a).
#   S2  an unknown key is REFUSED, naming the token, the JSON path, the LINE
#       and the accepted vocabulary — and the same document without it is
#       ADMITTED (the inversion for "refuses everything").
#   S3  an unknown key whose value is `null` is REFUSED. ⚠ `next_field()`
#       SKIPS a null (proto3: null means absent), so this one never reaches
#       the loop body and `skip()` can never see it — only the up-front
#       `expect_fields` pass can. A KNOWN key with a null value stays legal.
#   S4  an unknown ENUM NAME is REFUSED naming the token and the declared
#       vocabulary — and the DECLARED ZERO VALUE is not (`Self(0)` is the
#       honest answer for one of them, which is the whole trap).
#   S5  the enum INTEGER forms — a JSON number and a numeric STRING — are
#       still accepted. The refusal is about NAMES; making it about anything
#       else would break the spec's robustness case.
#   S6  the LENIENT mode ignores both, on the SAME documents S2/S4 refuse.
#       Without this leg "strict" could be "the codec is broken".
#   S7  the path names a NESTED position (`$.children[1]`), not just `$`.
#   S8  ⛔ the accepted-vocabulary test is TOKEN-wise, not substring-wise: a
#       key that is a strict substring of an accepted spelling is REFUSED.
#       A `csv.find(key) >= 0` implementation passes every other leg here.
#   S9  the reported LINE is the line of the offending KEY in a multi-line
#       document — not 1, and not the line of the value.
#   S11 ⛔⛔ TWO SPELLINGS OF ONE FIELD ARE A REFUSAL, NOT A MERGE — the
#       fail-open that ACCEPTING BOTH SPELLINGS would otherwise create. `{"logicalId":"a",
#       "logical_id":"b"}` is one field stated twice; the loop keeps the LAST
#       one, so the document has two meanings and key order picks. Refused in
#       BOTH modes: ignore-UNKNOWN is not ignore-AMBIGUOUS.
#   S12 an EMPTY vocabulary (a `google.protobuf.Empty`-shaped message)
#       accepts NO key — including the EMPTY key, which is what an empty
#       vocabulary tokenizes to and what `{"": 1}` supplies.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_serde import (
    ProtoEnum,
    Serializable,
    WireEncoder,
    WireDecoder,
    JsonDecoder,
    UnknownFields,
    decode_json,
    decode_json_lenient,
    encode_json,
)


# =============================================================================
# The probes — hand-written in EXACTLY the shape the code generator emits
# (`expect_fields` before the loop; both spellings in the match arm), so this
# suite falsifies the CODEC even when nothing regenerates.
# =============================================================================


@fieldwise_init
struct ProbeKind(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    """A stand-in for a generated proto enum."""

    var value: Int

    comptime KIND_UNSPECIFIED: Int = 0
    comptime KIND_SERVERLESS_COMPUTE: Int = 1
    comptime KIND_SECRET: Int = 2

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        if self.value == 0:
            return String("KIND_UNSPECIFIED")
        if self.value == 1:
            return String("KIND_SERVERLESS_COMPUTE")
        if self.value == 2:
            return String("KIND_SECRET")
        return String(self.value)

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        if s == "KIND_UNSPECIFIED":
            return Self(0)
        if s == "KIND_SERVERLESS_COMPUTE":
            return Self(1)
        if s == "KIND_SECRET":
            return Self(2)
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        if s == "KIND_UNSPECIFIED":
            return True
        if s == "KIND_SERVERLESS_COMPUTE":
            return True
        if s == "KIND_SECRET":
            return True
        return False

    @staticmethod
    def known_json_names() -> String:
        return String(
            "KIND_UNSPECIFIED,KIND_SERVERLESS_COMPUTE,KIND_SECRET"
        )


@fieldwise_init
struct Child(Serializable, Copyable, Movable):
    """A nested message, so the refusal path can be checked below the root."""

    var label: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "label", self.label)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("probe.v1.Child", "label")
        var label = String("")
        while True:
            var _pb_field = dec.next_field()
            if _pb_field.end:
                break
            if _pb_field.field_no == 1 or _pb_field.json_name == "label":
                label = dec.read_string()
            else:
                dec.skip()
        return Child(label^)


@fieldwise_init
struct Nothing(Serializable, Copyable, Movable):
    """A `google.protobuf.Empty`-shaped message: NO fields, so an EMPTY
    accepted vocabulary. The emitter emits `dec.expect_fields("<M>", "")` for
    one of these (pinned in `emit_tests::empty_message_emits_a_pass_body`),
    and an empty vocabulary is a STATEMENT — this message accepts no key at
    all — not an omission."""

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("probe.v1.Nothing", "")
        while True:
            var _pb_field = dec.next_field()
            if _pb_field.end:
                break
            dec.skip()
        return Nothing()


@fieldwise_init
struct Node(Serializable, Copyable, Movable):
    """`logical_id` is the snake/camel pair; `note` is already lowerCamel, so
    the same struct carries both the case under test and its inversion."""

    var logical_id: String
    var kind: ProbeKind
    var note: String
    var children: List[Child]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "logicalId", self.logical_id)
        enc.write_enum_field[ProbeKind](2, "kind", self.kind)
        enc.write_string_field(3, "note", self.note)
        enc.begin_list_field(4, "children")
        for i in range(len(self.children)):
            enc.write_message_element[Child](4, self.children[i])
        enc.end_list_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        # ⭐ THE VOCABULARY IS GROUPED, NOT FLAT. `|` joins the spellings of
        # ONE field; `,` separates fields. A flat
        # `"logicalId,logical_id,kind,..."` accepts exactly the same keys and
        # passes every other leg in this file — and makes S11 unimplementable,
        # because "these two keys are the same field" is then underivable.
        dec.expect_fields(
            "probe.v1.Node", "logicalId|logical_id,kind,note,children"
        )
        var logical_id = String("")
        var kind = ProbeKind(0)
        var note = String("")
        var children = List[Child]()
        while True:
            var _pb_field = dec.next_field()
            if _pb_field.end:
                break
            if (
                _pb_field.field_no == 1
                or _pb_field.json_name == "logicalId"
                or _pb_field.json_name == "logical_id"
            ):
                logical_id = dec.read_string()
            elif _pb_field.field_no == 2 or _pb_field.json_name == "kind":
                kind = dec.read_enum[ProbeKind]()
            elif _pb_field.field_no == 3 or _pb_field.json_name == "note":
                note = dec.read_string()
            elif _pb_field.field_no == 4 or _pb_field.json_name == "children":
                dec.read_into_repeated_message[Child](children)
            else:
                dec.skip()
        return Node(logical_id^, kind, note^, children^)


# =============================================================================
# Helpers — a refusal is returned as text so every assertion below is POSITIVE
# and prints the message it actually got.
# =============================================================================


def _refusal_of(doc: String) raises -> String:
    """The refusal `decode_json[Node]` raises for `doc`, or "" if ADMITTED."""
    try:
        _ = decode_json[Node](doc)
    except e:
        return String(e)
    return String("")


def _says(msg: String, needle: String) -> Bool:
    return msg.find(needle) >= 0


def _must_say(msg: String, needle: String, why: String) raises:
    assert_true(
        _says(msg, needle),
        String("⛔ the refusal must ")
        + why
        + String(" — it must contain ")
        + needle
        + String(". IT SAID: ")
        + msg,
    )


# =============================================================================
# S1 — the ORIGINAL `.proto` FIELD NAME decodes (and the jsonName still does).
# =============================================================================
def test_s1_the_proto_field_name_decodes_like_the_json_name() raises:
    """⭐ FAIL-OPEN 1. `{"logical_id": "svc"}` must not decode to a node with
    an EMPTY logical id and no error whatsoever."""
    var snake = String(
        '{"logical_id":"svc-a","kind":"KIND_SECRET","note":"n"}'
    )
    var from_snake = decode_json[Node](snake)
    assert_equal(
        from_snake.logical_id,
        String("svc-a"),
        "⛔ THE `.proto` FIELD NAME WAS STILL DROPPED. Canonical proto3-JSON"
        " accepts it; a document copied out of the .proto decodes to an"
        " all-default message with no error at all.",
    )
    assert_equal(from_snake.kind.value, 2, "the rest of the document decoded")

    # ── THE INVERSION: the canonical spelling still works, and produces the
    # IDENTICAL message. Without this a decoder that accepted every key as
    # `logical_id` would pass the leg above.
    var camel = String(
        '{"logicalId":"svc-a","kind":"KIND_SECRET","note":"n"}'
    )
    var from_camel = decode_json[Node](camel)
    assert_equal(
        from_camel.logical_id,
        from_snake.logical_id,
        "the two spellings must produce the SAME message",
    )
    assert_equal(from_camel.note, String("n"), "a lowerCamel-only field")
    print("  test_s1_the_proto_field_name_decodes_like_the_json_name: PASS")


# =============================================================================
# S2 — AN UNKNOWN KEY IS REFUSED, NAMING TOKEN + PATH + LINE + VOCABULARY.
# =============================================================================
def test_s2_an_unknown_key_is_refused_naming_it() raises:
    """⭐ FAIL-OPEN 1's other half: `skip()` must not be a no-op."""
    var doc = String('{"logicalId":"svc","logicl_id":"typo"}')
    var msg = _refusal_of(doc)
    assert_true(
        msg.byte_length() > 0,
        "⛔ AN UNKNOWN KEY WAS SILENTLY DROPPED. The decode returned a"
        " message the document does not describe, and said nothing.",
    )
    _must_say(msg, String('"logicl_id"'), String("NAME the offending token"))
    _must_say(msg, String("$"), String("name WHERE (a JSON path)"))
    _must_say(
        msg,
        String("logicalId"),
        String("state the accepted vocabulary — a reader who is not told what"
               " IS accepted reads this as 'the field does not exist'"),
    )
    _must_say(
        msg,
        String("probe.v1.Node"),
        String("name the MESSAGE, so the reader knows which schema to open"),
    )

    # ── THE INVERSION: the same document without the typo is ADMITTED. ──
    var ok = decode_json[Node](String('{"logicalId":"svc"}'))
    assert_equal(
        ok.logical_id,
        String("svc"),
        "⛔ THE DECODER REFUSES EVERYTHING, which is not a guard.",
    )
    print("  test_s2_an_unknown_key_is_refused_naming_it: PASS")


# =============================================================================
# S3 — AN UNKNOWN KEY WITH A `null` VALUE. The leg `skip()` cannot cover.
# =============================================================================
def test_s3_an_unknown_key_is_refused_even_when_its_value_is_null() raises:
    """⚠ `next_field()` SKIPS a JSON null (proto3: null means absent), so a
    misspelled key with a null value never reaches the decode loop and
    `skip()` is never called for it. Only the up-front vocabulary pass sees
    it. Delete `expect_fields` and this is the leg that goes red while S2
    stays green."""
    var msg = _refusal_of(String('{"logicalId":"svc","logicl_id":null}'))
    assert_true(
        msg.byte_length() > 0,
        "⛔ A MISSPELLED KEY WITH A null VALUE WAS ACCEPTED SILENTLY.",
    )
    _must_say(msg, String('"logicl_id"'), String("name the null-valued typo"))

    # ── THE INVERSION: a KNOWN key with a null value is LEGAL (proto3 says
    # null means absent) and must leave the field at its default. ──
    var ok = decode_json[Node](String('{"logicalId":"svc","note":null}'))
    assert_equal(
        ok.note,
        String(""),
        "⛔ A null ON A DECLARED FIELD WAS REFUSED. proto3 JSON says null"
        " means absent; refusing it makes the decoder wrong about a legal"
        " document.",
    )
    assert_equal(ok.logical_id, String("svc"), "the rest still decoded")
    print(
        "  test_s3_an_unknown_key_is_refused_even_when_its_value_is_null:"
        " PASS"
    )


# =============================================================================
# S4 — AN UNKNOWN ENUM NAME IS REFUSED (and the declared ZERO value is not).
# =============================================================================
def test_s4_an_unknown_enum_name_is_refused_not_folded_to_zero() raises:
    """⭐ FAIL-OPEN 2. `KIND_SERVERLES_COMPUTE` (one L) must not become
    ordinal 0 silently — indistinguishable from the field being omitted."""
    var msg = _refusal_of(
        String('{"logicalId":"svc","kind":"KIND_SERVERLES_COMPUTE"}')
    )
    assert_true(
        msg.byte_length() > 0,
        "⛔ A MISSPELLED ENUM NAME DECODED TO ORDINAL 0 SILENTLY. Downstream"
        " it is reported as an unmapped/unspecified value, which sends the"
        " reader to the consumer instead of to the typo.",
    )
    _must_say(
        msg,
        String('"KIND_SERVERLES_COMPUTE"'),
        String("NAME the offending token — this is the whole point"),
    )
    _must_say(
        msg,
        String("KIND_SERVERLESS_COMPUTE"),
        String("state the declared vocabulary, so the typo is visible"),
    )
    _must_say(msg, String("$.kind"), String("name WHERE"))

    # ── THE INVERSION (a): a DECLARED name decodes. ──
    var ok = decode_json[Node](
        String('{"kind":"KIND_SERVERLESS_COMPUTE"}')
    )
    assert_equal(ok.kind.value, 1, "a declared enum name must still decode")

    # ── THE INVERSION (b): ⛔ THE TRAP. The DECLARED ZERO value produces the
    # same `Self(0)` an unknown name produces, so an implementation that
    # tested `from_json_name(s).value == 0` would refuse this legal document.
    var zero = decode_json[Node](String('{"kind":"KIND_UNSPECIFIED"}'))
    assert_equal(
        zero.kind.value,
        0,
        "⛔ THE DECLARED ZERO VALUE WAS REFUSED. `from_json_name` answers"
        " Self(0) for it AND for an unknown name; the check has to be the"
        " `is_known_json_name` PREDICATE, not the returned ordinal.",
    )
    print(
        "  test_s4_an_unknown_enum_name_is_refused_not_folded_to_zero: PASS"
    )


# =============================================================================
# S5 — THE ENUM INTEGER FORMS STAY LEGAL (the spec's robustness case).
# =============================================================================
def test_s5_an_enum_integer_form_is_still_accepted() raises:
    """proto3-JSON accepts an enum as its NUMBER as well as its name. A
    strictness change that routed a numeric token through the NAME table
    would make every `"5"` an undeclared name."""
    var as_number = decode_json[Node](String('{"kind":2}'))
    assert_equal(as_number.kind.value, 2, "the JSON-number form")

    var as_numeric_string = decode_json[Node](String('{"kind":"2"}'))
    assert_equal(
        as_numeric_string.kind.value,
        2,
        "a numeric STRING is the integer form, not a name",
    )

    # An UNDECLARED ordinal arriving as a number is NOT a name error — proto3
    # preserves an unknown enum NUMBER. Refusing it here would be a different
    # policy than the one this suite is about.
    var unknown_ordinal = decode_json[Node](String('{"kind":97}'))
    assert_equal(
        unknown_ordinal.kind.value,
        97,
        "an unknown enum NUMBER is preserved (proto3), not refused",
    )
    print("  test_s5_an_enum_integer_form_is_still_accepted: PASS")


# =============================================================================
# S6 — THE LENIENT MODE IS REAL, ON THE SAME DOCUMENTS S2 AND S4 REFUSE.
# =============================================================================
def test_s6_the_lenient_mode_ignores_both() raises:
    """⛔ WITHOUT THIS LEG, "strict" is indistinguishable from "the codec is
    broken". The forward-compat direction — a client reading a peer built
    from a NEWER schema — must still work, and it must be a MODE stated at
    the call site rather than a default."""
    var with_unknown_key = decode_json_lenient[Node](
        String('{"logicalId":"svc","logicl_id":"typo"}')
    )
    assert_equal(
        with_unknown_key.logical_id,
        String("svc"),
        "lenient mode drops an unknown key and decodes the rest",
    )

    var with_unknown_enum = decode_json_lenient[Node](
        String('{"kind":"KIND_FROM_THE_FUTURE"}')
    )
    assert_equal(
        with_unknown_enum.kind.value,
        0,
        "lenient mode folds an unknown enum name to the zero value",
    )

    # ── THE INVERSION: the SAME two documents through the STRICT front door
    # are refused. If the default were lenient, both of these would be "".
    assert_true(
        _refusal_of(String('{"logicalId":"svc","logicl_id":"typo"}'))
        .byte_length()
        > 0,
        "⛔ THE DEFAULT IS LENIENT — the mode is not doing anything.",
    )
    assert_true(
        _refusal_of(String('{"kind":"KIND_FROM_THE_FUTURE"}')).byte_length()
        > 0,
        "⛔ THE DEFAULT IS LENIENT for enum names.",
    )
    print("  test_s6_the_lenient_mode_ignores_both: PASS")


# =============================================================================
# S7 — THE PATH NAMES A NESTED POSITION, NOT JUST THE ROOT.
# =============================================================================
def test_s7_the_refusal_path_reaches_into_a_repeated_message() raises:
    """A locator that is always `$` is a constant, not a derivation. The
    element INDEX is what makes it one."""
    var doc = String(
        '{"children":[{"label":"a"},{"label":"b","labl":"typo"}]}'
    )
    var msg = _refusal_of(doc)
    assert_true(msg.byte_length() > 0, "the nested typo must be refused")
    _must_say(
        msg,
        String("$.children[1]"),
        String("name the ELEMENT the typo is in, not just the document"),
    )
    _must_say(msg, String("probe.v1.Child"), String("name the NESTED message"))

    # ⛔ THE INVERSION FOR THE INDEX: the same typo in element 0 must report
    # [0]. A hardcoded suffix passes the assertion above.
    var msg0 = _refusal_of(
        String('{"children":[{"labl":"typo"},{"label":"b"}]}')
    )
    _must_say(
        msg0,
        String("$.children[0]"),
        String("report the ACTUAL element index"),
    )
    print("  test_s7_the_refusal_path_reaches_into_a_repeated_message: PASS")


# =============================================================================
# S8 — ⛔ THE VOCABULARY TEST IS TOKEN-WISE, NOT SUBSTRING-WISE.
# =============================================================================
def test_s8_a_substring_of_an_accepted_key_is_not_an_accepted_key() raises:
    """⛔ THE MUTANT THIS LEG EXISTS TO KILL: `accepted.find(key) >= 0` in
    `_csv_contains`. `"id"` is a substring of `"logicalId"`, `"kind"` AND
    `"logical_id"`; `"ote"` is a suffix of `"note"`; `"child"` a prefix of
    `"children"`.

    ⛔⛔ AND THE VALUE MUST BE `null`, WHICH IS THE WHOLE POINT OF THIS LEG.
    MEASURED: with a non-null value the substring mutant SURVIVES the entire
    rest of this file, because a key `expect_fields` wrongly admits then
    fails every match arm and is refused a second time by `skip()` — the
    right verdict from the wrong mechanism. `next_field()` SKIPS a null, so
    `skip()` is never reached and `expect_fields` is the ONLY thing standing
    between the document and a silent admission. That is the one input shape
    that isolates the vocabulary test.

    Both value shapes are asserted: the null one to kill the mutant, the
    non-null one because a reader will otherwise 'simplify' it back."""
    var probes = List[String]()
    probes.append(String("id"))       # inside "logicalId" AND "logical_id"
    probes.append(String("ote"))      # a SUFFIX of "note"
    probes.append(String("ogicalId")) # a SUFFIX of "logicalId"
    probes.append(String("child"))    # a PREFIX of "children"
    for i in range(len(probes)):
        ref probe = probes[i]
        # ⭐ THE MUTANT-KILLING SHAPE: a null value, so only `expect_fields`
        # can see this key at all.
        var null_msg = _refusal_of(String('{"') + probe + String('":null}'))
        assert_true(
            null_msg.byte_length() > 0,
            String(
                "⛔ A SUBSTRING-OF-AN-ACCEPTED-KEY WITH A null VALUE WAS"
                " ADMITTED. The accepted-vocabulary test is a SUBSTRING"
                " search, so a misspelling is accepted by the very check that"
                " exists to catch it — and a null value means nothing else"
                " ever looks at this key. The key was: "
            )
            + probe,
        )
        # And with a value, where the match arms are a second line of defence.
        var msg = _refusal_of(String('{"') + probe + String('":"x"}'))
        assert_true(
            msg.byte_length() > 0,
            String(
                "⛔ A KEY THAT IS ONLY A SUBSTRING OF AN ACCEPTED SPELLING WAS"
                " ADMITTED. The key was: "
            )
            + probe,
        )

    # ── THE INVERSION: a WHOLE token is accepted, at both ends of the list
    # and in the middle (a bounds bug at either end passes one of these).
    var first = decode_json[Node](String('{"logicalId":"a"}'))
    assert_equal(first.logical_id, String("a"), "first token accepted")
    var middle = decode_json[Node](String('{"note":"b"}'))
    assert_equal(middle.note, String("b"), "middle token accepted")
    var last = decode_json[Node](String('{"children":[]}'))
    assert_equal(len(last.children), 0, "last token accepted")
    print(
        "  test_s8_a_substring_of_an_accepted_key_is_not_an_accepted_key: PASS"
    )


# =============================================================================
# S9 — THE REPORTED LINE IS THE OFFENDING KEY'S LINE.
# =============================================================================
def test_s9_the_refusal_names_the_line_the_key_is_on() raises:
    """A locator that always says `line 1` is a constant. The document below
    puts the typo on line 4, and a KNOWN key on every other line, so a
    'first line' or 'last line' implementation reports the wrong number."""
    var doc = String(
        '{\n'
        '  "logicalId": "svc",\n'
        '  "note": "n",\n'
        '  "logicl_id": "typo",\n'
        '  "kind": "KIND_SECRET"\n'
        '}'
    )
    var msg = _refusal_of(doc)
    assert_true(msg.byte_length() > 0, "the typo must be refused")
    _must_say(msg, String("(line 4)"), String("name the LINE of the key"))

    # ⛔ THE INVERSION: move the typo and the reported line MOVES. Without
    # this, `line 4` could be a constant.
    var doc2 = String(
        '{\n'
        '  "logicl_id": "typo",\n'
        '  "note": "n"\n'
        '}'
    )
    _must_say(
        _refusal_of(doc2),
        String("(line 2)"),
        String("report the ACTUAL line, not a fixed one"),
    )

    # And a MULTI-LINE member: the key is on its own line, the value on the
    # next. The KEY's line is what a reader searches for.
    var doc3 = String(
        '{\n'
        '  "logicalId": "svc",\n'
        '  "childrn":\n'
        '     []\n'
        '}'
    )
    _must_say(
        _refusal_of(doc3),
        String("(line 3)"),
        String(
            "report the KEY's line, not the value's — they differ exactly"
            " when the member is wrapped"
        ),
    )
    print("  test_s9_the_refusal_names_the_line_the_key_is_on: PASS")


# =============================================================================
# S10 — THE ROUND TRIP HOLDS (encoder output satisfies the strict decoder).
# =============================================================================
def test_s10_a_strict_decode_round_trips_an_encoded_message() raises:
    """The encoder emits `jsonName`s, so its own output must satisfy the
    strict decoder. A vocabulary that missed a field would break this."""
    var children = List[Child]()
    children.append(Child(String("c0")))
    children.append(Child(String("c1")))
    var node = Node(
        String("svc-x"), ProbeKind(1), String("hello"), children^
    )
    var json = encode_json(node)
    var back = decode_json[Node](json)
    assert_equal(back.logical_id, String("svc-x"), "round trip: logical_id")
    assert_equal(back.kind.value, 1, "round trip: kind")
    assert_equal(back.note, String("hello"), "round trip: note")
    assert_equal(len(back.children), 2, "round trip: children")
    assert_equal(back.children[1].label, String("c1"), "round trip: nested")
    print("  test_s10_a_strict_decode_round_trips_an_encoded_message: PASS")


# =============================================================================
# S11 — ⛔⛔ TWO SPELLINGS OF ONE FIELD ARE A REFUSAL, NOT A MERGE.
# =============================================================================
def test_s11_one_field_stated_under_two_spellings_is_refused() raises:
    """⛔⛔ THE FAIL-OPEN THAT ACCEPTING BOTH SPELLINGS WOULD CREATE — the
    same class as the one S1/S2 close, introduced by accepting both.

    Once BOTH `logicalId` and `logical_id` are accepted keys, a document
    carrying both is admitted and the decode loop keeps whichever comes
    LAST. Without this guard:

        {"logicalId":"a","logical_id":"b"} -> ADMITTED, logical_id == "b"
        {"logical_id":"b","logicalId":"a"} -> ADMITTED, logical_id == "a"

    One document, two meanings, decided by key ORDER — which a JSON object
    does not promise — and no diagnostic anywhere. Neither existing guard
    could see it: `expect_fields` accepted both because both ARE in the
    vocabulary, and a consumer that checks for unconsumed keys by comparing
    LITERAL key strings sees `logicalId` != `logical_id`."""
    var msg = _refusal_of(
        String('{"logicalId":"a","logical_id":"b","note":"n"}')
    )
    assert_true(
        msg.byte_length() > 0,
        "⛔ ONE FIELD STATED UNDER TWO SPELLINGS WAS ADMITTED SILENTLY."
        " Which value survives is an accident of key ORDER.",
    )
    _must_say(msg, String('"logical_id"'), String("name the SECOND spelling"))
    _must_say(
        msg,
        String('"logicalId"'),
        String("name the FIRST spelling too — a reader given only one token"
               " cannot see what it collides with"),
    )
    _must_say(
        msg,
        String("logicalId|logical_id"),
        String("name the FIELD, i.e. the whole group of spellings — two"
               " different strings being one field is the part that needs"
               " explaining"),
    )
    _must_say(msg, String("probe.v1.Node"), String("name the MESSAGE"))

    # ⛔ THE ORDER INVERSION. The reverse document must be refused too. A
    # guard that only compared each key against the PREVIOUS one, or that
    # keyed on "the camel spelling came first", passes one of these two.
    assert_true(
        _refusal_of(String('{"logical_id":"b","logicalId":"a"}')).byte_length()
        > 0,
        "⛔ THE REFUSAL IS ORDER-DEPENDENT — it must not be, since the defect"
        " it catches is precisely that the MEANING is order-dependent.",
    )

    # ⛔ AND THE NON-ADJACENT INVERSION: the two spellings separated by other
    # keys. An implementation comparing only neighbours passes everything
    # above and admits this.
    assert_true(
        _refusal_of(
            String('{"logicalId":"a","kind":"KIND_SECRET","note":"n",'
                   '"logical_id":"b"}')
        ).byte_length()
        > 0,
        "⛔ THE DUPLICATE CHECK ONLY LOOKS AT ADJACENT KEYS.",
    )

    # ⛔ A LITERAL duplicate lands on the SAME arm — and its message must not
    # claim the two spellings differ, because they do not.
    var lit = _refusal_of(String('{"note":"x","note":"y"}'))
    assert_true(
        lit.byte_length() > 0,
        "⛔ `{\"note\":\"x\",\"note\":\"y\"}` WAS ADMITTED. One key"
        " twice is the same ambiguity as two spellings of one field.",
    )
    _must_say(
        lit,
        String("SAME spelling"),
        String("say WHICH kind of duplicate this is"),
    )
    assert_true(
        not _says(lit, String("spelled differently")),
        String("⛔ THE MESSAGE IS A FIXED STRING: it told a reader holding"
               " two BYTE-IDENTICAL keys that they are 'spelled"
               " differently'. IT SAID: ")
        + lit,
    )

    # ⛔ THE NESTED INVERSION: the guard runs at every depth, and the refusal
    # carries the nested path — not just the root object.
    var nested = _refusal_of(
        String('{"children":[{"label":"a"},{"label":"b","label":"c"}]}')
    )
    assert_true(nested.byte_length() > 0, "a nested duplicate must be refused")
    _must_say(
        nested,
        String("$.children[1]"),
        String("name WHERE the duplicate is, not just that there is one"),
    )

    # ── THE INVERSIONS THAT STOP "REFUSE EVERYTHING" FROM PASSING ─────────
    # (a) EITHER spelling ALONE is still admitted, and to the same field.
    var camel = decode_json[Node](String('{"logicalId":"a","note":"n"}'))
    assert_equal(
        camel.logical_id,
        String("a"),
        "⛔ THE CANONICAL SPELLING ALONE WAS REFUSED.",
    )
    var snake = decode_json[Node](String('{"logical_id":"a","note":"n"}'))
    assert_equal(
        snake.logical_id,
        String("a"),
        "⛔ THE `.proto` SPELLING ALONE WAS REFUSED — that is S1, undone.",
    )

    # (b) TWO DIFFERENT fields are not a duplicate. A guard that refused on
    #     "I have seen a key before" rather than on FIELD IDENTITY would
    #     refuse every document with more than one key.
    var many = decode_json[Node](
        String('{"logicalId":"a","kind":"KIND_SECRET","note":"n",'
               '"children":[]}')
    )
    assert_equal(many.note, String("n"), "four distinct fields must decode")
    assert_equal(many.kind.value, 2, "…including the enum")

    # (c) ⛔ IGNORE-UNKNOWN IS NOT IGNORE-AMBIGUOUS. The lenient mode exists
    #     so a client can read a peer built from a NEWER schema; a field this
    #     build DOES declare, stated twice, is not a newer schema — it is a
    #     malformed document under every schema. Dropping the check with the
    #     unknown-field check would leave the lenient path picking a meaning
    #     by key order, which is the defect and not the remedy.
    var lenient_dup = String("")
    try:
        _ = decode_json_lenient[Node](
            String('{"logicalId":"a","logical_id":"b"}')
        )
    except e:
        lenient_dup = String(e)
    assert_true(
        lenient_dup.byte_length() > 0,
        "⛔ THE LENIENT MODE ADMITTED AN AMBIGUOUS DOCUMENT. Ignoring keys"
        " this build cannot NAME is forward-compat; silently choosing"
        " between two values of a field it CAN name is not.",
    )
    _must_say(
        lenient_dup,
        String("logicalId|logical_id"),
        String("name the field in lenient mode too"),
    )

    # (d) …and the lenient mode still ignores what it is FOR — any number of
    #     unknown keys, which must NOT collide with each other. Group -1 is
    #     "no field"; recording it would make two unknown keys a duplicate.
    var fwd = decode_json_lenient[Node](
        String('{"logicalId":"a","fromTheFuture":1,"alsoNew":2,"third":null}')
    )
    assert_equal(
        fwd.logical_id,
        String("a"),
        "⛔ LENIENT MODE REFUSED A DOCUMENT WITH SEVERAL UNKNOWN KEYS — the"
        " unknown-group sentinel is being tracked as if it were a field.",
    )
    print(
        "  test_s11_one_field_stated_under_two_spellings_is_refused: PASS"
    )


# =============================================================================
# S12 — AN EMPTY VOCABULARY ACCEPTS NOTHING, INCLUDING THE EMPTY KEY.
# =============================================================================
def test_s12_a_message_with_no_fields_accepts_no_key() raises:
    """⛔ THE ARM THAT IS EASY TO WIRE TO NOTHING. A message with no fields
    emits `expect_fields("<M>", "")`, and an empty vocabulary tokenizes to a
    SINGLE EMPTY TOKEN. `{"": 1}` is a legal JSON object, so without an
    explicit empty-needle refusal the one message that accepts NO key would
    have accepted that one — the widest possible fail-open sitting on the
    narrowest possible message.

    This matters beyond the exotic key: every `google.protobuf.Empty`-shaped
    request body decodes through this arm."""
    var empty_ok = decode_json[Nothing](String("{}"))
    _ = empty_ok
    # ⛔⛔ THE EMPTY KEY, WITH A `null` VALUE — AND THE null IS THE WHOLE
    # POINT, exactly as in S8. `_vocab_group_of("", "")` answers group 0
    # without the `nn == 0` guard, so the key is ADMITTED by the vocabulary
    # pass. MEASURED: with a non-null value the mutant is still refused, by
    # `skip()` in the loop — the right verdict from the wrong mechanism, and
    # the refusal does not even name the message. `next_field()` SKIPS a
    # null, so `skip()` is never reached and the vocabulary pass is the only
    # thing standing between this document and a silent admission.
    var by_empty_key = String("")
    try:
        _ = decode_json[Nothing](String('{"":null}'))
    except e:
        by_empty_key = String(e)
    assert_true(
        by_empty_key.byte_length() > 0,
        "⛔ THE EMPTY KEY WAS ACCEPTED BY A MESSAGE THAT ACCEPTS NO KEY."
        " An empty accepted-vocabulary tokenizes to one EMPTY token, and an"
        " empty document key matches it.",
    )
    _must_say(
        by_empty_key,
        String('""'),
        String("show the token's exact extent — an empty key reads as no key"
               " at all if it is not quoted"),
    )
    _must_say(
        by_empty_key,
        String("probe.v1.Nothing"),
        String("name the message"),
    )

    # …and with a VALUE too, because a reader will otherwise "simplify" the
    # null away — it is refused there as well, just by a second mechanism.
    var by_empty_key_valued = String("")
    try:
        _ = decode_json[Nothing](String('{"":1}'))
    except e:
        by_empty_key_valued = String(e)
    assert_true(
        by_empty_key_valued.byte_length() > 0,
        "⛔ THE EMPTY KEY WITH A VALUE WAS ACCEPTED.",
    )

    # An ordinary key is refused too (the arm is not empty-key-specific).
    var by_named_key = String("")
    try:
        _ = decode_json[Nothing](String('{"anything":1}'))
    except e:
        by_named_key = String(e)
    assert_true(
        by_named_key.byte_length() > 0,
        "⛔ A KEY WAS ACCEPTED BY A MESSAGE THAT DECLARES NO FIELD.",
    )

    # ⚠ AND THE NULL SHAPE, because that is the one `skip()` cannot cover.
    var by_null = String("")
    try:
        _ = decode_json[Nothing](String('{"anything":null}'))
    except e:
        by_null = String(e)
    assert_true(
        by_null.byte_length() > 0,
        "⛔ A null-VALUED KEY WAS ACCEPTED BY AN EMPTY MESSAGE — the only"
        " thing that can see it is the vocabulary pass.",
    )

    # ── THE INVERSION: an empty vocabulary must not poison a NON-empty one.
    # A guard written as "if the vocabulary is empty, refuse everything"
    # passes every leg above; this one proves the emptiness is read from the
    # NEEDLE side, not asserted about the vocabulary.
    var node = decode_json[Node](String('{"logicalId":"a"}'))
    assert_equal(node.logical_id, String("a"), "a real message still decodes")
    print("  test_s12_a_message_with_no_fields_accepts_no_key: PASS")


def main() raises:
    print("test_serde_proto3_json_strictness:")
    test_s1_the_proto_field_name_decodes_like_the_json_name()
    test_s2_an_unknown_key_is_refused_naming_it()
    test_s3_an_unknown_key_is_refused_even_when_its_value_is_null()
    test_s4_an_unknown_enum_name_is_refused_not_folded_to_zero()
    test_s5_an_enum_integer_form_is_still_accepted()
    test_s6_the_lenient_mode_ignores_both()
    test_s7_the_refusal_path_reaches_into_a_repeated_message()
    test_s8_a_substring_of_an_accepted_key_is_not_an_accepted_key()
    test_s9_the_refusal_names_the_line_the_key_is_on()
    test_s10_a_strict_decode_round_trips_an_encoded_message()
    test_s11_one_field_stated_under_two_spellings_is_refused()
    test_s12_a_message_with_no_fields_accepts_no_key()
    print("test_serde_proto3_json_strictness: ALL PASS")
