# =============================================================================
# proto3_json.mojo — the proto3-canonical-JSON WireEncoder / WireDecoder.
# =============================================================================
#
# `JsonEncoder` /
# `JsonDecoder` are the proto3-canonical-JSON wire backend. This is NOT
# freeform JSON and NOT a reuse of `JsonCompatible` — it implements the
# protobuf language spec's normative JSON mapping:
#
#   - int64 / uint64 / fixed64 / sfixed64  -> JSON STRING (JS-number-precision
#     safety; a 2^53+ int64 loses precision as a JSON number).
#   - int32 / uint32 / fixed32 / sfixed32  -> JSON number.
#   - double                              -> JSON number; "NaN" /
#                                            "Infinity" / "-Infinity"
#                                            strings; read correctly
#                                            rounded, at any length, and
#                                            refused past the double range
#                                            (`proto3_json_float.mojo`).
#   - float                               -> the shortest float32 JSON
#                                            number; "NaN" / "Infinity" /
#                                            "-Infinity" strings; refused on
#                                            read outside float32 range
#                                            (`proto3_json_float.mojo`).
#   - bool                                -> JSON true / false.
#   - string                              -> JSON string (escaped).
#   - bytes                               -> base64 STRING (RFC 4648 §4, std
#                                            alphabet with padding).
#   - field names: ENCODE writes the proto3 lowerCamelCase `json_name`, and
#     only that. DECODE accepts BOTH it and the ORIGINAL `.proto` field name
#     — canonical proto3-JSON parsers accept both, and a document written
#     with the names copied out of the `.proto` (`logical_id`, `depends_on`)
#     must not decode to an all-default message with no error at all.
#     ⛔ THE TWO DIRECTIONS ARE NOT THE SAME RULE; a sentence stating one
#     of them without saying WHICH invites exactly that fail-open. A document stating BOTH spellings of one field is
#     a REFUSAL, not a merge — see `JsonDecoder.expect_fields`.
#   - a nested message is a nested JSON object.
#   - ENCODE omits a field at its default where the field has implicit
#     presence: a plain proto3 scalar or enum (the generated `encode` skips
#     it, reading `OMITS_IMPLICIT_DEFAULTS`) and an empty repeated or map
#     field (this encoder cuts it back out). A field with explicit presence
#     (`optional`, a oneof member, a message) is written whenever it is set,
#     at its default too.
#   - an absent proto3 `optional` field decodes to None (the generated decode
#     body calls `has(json_name)` first); an absent `repeated` field decodes
#     to an empty list.
#
# The `map<K,V>` mapping: a proto3 map field is a JSON OBJECT
# `{"<key>": <value>, ...}`; a non-string (integral) key is stringified to
# its decimal text. The map-entry message is never a standalone struct — the
# code generator emits the loop; the JSON value model (`JsonValue`) exposes
# the object so the generated body can walk it.
#
# Encode rides the direct-byte `List[UInt8]` writers in `komira_json`
# (`write_json_string`, `write_i64_dec`, `write_u64_dec`, and `write_f64_dtoa`
# through `write_proto3_json_f64`) — no intermediate `String` allocation on
# the value path except a double on `write_f64_dtoa`'s slow path (a float32
# is written straight into the buffer by `proto3_json_float.mojo`); bytes
# >= 0x80 are valid JSON content and pass through verbatim. Decode rides the
# `komira_json.JsonValue` tree (the proto3-JSON decode path is the
# debuggability format, off the codec hot path).
#
# Encapsulation: `JsonEncoder` is a `List[UInt8]` accumulator + small
# bookkeeping; `JsonDecoder` wraps an owned `JsonValue`. No pointers cross the
# module boundary.
# =============================================================================

from std.builtin.rebind import downcast, rebind_var

from komira_encoding import base64_encode, base64_decode
from komira_json import (
    JsonValue,
    parse_json_value,
    parse_int64_text,
    JSON_STRING,
    write_json_null,
    write_json_string,
    write_i64_dec,
    write_u64_dec,
)

from .proto3_json_float import (
    read_proto3_json_f32,
    read_proto3_json_f64,
    write_proto3_json_f32,
    write_proto3_json_f64,
)
from .wire_format import (
    FieldKey,
    ProtoEnum,
    ProtoNullValueEnum,
    Serializable,
    Proto3JsonWkt,
    WireDecoder,
    WireEncoder,
)


# =============================================================================
# JsonEncoder — the proto3-JSON WireEncoder.
#
# A message encodes as `{` field* `}`. `JsonEncoder` tracks whether the object
# has been opened and whether a leading comma is owed before the next field,
# so the generated `encode` body can call `write_*_field` in any order
# without managing punctuation. `finish()` closes the object.
# =============================================================================


struct JsonEncoder(WireEncoder):
    """The proto3-canonical-JSON `WireEncoder` over a `List[UInt8]`."""

    comptime OMITS_IMPLICIT_DEFAULTS = True
    """The proto3 JSON mapping omits an implicit-presence field at its
    default (`"name":""` in a request body can ask an API to set it)."""

    var buf: List[UInt8]
    var _opened: Bool
    var _need_comma: Bool
    # Repeated-array element state: whether an element separator is owed.
    var _list_need_comma: Bool
    # Map state. `_map_phase` is 0 outside a map entry, 1 while the next
    # write is the entry KEY (captured as the JSON object key), 2 while the
    # next write is the entry VALUE. `_map_need_comma` tracks the entry
    # separator inside the `{...}` object.
    var _map_phase: Int
    var _map_need_comma: Bool
    # Where the open repeated or map field began, and the comma state before
    # it: an empty one is cut back to here when it closes (see `_drop_empty`).
    var _coll_start: Int
    var _coll_prev_comma: Bool

    def __init__(out self):
        self.buf = List[UInt8]()
        self._opened = False
        self._need_comma = False
        self._list_need_comma = False
        self._map_phase = 0
        self._map_need_comma = False
        self._coll_start = 0
        self._coll_prev_comma = False

    def _ensure_open(mut self):
        """Emit the opening `{` lazily on the first field write."""
        if not self._opened:
            self.buf.append(0x7B)  # '{'
            self._opened = True

    def _begin_field(mut self, json_name: StringSlice):
        """Emit the punctuation that precedes a scalar VALUE, context-aware.

        Two contexts share the scalar `write_*_field` primitives:
          - a normal message field: emit `[,]"<json_name>":` (key + colon).
          - a map entry KEY/VALUE (`_map_phase != 0`): the KEY's rendered
            scalar bytes ARE the object key (always a JSON string in proto3-
            JSON), so emit no name; the trailing `:` and the VALUE's bare
            render are handled in `_end_field`.
        (Repeated-array elements use the separate `write_*_element`
        primitives, which manage their own `[`/`,`/`]` punctuation and do not
        route through `_begin_field`.)
        """
        if self._map_phase != 0:
            # In a map entry — no field name; the value bytes follow.
            return
        self._ensure_open()
        if self._need_comma:
            self.buf.append(0x2C)  # ','
        write_json_string(self.buf, String(json_name))
        self.buf.append(0x3A)  # ':'
        self._need_comma = True

    def _end_field(mut self):
        """Emit the punctuation that follows a scalar VALUE, context-aware.

        For a map entry KEY (phase 1) the just-written value bytes are the
        object key, so emit `:` and advance to the VALUE phase. Otherwise a
        no-op (normal fields and list elements need no trailing punctuation)."""
        if self._map_phase == 1:
            self.buf.append(0x3A)  # ':'
            self._map_phase = 2

    @always_inline
    def _map_key_unquoted(self) -> Bool:
        """True while rendering a map-entry KEY whose scalar writer would emit
        an UNQUOTED token (i32 / u32 / float / bool). proto3-JSON requires the
        object key to be a JSON string, so such a key must be quote-wrapped.
        (string / int64 / uint64 keys are already quoted by their writers, and
        proto forbids float/double map keys; this covers the i32/u32/bool key
        case for completeness.)"""
        return self._map_phase == 1

    def finish(mut self):
        """Close the object. A message with zero written fields still emits
        `{}` (the proto3-JSON empty-message form)."""
        self._ensure_open()
        self.buf.append(0x7D)  # '}'

    def into_string(var self) -> String:
        """The accumulated JSON text as an owned String."""
        return String(unsafe_from_utf8=Span(self.buf))

    # -- scalar field encoders --------------------------------------------

    def write_string_field(
        mut self, field_no: Int, json_name: StringSlice, v: String
    ) raises:
        self._begin_field(json_name)
        write_json_string(self.buf, v)
        self._end_field()

    def write_bytes_field(
        mut self, field_no: Int, json_name: StringSlice, v: List[UInt8]
    ) raises:
        # proto3 JSON: bytes -> base64 string.
        self._begin_field(json_name)
        write_json_string(self.buf, base64_encode(v))
        self._end_field()

    def write_i64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        # proto3 JSON: int64 -> JSON STRING (precision safety).
        self._begin_field(json_name)
        self.buf.append(0x22)  # opening '"'
        write_i64_dec(self.buf, v)
        self.buf.append(0x22)  # closing '"'
        self._end_field()

    def write_i32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        # proto3 JSON: int32 -> JSON number (quoted when used as a map KEY).
        self._begin_field(json_name)
        var quote = self._map_key_unquoted()
        if quote:
            self.buf.append(0x22)
        write_i64_dec(self.buf, Int64(v))
        if quote:
            self.buf.append(0x22)
        self._end_field()

    def write_u64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        # proto3 JSON: uint64 -> JSON STRING. Emit the unsigned decimal directly
        # (write_i64_dec is signed; a uint64 above Int64.MAX must not wrap).
        self._begin_field(json_name)
        self.buf.append(0x22)
        write_u64_dec(self.buf, v)
        self.buf.append(0x22)
        self._end_field()

    def write_u32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        # proto3 JSON: uint32 -> JSON number (quoted when used as a map KEY).
        self._begin_field(json_name)
        var quote = self._map_key_unquoted()
        if quote:
            self.buf.append(0x22)
        write_u64_dec(self.buf, UInt64(v))
        if quote:
            self.buf.append(0x22)
        self._end_field()

    def write_f64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float64
    ) raises:
        self._begin_field(json_name)
        write_proto3_json_f64(self.buf, v)
        self._end_field()

    def write_f32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float32
    ) raises:
        self._begin_field(json_name)
        write_proto3_json_f32(self.buf, v)
        self._end_field()

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    #
    # proto3-JSON has NO wire-type concept — these render IDENTICALLY to the
    # same-width plain int. `sint64`/`sfixed64` -> signed 64-bit (JSON string,
    # like int64); `fixed64` -> unsigned 64-bit (string, like uint64);
    # `sint32`/`sfixed32` -> signed 32-bit (number, like int32);
    # `fixed32` -> unsigned 32-bit (number, like uint32). Delegate so the
    # map-key quoting logic stays single-sourced.

    def write_sint64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        self.write_i64_field(field_no, json_name, v)

    def write_sfixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        self.write_i64_field(field_no, json_name, v)

    def write_fixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        self.write_u64_field(field_no, json_name, v)

    def write_sint32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        self.write_i32_field(field_no, json_name, v)

    def write_sfixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        self.write_i32_field(field_no, json_name, v)

    def write_fixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        self.write_u32_field(field_no, json_name, v)

    def write_bool_field(
        mut self, field_no: Int, json_name: StringSlice, v: Bool
    ) raises:
        self._begin_field(json_name)
        var quote = self._map_key_unquoted()
        if quote:
            self.buf.append(0x22)
        if v:
            _append_lit(self.buf, "true")
        else:
            _append_lit(self.buf, "false")
        if quote:
            self.buf.append(0x22)
        self._end_field()

    # -- enum field (proto3-JSON = the value NAME string) -----------------
    #
    # proto3-canonical-JSON renders an enum as its value NAME string
    # (`"RUNNING"`), NOT the int32. The name is always a JSON string, so a
    # map-KEY enum needs no extra quoting (unlike i32/bool keys). Real Google
    # REST APIs emit this form — decoding it back is what makes the generated
    # client work against a live Compute/GCS response.
    def write_enum_field[
        En: ProtoEnum
    ](mut self, field_no: Int, json_name: StringSlice, v: En) raises:
        self._begin_field(json_name)
        comptime if conforms_to(En, ProtoNullValueEnum):
            # google.protobuf.NullValue: JSON `null`, not a name.
            write_json_null(self.buf)
        else:
            write_json_string(self.buf, v.json_name())
        self._end_field()

    # -- the embedded-message field (cross-trait recursion) ---------------
    #
    # A well-known type (`M: Proto3JsonWkt` -- Timestamp, Duration, Struct,
    # a wrapper, Any, ...) is NOT written as its `{field: value}` object: the
    # protobuf JSON mapping gives it a canonical form of its own
    # (`"1970-01-01T00:00:01Z"`, `"1.5s"`, a free-form object, a bare
    # scalar), which `write_proto3_json` appends whole. The branch is
    # resolved at comptime, so this ONE arm is canonical whichever message
    # type the generated body hands it -- there is no WKT-specific twin to
    # forget to call. Same for the element arm and every read arm below.

    def write_message_field[
        M: Serializable
    ](mut self, field_no: Int, json_name: StringSlice, v: M) raises:
        comptime if conforms_to(M, Proto3JsonWkt):
            if self._map_phase == 1:
                # proto3 forbids a message-typed map KEY; a WKT is a message.
                raise Error(
                    "JsonError: a well-known type cannot be a map key"
                )
            self._begin_field(json_name)
            trait_downcast[Proto3JsonWkt](v).write_proto3_json(self.buf)
            self._end_field()
        else:
            self._begin_field(json_name)
            # Encode the child into its own JsonEncoder, then splice the bytes.
            var child = JsonEncoder()
            v.encode[JsonEncoder](child)
            child.finish()
            for i in range(len(child.buf)):
                self.buf.append(child.buf[i])
            self._end_field()

    # -- repeated (array) framing + element writers -----------------------
    #
    # `begin_list_field` opens `"<name>":[`; each `write_*_element` appends a
    # comma-separated bare value; `end_list_field` closes `]`. An EMPTY
    # repeated field is OMITTED, key and all, as the proto3 JSON mapping
    # omits every field at its default (an absent array decodes to an empty
    # list). This is not cosmetic: under a merge-patch (Compute's PATCH) a
    # sent `"<name>":[]` means "set this list to empty", so emitting it would
    # clear every list a sparse patch left unset.

    def begin_list_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        self._ensure_open()
        self._coll_start = len(self.buf)
        self._coll_prev_comma = self._need_comma
        if self._need_comma:
            self.buf.append(0x2C)  # ','
        write_json_string(self.buf, String(json_name))
        self.buf.append(0x3A)  # ':'
        self.buf.append(0x5B)  # '['
        self._need_comma = True
        self._list_need_comma = False

    def end_list_field(mut self) raises:
        if not self._list_need_comma:
            self._drop_empty()
            return
        self.buf.append(0x5D)  # ']'
        self._list_need_comma = False

    def _drop_empty(mut self):
        """Cut an empty repeated or map field back out: its `[,]"<name>":[`
        (or `{`) prefix is removed and the comma state restored, so the
        field leaves no bytes. A list or map is never open inside another in
        one encoder (a message element encodes into its own child encoder),
        so one saved start suffices."""
        while len(self.buf) > self._coll_start:
            _ = self.buf.pop()
        self._need_comma = self._coll_prev_comma

    def _list_sep(mut self):
        """Emit the element separator before a repeated array element."""
        if self._list_need_comma:
            self.buf.append(0x2C)  # ','
        self._list_need_comma = True

    def write_string_element(mut self, field_no: Int, v: String) raises:
        self._list_sep()
        write_json_string(self.buf, v)

    def write_i64_element(mut self, field_no: Int, v: Int64) raises:
        # proto3 JSON: int64 -> JSON STRING.
        self._list_sep()
        self.buf.append(0x22)
        write_i64_dec(self.buf, v)
        self.buf.append(0x22)

    def write_i32_element(mut self, field_no: Int, v: Int32) raises:
        self._list_sep()
        write_i64_dec(self.buf, Int64(v))

    def write_u64_element(mut self, field_no: Int, v: UInt64) raises:
        self._list_sep()
        self.buf.append(0x22)
        write_u64_dec(self.buf, v)
        self.buf.append(0x22)

    def write_u32_element(mut self, field_no: Int, v: UInt32) raises:
        self._list_sep()
        write_u64_dec(self.buf, UInt64(v))

    def write_f64_element(mut self, field_no: Int, v: Float64) raises:
        self._list_sep()
        write_proto3_json_f64(self.buf, v)

    def write_f32_element(mut self, field_no: Int, v: Float32) raises:
        self._list_sep()
        write_proto3_json_f32(self.buf, v)

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed —
    # JSON-identical to the same-width plain int element.
    def write_sint64_element(mut self, field_no: Int, v: Int64) raises:
        self.write_i64_element(field_no, v)

    def write_sfixed64_element(mut self, field_no: Int, v: Int64) raises:
        self.write_i64_element(field_no, v)

    def write_fixed64_element(mut self, field_no: Int, v: UInt64) raises:
        self.write_u64_element(field_no, v)

    def write_sint32_element(mut self, field_no: Int, v: Int32) raises:
        self.write_i32_element(field_no, v)

    def write_sfixed32_element(mut self, field_no: Int, v: Int32) raises:
        self.write_i32_element(field_no, v)

    def write_fixed32_element(mut self, field_no: Int, v: UInt32) raises:
        self.write_u32_element(field_no, v)

    def write_bool_element(mut self, field_no: Int, v: Bool) raises:
        self._list_sep()
        if v:
            _append_lit(self.buf, "true")
        else:
            _append_lit(self.buf, "false")

    def write_enum_element[
        En: ProtoEnum
    ](mut self, field_no: Int, v: En) raises:
        # A repeated enum element renders as its bare NAME string element
        # (`null` for google.protobuf.NullValue).
        self._list_sep()
        comptime if conforms_to(En, ProtoNullValueEnum):
            write_json_null(self.buf)
        else:
            write_json_string(self.buf, v.json_name())

    def write_message_element[
        M: Serializable
    ](mut self, field_no: Int, v: M) raises:
        # A repeated-message element: emit the element separator, then splice
        # the child's bare object bytes (no field key — the key + brackets are
        # owned by the enclosing `begin/end_list_field`). A well-known type
        # appends its canonical JSON value instead (see `write_message_field`).
        self._list_sep()
        comptime if conforms_to(M, Proto3JsonWkt):
            trait_downcast[Proto3JsonWkt](v).write_proto3_json(self.buf)
        else:
            var child = JsonEncoder()
            v.encode[JsonEncoder](child)
            child.finish()
            for i in range(len(child.buf)):
                self.buf.append(child.buf[i])

    # -- map (object) framing --------------------------------------------
    #
    # `begin_map_field` opens `"<name>":{`; each entry is bracketed by
    # `begin_map_entry` / `end_map_entry`, with the KEY + VALUE written via the
    # ordinary `write_*_field(1, "key", ..)` / `write_*_field(2, "value", ..)`
    # primitives — the `_map_phase` state machine renders the KEY's scalar as
    # the object key and the VALUE's scalar as the object value.
    # `end_map_field` closes `}`. An EMPTY map is omitted, key and all, as an
    # empty repeated field is (see above).

    def begin_map_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        self._ensure_open()
        self._coll_start = len(self.buf)
        self._coll_prev_comma = self._need_comma
        if self._need_comma:
            self.buf.append(0x2C)  # ','
        write_json_string(self.buf, String(json_name))
        self.buf.append(0x3A)  # ':'
        self.buf.append(0x7B)  # '{'
        self._need_comma = True
        self._map_need_comma = False
        self._map_phase = 0

    def end_map_field(mut self) raises:
        self._map_phase = 0
        if not self._map_need_comma:
            self._drop_empty()
            return
        self.buf.append(0x7D)  # '}'
        self._map_need_comma = False

    def begin_map_entry(mut self) raises:
        if self._map_need_comma:
            self.buf.append(0x2C)  # ',' between entries
        self._map_need_comma = True
        self._map_phase = 1  # next scalar write is the KEY

    def end_map_entry(mut self) raises:
        self._map_phase = 0


# =============================================================================
# UnknownFields — what a `JsonDecoder` does with something it cannot name.
# =============================================================================


@fieldwise_init
struct UnknownFields(Copyable, Movable, ImplicitlyCopyable):
    """The `JsonDecoder`'s policy for a token the target schema does not
    declare — an object KEY matching no field, or an enum NAME matching no
    declared value.

    ⭐ THE DEFAULT IS `REFUSE`, AND THAT IS THE SPEC'S DEFAULT TOO. The
    protobuf JSON mapping says a parser *"should reject unknown fields by
    default but may provide an option to ignore unknown fields in parsing"*.
    Ignoring them is a FAIL-OPEN on any input a human or an LLM authored: a
    single mistyped key becomes a different message, confidently accepted.

    ⛔ `IGNORE` IS A MODE STATED AT THE CALL SITE, NEVER A DEFAULT. It has
    exactly one legitimate use — reading a message produced by a **different
    build** of the schema, where an unrecognised field is the peer being
    NEWER rather than the author being wrong. That is a property of the
    DIRECTION of the call (a client reading a server's response), which the
    call site knows and this codec cannot.
    """

    var value: Int

    comptime REFUSE: Int = 0
    """Refuse an unknown key / unknown enum name, naming it and where it is."""
    comptime IGNORE: Int = 1
    """Skip an unknown key; fold an unknown enum name to the zero value."""

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    @staticmethod
    def refuse() -> Self:
        return Self(Self.REFUSE)

    @staticmethod
    def ignore() -> Self:
        return Self(Self.IGNORE)


# =============================================================================
# JsonDecoder — the proto3-JSON WireDecoder.
#
# Wraps the parsed `JsonValue` object for one message. `next_field()` iterates
# the object's keys in document order, yielding a `FieldKey` carrying the
# `json_name`; the per-type `read_*` accessors decode the value at the key
# the most recent `next_field()` positioned at.
#
# An absent proto3 field is simply a key the iteration never yields — so the
# generated `decode` body initializes every field to its default and only
# overwrites the keys present, which is the proto3 absent-field contract.
#
# ── THE TWO THINGS THIS DECODER REFUSES, AND WHY (see `UnknownFields`) ───────
# Both are SILENT by default in a naive decoder:
#   * an object key matching no field of the target message is DROPPED by
#     the generated `else: dec.skip()` arm if `skip` is a no-op;
#   * an enum NAME matching no declared value becomes ORDINAL 0, because the
#     generated `from_json_name` ends `return Self(0)`.
# Neither produces any diagnostic, at any layer, unless the decoder refuses.
# =============================================================================


struct JsonDecoder(WireDecoder):
    """The proto3-canonical-JSON `WireDecoder` — a key-driven message cursor.
    """

    var value: JsonValue
    var _idx: Int
    var _unknown: UnknownFields
    """What to do with a key or enum name the schema does not declare."""
    var _path: String
    """The JSON path of the OBJECT this cursor decodes — `$` at the document
    root, `$.nodes[2]` for a nested message. A refusal appends the offending
    key, so the reader gets a locator and not just a name."""
    var _keep_null: List[String]
    """The keys whose `null` `next_field()` yields rather than skips
    (`keep_null_fields`); empty for every message without a
    `google.protobuf.NullValue` or singular `google.protobuf.Value`
    field."""

    def __init__(out self, var value: JsonValue):
        """A cursor over `value`, REFUSING unknown keys / enum names.

        ⚠ THE DEFAULT IS THE STRICT ONE ON PURPOSE — see `UnknownFields`."""
        self.value = value^
        self._idx = -1
        self._unknown = UnknownFields.refuse()
        self._path = String("$")
        self._keep_null = List[String]()

    def __init__(
        out self,
        var value: JsonValue,
        unknown: UnknownFields,
        var path: String,
    ):
        """A cursor with an explicit unknown-token policy and path prefix.
        Used by `read_message` / the repeated + map decoders to give a nested
        message its parent's policy and its own locator."""
        self.value = value^
        self._idx = -1
        self._unknown = unknown
        self._path = path^
        self._keep_null = List[String]()

    def copy(self) -> Self:
        """Deep clone — `WireDecoder` requires `Copyable`."""
        var out = Self(self.value.copy(), self._unknown, self._path.copy())
        out._idx = self._idx
        out._keep_null = self._keep_null.copy()
        return out^

    @staticmethod
    def from_text(s: String) raises -> JsonDecoder:
        """Parse `s` as a JSON document and wrap it as a decode cursor.

        REFUSES unknown keys and unknown enum names — the proto3-JSON spec
        default. For the forward-compat direction use `from_text_lenient`."""
        return JsonDecoder(parse_json_value(s))

    @staticmethod
    def from_text_lenient(s: String) raises -> JsonDecoder:
        """`from_text`, but IGNORING unknown keys and folding an unknown enum
        name to the zero value.

        ⛔ ONLY for decoding a message produced by a DIFFERENT BUILD of the
        schema — a client reading a possibly-newer server's response. On
        operator- or LLM-authored input this is a fail-open: use
        `from_text`."""
        return JsonDecoder(
            parse_json_value(s), UnknownFields.ignore(), String("$")
        )

    # -- diagnostics -------------------------------------------------------

    def _cur_key(self) -> String:
        """The key `next_field()` is positioned at, or `?` before the first."""
        if self._idx < 0 or self._idx >= len(self.value.obj_keys):
            return String("?")
        return self.value.obj_keys[self._idx].copy()

    def _cur_path(self) -> String:
        """The JSON path of the field the cursor is positioned at."""
        return self._path + String(".") + self._cur_key()

    @staticmethod
    def _at_line(line: Int) -> String:
        """` (line N)`, or the empty string when the value has no source
        position — a synthesized `JsonValue` carries line 0, and printing
        `line 0` would be a confident lie about where to look."""
        if line <= 0:
            return String("")
        return String(" (line ") + String(line) + String(")")

    def keep_null_fields(mut self, spellings: StringSlice):
        for part in String(spellings).split("|"):
            self._keep_null.append(String(part))

    def _null_is_a_value(self, key: String) -> Bool:
        for i in range(len(self._keep_null)):
            if self._keep_null[i] == key:
                return True
        return False

    def next_field(mut self) raises -> FieldKey:
        if not self.value.is_object():
            raise Error("JsonError: decode source is not a JSON object")
        # Advance past keys whose value is JSON null (proto3 treats a null
        # field as absent — skip it so the generated body keeps the default),
        # except a `google.protobuf.NullValue` or singular
        # `google.protobuf.Value` field's, whose `null` is its value
        # (`keep_null_fields`).
        self._idx += 1
        while self._idx < len(self.value.obj_keys):
            if not self.value.children[self._idx].is_null() or self._null_is_a_value(
                self.value.obj_keys[self._idx]
            ):
                return FieldKey(
                    0, self.value.obj_keys[self._idx], False
                )
            self._idx += 1
        return FieldKey.at_end()

    def _cur(self) raises -> JsonValue:
        """The JSON value at the current field index."""
        if self._idx < 0 or self._idx >= len(self.value.children):
            raise Error("JsonError: read_* before next_field()")
        return self.value.children[self._idx].copy()

    def read_string(mut self) raises -> String:
        return self._cur().as_string()

    def read_bytes(mut self) raises -> List[UInt8]:
        # proto3 JSON: bytes is a base64 string.
        return base64_decode(self._cur().as_string())

    def read_i64(mut self) raises -> Int64:
        return self._cur().as_int64()

    def read_i32(mut self) raises -> Int32:
        return Int32(self._cur().as_int64())

    def read_u64(mut self) raises -> UInt64:
        return self._cur().as_uint64()

    def read_u32(mut self) raises -> UInt32:
        return UInt32(self._cur().as_uint64())

    def read_f64(mut self) raises -> Float64:
        return read_proto3_json_f64(self._cur())

    def read_f32(mut self) raises -> Float32:
        return read_proto3_json_f32(self._cur())

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    # proto3-JSON has no wire types — parse as the same-width plain int.
    def read_sint64(mut self) raises -> Int64:
        return self._cur().as_int64()

    def read_sfixed64(mut self) raises -> Int64:
        return self._cur().as_int64()

    def read_fixed64(mut self) raises -> UInt64:
        return self._cur().as_uint64()

    def read_sint32(mut self) raises -> Int32:
        return Int32(self._cur().as_int64())

    def read_sfixed32(mut self) raises -> Int32:
        return Int32(self._cur().as_int64())

    def read_fixed32(mut self) raises -> UInt32:
        return UInt32(self._cur().as_uint64())

    def read_bool(mut self) raises -> Bool:
        return self._cur().as_bool()

    def read_enum[En: ProtoEnum](mut self) raises -> En:
        # proto3-JSON accepts BOTH forms on input (spec §JSON Mapping): the
        # canonical NAME string (`"RUNNING"` — what real Google REST APIs
        # emit) maps via `from_json_name`; the integer form (a number, the
        # robustness case the spec permits) maps via `from_number`.
        var v = self._cur()
        comptime if conforms_to(En, ProtoNullValueEnum):
            # google.protobuf.NullValue reads `null` as its one value; a name
            # or number is read as for any enum below.
            if v.is_null():
                return En.from_number(0)
        if v.kind == JSON_STRING:
            var text = v.as_string()
            # A NUMERIC string is the integer form, not a name — the spec's
            # robustness case. Routing it through the name table would make
            # every `"5"` an undeclared name.
            if _is_integer_text(text):
                return En.from_number(Int(v.as_int64()))
            self._refuse_unknown_enum[En](text, v.src_line, v.key_line)
            return En.from_json_name(text)
        return En.from_number(Int(v.as_int64()))

    def _refuse_unknown_enum[
        En: ProtoEnum
    ](self, name: String, src_line: Int, key_line: Int) raises:
        """RAISE if `name` is not a declared value of `En` (strict mode only).

        ⛔ THIS CANNOT BE DONE BY INSPECTING `from_json_name`'s ANSWER. It
        returns the zero value for an undeclared name AND for the declared
        zero value — `Self(0) == Self(0)` — so the two are indistinguishable
        after the fact. The predicate has to be asked BEFORE."""
        if self._unknown == UnknownFields.ignore():
            return
        if En.is_known_json_name(name):
            return
        var line = key_line
        if line <= 0:
            line = src_line
        raise Error(
            String("JsonError: unknown enum value ")
            + _quote(name)
            + String(" at ")
            + self._cur_path()
            + Self._at_line(line)
            + String(" — declared values are: ")
            + En.known_json_names()
            + String(
                ". An undeclared name would otherwise decode to ORDINAL 0"
                " silently (the proto3 unknown-enum contract), which is"
                " indistinguishable from the field being omitted."
            )
        )

    def read_message[M: Serializable](mut self) raises -> M:
        comptime if conforms_to(M, Proto3JsonWkt):
            # A well-known type reads its canonical JSON value (see
            # `JsonEncoder.write_message_field`); a refusal names the field.
            try:
                return _read_wkt[M](self._cur())
            except e:
                raise Error(String(e) + " at " + self._cur_path())
        else:
            var sub_dec = JsonDecoder(
                self._cur(), self._unknown, self._cur_path()
            )
            return M.decode[JsonDecoder](sub_dec)

    # -- repeated (array) decode ------------------------------------------
    #
    # The current field's value is a JSON `[...]` array; append ALL of its
    # elements to `out`. (A single `next_field()` yields the whole array in
    # proto3-JSON — the binary backend appends one element per occurrence.)

    def _cur_array(self) raises -> JsonValue:
        """The current field's value, required to be a JSON array."""
        var v = self._cur()
        if not v.is_array():
            raise Error("JsonError: expected a JSON array for repeated field")
        return v^

    def read_into_repeated_string(mut self, mut out: List[String]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_string())

    def read_into_repeated_i64(mut self, mut out: List[Int64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_int64())

    def read_into_repeated_i32(mut self, mut out: List[Int32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(Int32(arr.children[i].as_int64()))

    def read_into_repeated_u64(mut self, mut out: List[UInt64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_uint64())

    def read_into_repeated_u32(mut self, mut out: List[UInt32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(UInt32(arr.children[i].as_uint64()))

    def read_into_repeated_f64(mut self, mut out: List[Float64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(read_proto3_json_f64(arr.children[i]))

    def read_into_repeated_f32(mut self, mut out: List[Float32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(read_proto3_json_f32(arr.children[i]))

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed —
    # JSON-identical to the same-width plain int.
    def read_into_repeated_sint64(mut self, mut out: List[Int64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_int64())

    def read_into_repeated_sfixed64(mut self, mut out: List[Int64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_int64())

    def read_into_repeated_fixed64(mut self, mut out: List[UInt64]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_uint64())

    def read_into_repeated_sint32(mut self, mut out: List[Int32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(Int32(arr.children[i].as_int64()))

    def read_into_repeated_sfixed32(mut self, mut out: List[Int32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(Int32(arr.children[i].as_int64()))

    def read_into_repeated_fixed32(mut self, mut out: List[UInt32]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(UInt32(arr.children[i].as_uint64()))

    def read_into_repeated_bool(mut self, mut out: List[Bool]) raises:
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            out.append(arr.children[i].as_bool())

    def read_into_repeated_enum[
        En: ProtoEnum
    ](mut self, mut out: List[En]) raises:
        # The current field's value is a JSON `[...]` array of enum NAME
        # strings (canonical) or integers (robustness); map each element.
        var arr = self._cur_array()
        for i in range(len(arr.children)):
            ref e = arr.children[i]
            if e.kind == JSON_STRING:
                var text = e.as_string()
                if _is_integer_text(text):
                    out.append(En.from_number(Int(e.as_int64())))
                    continue
                self._refuse_unknown_enum[En](text, e.src_line, e.key_line)
                out.append(En.from_json_name(text))
            else:
                out.append(En.from_number(Int(e.as_int64())))

    def read_into_repeated_message[
        M: Serializable
    ](mut self, mut out: List[M]) raises:
        # The current field's value is a JSON `[{..},{..}]` array; decode each
        # element object as an `M` and append it.
        var arr = self._cur_array()
        var base = self._cur_path()
        for i in range(len(arr.children)):
            var path = base + String("[") + String(i) + String("]")
            comptime if conforms_to(M, Proto3JsonWkt):
                try:
                    out.append(_read_wkt[M](arr.children[i]))
                except e:
                    raise Error(String(e) + " at " + path)
            else:
                var sub_dec = JsonDecoder(
                    arr.children[i].copy(), self._unknown, path^
                )
                out.append(M.decode[JsonDecoder](sub_dec))

    # -- map (object) decode --------------------------------------------
    #
    # The current field's value is a JSON `{...}` object; insert ALL of its
    # key/value pairs into `out`. The object key is the map key (an integral
    # proto key arrives as its decimal text — parsed back via `parse_int64_text`
    # on the key string). proto3-JSON always renders the value per its scalar
    # type (string -> string, int32 -> number).

    def _cur_object(self) raises -> JsonValue:
        """The current field's value, required to be a JSON object."""
        var v = self._cur()
        if not v.is_object():
            raise Error("JsonError: expected a JSON object for map field")
        return v^

    def read_into_string_string_map(
        mut self, mut out: Dict[String, String]
    ) raises:
        var obj = self._cur_object()
        for i in range(len(obj.obj_keys)):
            out[obj.obj_keys[i]] = obj.children[i].as_string()

    def read_into_string_i32_map(
        mut self, mut out: Dict[String, Int32]
    ) raises:
        var obj = self._cur_object()
        for i in range(len(obj.obj_keys)):
            out[obj.obj_keys[i]] = Int32(obj.children[i].as_int64())

    def read_into_string_i64_map(
        mut self, mut out: Dict[String, Int64]
    ) raises:
        var obj = self._cur_object()
        for i in range(len(obj.obj_keys)):
            # An int64 value is its decimal text, a JSON string or number.
            out[obj.obj_keys[i]] = obj.children[i].as_int64()

    def read_into_i64_string_map(
        mut self, mut out: Dict[Int64, String]
    ) raises:
        var obj = self._cur_object()
        for i in range(len(obj.obj_keys)):
            # The integral map key is the object key's decimal text.
            out[parse_int64_text(obj.obj_keys[i])] = obj.children[i].as_string()

    def read_into_string_message_map[
        V: Serializable & Deinitable
    ](mut self, mut out: Dict[String, V]) raises:
        # The current field's value is a JSON `{...}` object whose values are
        # themselves nested objects; the object key is the map key, and each
        # value is decoded as a `V` (mirrors `read_into_repeated_message`).
        var obj = self._cur_object()
        var base = self._cur_path()
        for i in range(len(obj.obj_keys)):
            var path = (
                base + String("[") + _quote(obj.obj_keys[i]) + String("]")
            )
            comptime if conforms_to(V, Proto3JsonWkt):
                try:
                    out[obj.obj_keys[i]] = _read_wkt[V](obj.children[i])
                except e:
                    raise Error(String(e) + " at " + path)
            else:
                var sub_dec = JsonDecoder(
                    obj.children[i].copy(), self._unknown, path^
                )
                out[obj.obj_keys[i]] = V.decode[JsonDecoder](sub_dec)

    # A well-known-type FIELD whose JSON value is `null` reaches
    # `read_message` only if the generated `decode` named its key to
    # `keep_null_fields`, which it does for a singular `google.protobuf.Value`
    # field alone: the spec reads `null` there as NULL_VALUE (Value's
    # `read_proto3_json` maps it) and in every other WKT field as ABSENT,
    # which `next_field()` gives by skipping the key. A null INSIDE a Struct,
    # a ListValue or a map<string, Value> is a NULL_VALUE.

    # -- the unknown-token refusals ---------------------------------------

    def expect_fields(
        mut self, message_name: StringSlice, accepted: StringSlice
    ) raises:
        """Validate EVERY key of this object against `accepted`, up front.

        Called once by the generated `decode` body before its `next_field()`
        loop. See `WireDecoder.expect_fields` for why the loop's `skip()`
        cannot do this job on its own (a `null`-valued key never reaches the
        loop, and `skip()` cannot say what WOULD have been accepted).

        ⭐⭐ TWO REFUSALS, AND THE SECOND ONE EXISTS BECAUSE OF THE FIRST FIX.
        Accepting BOTH the `jsonName` and the original `.proto` field name
        (which canonical proto3-JSON parsers do) makes a document carrying
        BOTH spellings of one field legal-looking and ORDER-DEPENDENT: the
        decode loop keeps whichever arrives LAST, so `{"logicalId":"a",
        "logical_id":"b"}` and its reverse are the same document with two
        different meanings, and nothing anywhere says so. That is the exact
        class of silent fail-open the vocabulary pass exists to close, so it
        is closed here too:

          * a key in NO group      -> unknown field, naming the vocabulary.
          * two keys in ONE group  -> ambiguous document, naming BOTH
                                      spellings, both lines and the field.

        The group structure is what makes the second one derivable at all —
        `accepted` is comma-separated GROUPS, each group the `|`-separated
        spellings of ONE field, so "same field" is an ordinal comparison
        rather than a string one. A flat list cannot express it, which is
        why the emitted format carries the grouping.

        ⛔ THE IGNORE-UNKNOWN MODE TURNS OFF THE FIRST REFUSAL AND NOT THE
        SECOND. "Ignore unknown fields" is a FORWARD-COMPAT setting — it
        exists so a client can read a peer built from a NEWER schema — and a
        field the message DOES declare, stated twice, is not a newer schema:
        it is a malformed document under every schema. Dropping the
        ambiguity check with the unknown-field check would leave the lenient
        path picking a meaning by key ORDER, which is the defect, not the
        remedy. Two spellings of one DECLARED field are refused in both
        modes; an unknown key is still ignored in lenient mode, including
        several of them (each is group -1 and none is tracked).

        A non-object value is left alone — `next_field()` already produces
        the "decode source is not a JSON object" diagnostic for that, and
        two errors for one cause is worse than one."""
        if not self.value.is_object():
            return
        var lenient = self._unknown == UnknownFields.ignore()
        # `seen_group[j]` is the group ordinal of key `seen_at[j]`. Two
        # parallel lists rather than one, because the lenient path SKIPS an
        # unknown key and index alignment with `obj_keys` would not survive
        # that. `seen_at` is what lets the refusal name the EARLIER spelling
        # and its line.
        var n_keys = len(self.value.obj_keys)
        var seen_group = List[Int](capacity=n_keys)
        var seen_at = List[Int](capacity=n_keys)
        for i in range(n_keys):
            ref key = self.value.obj_keys[i]
            var group = _vocab_group_of(accepted, key)
            if group < 0:
                if lenient:
                    # Forward-compat: a key this build cannot name is
                    # dropped, and any number of them may appear. NOT
                    # tracked below — group -1 is "no field", so recording it
                    # would make two unknown keys collide with each other.
                    continue
                raise Error(
                    String("JsonError: unknown field ")
                    + _quote(key)
                    + String(" at ")
                    + self._path
                    + Self._at_line(self.value.children[i].key_line)
                    + String(" — message ")
                    + String(message_name)
                    + String(" accepts: ")
                    + String(accepted)
                    + String(
                        ". A proto3-JSON document may not carry a field the"
                        " target message does not declare; the decoder would"
                        " otherwise drop it and report nothing. Fix the"
                        " spelling, or — if this document was produced by a"
                        " NEWER build of the schema — decode it with the"
                        " ignore-unknown mode (`decode_json_lenient` /"
                        " `JsonDecoder.from_text_lenient`)."
                    )
                )
            for j in range(len(seen_group)):
                if seen_group[j] != group:
                    continue
                var first_ix = seen_at[j]
                ref first = self.value.obj_keys[first_ix]
                # A LITERAL duplicate and an ALIAS duplicate are the same
                # defect with different symptoms; saying "spelled
                # differently" about `{"a":1,"a":2}` would be a lie, so the
                # sentence is derived from the two tokens rather than fixed.
                var why = String(
                    " — the same field is stated TWICE under the SAME"
                    " spelling"
                )
                if first != key:
                    why = (
                        String(" — it is the SAME FIELD as ")
                        + _quote(first)
                        + Self._at_line(
                            self.value.children[first_ix].key_line
                        )
                        + String(
                            ", spelled differently: proto3-JSON accepts both"
                            " the lowerCamelCase `jsonName` and the original"
                            " `.proto` field name, and this document uses"
                            " both"
                        )
                    )
                raise Error(
                    String("JsonError: duplicate field ")
                    + _quote(key)
                    + String(" at ")
                    + self._path
                    + Self._at_line(self.value.children[i].key_line)
                    + why
                    + String(". Field: ")
                    + _vocab_group_text(accepted, group)
                    + String(" of message ")
                    + String(message_name)
                    + String(
                        ". A proto3-JSON document may not state one field"
                        " twice — the decode loop keeps whichever key comes"
                        " LAST, so this document means two different things"
                        " depending on key ORDER, which JSON does not"
                        " promise. Remove one. Accepted: "
                    )
                    + String(accepted)
                    + String(".")
                )
            seen_group.append(group)
            seen_at.append(i)

    def skip(mut self) raises:
        """Refuse the current field unless this cursor ignores unknowns.

        ⚠ THE GENERATED BODY REACHES THIS ONLY IF `expect_fields` DID NOT
        ALREADY REFUSE — i.e. essentially never, since the two are derived
        from the same field set. It is load-bearing for a HAND-WRITTEN
        `decode` body, which calls `dec.skip()` but declares no vocabulary;
        without it, every hand-written conformer would stay silently
        permissive while the generated ones are strict."""
        if self._unknown == UnknownFields.ignore():
            return
        var line = 0
        if self._idx >= 0 and self._idx < len(self.value.children):
            line = self.value.children[self._idx].key_line
        raise Error(
            String("JsonError: unknown field ")
            + _quote(self._cur_key())
            + String(" at ")
            + self._path
            + Self._at_line(line)
            + String(
                " — it matches no field of the message being decoded. Fix the"
                " spelling, or decode with the ignore-unknown mode"
                " (`decode_json_lenient` / `JsonDecoder.from_text_lenient`)"
                " if this document comes from a NEWER build of the schema."
            )
        )


# =============================================================================
# Local decode-diagnostic helpers.
# =============================================================================


def _vocab_group_of(vocab: StringSlice, needle: String) -> Int:
    """The GROUP ORDINAL of `needle` in `vocab`, or -1 if it is not accepted.

    `vocab` is the accepted-key vocabulary the codegen emits: comma-separated
    GROUPS, each group the `|`-separated spellings of ONE field —
    `"logicalId|logical_id,kind,note,children"`. Membership answers *is this
    key accepted*; the ORDINAL additionally answers *which FIELD is it*, and
    only the second question can catch a document that spells one field two
    ways. Returning a Bool here would make `expect_fields`'s duplicate arm
    unimplementable.

    ⛔ NOT `vocab.find(needle) >= 0`. A substring test accepts every PREFIX
    and every SUFFIX of a real token — `"id"` would pass against
    `"logicalId"`, and `"gicalId"` would too — so a misspelling would be
    admitted by the very check that exists to catch it. A token here is
    bounded on both sides by a `,`, a `|`, or an end of string.

    ⚠ AN EMPTY NEEDLE IS NEVER ACCEPTED, whatever `vocab` says. A message
    with no fields (a `google.protobuf.Empty`-shaped request) emits an EMPTY
    vocabulary, whose single token is also empty — and `{"": 1}` is a legal
    JSON object stating a key that is no proto field. Without this line the
    one message that accepts nothing would accept that key.

    Scans bytes; allocates nothing. `vocab` is a static literal emitted by
    the codegen and `needle` is one document key."""
    var hay = vocab.as_bytes()
    var need = needle.as_bytes()
    var hn = len(hay)
    var nn = len(need)
    if nn == 0:
        return -1
    var group = 0
    var tok_start = 0
    var i = 0
    while i <= hn:
        var is_end = i == hn
        var is_sep = is_end
        if not is_end:
            var c = hay[i]
            is_sep = c == 0x2C or c == 0x7C  # ',' (group) / '|' (alias)
        if is_sep:
            if i - tok_start == nn:
                var k = 0
                var same = True
                while k < nn:
                    if hay[tok_start + k] != need[k]:
                        same = False
                        break
                    k += 1
                if same:
                    return group
            if not is_end and hay[i] == 0x2C:
                group += 1
            tok_start = i + 1
        i += 1
    return -1


def _vocab_group_text(vocab: StringSlice, group: Int) -> String:
    """The `group`-th comma-separated GROUP of `vocab`, verbatim — e.g.
    `"logicalId|logical_id"`.

    ERROR PATH ONLY: it allocates. A duplicate-field refusal has to name the
    FIELD, and a field's identity in this vocabulary IS its group of
    spellings; printing only the two offending keys leaves the reader to work
    out for themselves why two different strings are one field."""
    var hay = vocab.as_bytes()
    var hn = len(hay)
    var g = 0
    var start = 0
    var i = 0
    while i <= hn:
        if i == hn or hay[i] == 0x2C:
            if g == group:
                var out = List[UInt8](capacity=i - start)
                for k in range(start, i):
                    out.append(hay[k])
                return String(unsafe_from_utf8=Span(out))
            g += 1
            start = i + 1
        i += 1
    return String("")


def _quote(s: String) -> String:
    """`s` wrapped in double quotes — a diagnostic must show a token's exact
    extent, or an empty / whitespace-padded key reads as no key at all."""
    return String('"') + s + String('"')


def _is_integer_text(s: String) -> Bool:
    """True iff `s` is a (possibly signed) decimal integer with no other
    characters — the proto3-JSON "enum value as a number" robustness form
    when it arrives as a STRING.

    Empty is False: `""` is a name, and a very common one to typo."""
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return False
    var i = 0
    if b[0] == 0x2D or b[0] == 0x2B:  # '-' / '+'
        i = 1
        if n == 1:
            return False
    while i < n:
        if b[i] < 0x30 or b[i] > 0x39:
            return False
        i += 1
    return True


# =============================================================================
# Local writer helpers.
# =============================================================================


def _append_lit(mut buf: List[UInt8], lit: StringLiteral):
    """Append an ASCII literal verbatim."""
    var s = String(lit)
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        buf.append(bytes[i])


def _read_wkt[M: Serializable](v: JsonValue) raises -> M:
    """Read a well-known type `M` from its canonical JSON value. Only
    instantiated under `comptime if conforms_to(M, Proto3JsonWkt)`."""
    return rebind_var[M](downcast[M, Proto3JsonWkt].read_proto3_json(v))

