# =============================================================================
# wire_format.mojo — the `Serializable` / `WireEncoder` / `WireDecoder`
# trait substrate.
# =============================================================================
#
# This is the Mojo-side codec
# substrate every generated message struct conforms to. The design promise:
# a message is described ONCE and serializes as protobuf-binary *or*
# proto3-canonical-JSON, with the format chosen at COMPTIME — zero runtime
# branching, zero dynamic dispatch, no trampoline, no fn-ptr, no vtable
# (dynamic dispatch is banned in this codebase; the only legal trampoline is
# C-FFI).
#
# -- The trait shape, and why this exact spelling -----------------------------
# The natural sketch carries the encode/decode state as an ASSOCIATED TYPE on
# a single `WireFormat` trait — `W.Sink` / `W.Source`. That shape compiles in
# a single standalone file, but in a multi-module runtime it hits a
# `mojo ==1.0.0b1` limitation: a
# trait method `encode[W: WireFormat](self, mut sink: W.Sink)`, when called
# with a concrete `W` and a concrete-typed local for `W.Sink`, does NOT
# materialize the associated type at the cross-trait recursion call site
# (`write_message_field[M]` calling `v.encode[W]`) — the compiler keeps
# `W.Sink` symbolic and rejects the concrete argument.
#
# The materialization-free shape, adopted here: the wire backend's state IS
# the trait-bound comptime parameter. `Serializable.encode[E: WireEncoder]`
# takes the encoder `E` itself by `mut`; `decode[D: WireDecoder]` takes the
# decoder `D` itself by `mut`. There is NO associated type — `E` / `D` are
# concrete structs passed directly, so nothing needs materializing. This is
# still the design intent ("derive once, all formats"; comptime-
# monomorphized; zero dynamic dispatch) — only the carrier of the per-format
# state moved from an associated type to the trait parameter itself. The
# generated message body is unchanged in spirit: a flat sequence of
# `enc.write_*_field(...)` calls.
#
# Encapsulation: no UnsafePointer crosses this module boundary.
# An encoder is a `List[UInt8]`-backed accumulator; a decoder is a `Span`- /
# `JsonValue`-backed cursor — both owned/view types. The generated body never
# sees a raw pointer.
# =============================================================================


# =============================================================================
# ProtoEnum — the format-neutral enum mapping a generated enum conforms to.
#
# A proto enum has TWO wire forms: on the binary
# wire it is an int32 varint (the `number`); on the proto3-JSON wire it is the
# value's NAME string (`"RUNNING"`, `"JOB_PHASE_PENDING"`). A single generated
# `<Enum>` struct must therefore expose both — the number for the binary path
# and the name for the JSON path — so the wire backend can route by format
# WITHOUT the generated message body branching on wire kind.
#
# `ProtoEnum` is that mapping. A generated enum struct (an `Int`-valued POD —
# Mojo 1.0.0b1 has no native enum sum type) conforms by providing:
#   - `number(self) -> Int`        — the proto int32 value (binary wire).
#   - `json_name(self) -> String`  — the proto value NAME (proto3-JSON wire).
#   - `from_number(n) -> Self`     — name-agnostic inverse (binary wire +
#                                    the proto3-JSON integer-input robustness
#                                    case the spec permits).
#   - `from_json_name(s) -> Self`  — the NAME-string inverse (proto3-JSON
#                                    canonical input).
#
# The wire methods (`write_enum_field` / `read_enum`) are parameterized
# `[En: ProtoEnum]` — fully comptime-monomorphized per enum, no fn-ptr, no
# vtable (the trait-dispatch ban). The binary backend calls `v.number()` and
# `En.from_number(..)`; the JSON backend calls `v.json_name()` and
# `En.from_json_name(..)` — same generated call site, two monomorphic bodies.
# =============================================================================


trait ProtoEnum(Copyable, Movable):
    """The format-neutral enum mapping a generated proto enum conforms to.

    Carries BOTH the binary-wire number and the proto3-JSON name so the wire
    backend can route by format without the generated body branching.
    """

    def number(self) -> Int:
        """The proto int32 value — the protobuf-binary wire form."""
        ...

    def json_name(self) -> String:
        """The proto value NAME — the proto3-canonical-JSON wire form."""
        ...

    @staticmethod
    def from_number(n: Int) -> Self:
        """Construct from the proto int32 value (binary wire; also the
        proto3-JSON integer-input robustness case)."""
        ...

    @staticmethod
    def from_json_name(s: String) -> Self:
        """Construct from the proto value NAME (proto3-JSON canonical input).

        ⛔ AN UNKNOWN NAME MAPS TO THE ZERO VALUE, SILENTLY. That is the
        proto3 unknown-enum contract and it is why `is_known_json_name`
        exists: a decoder that must REFUSE a typo cannot ask this method,
        because `Self(0)` is also the honest answer for the declared zero
        value. `"" == ""` — the two are indistinguishable at this surface.
        ⇒ ASK `is_known_json_name` FIRST if you need to tell them apart.
        """
        ...

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        """True iff `s` is a DECLARED value name of this enum.

        The predicate `from_json_name` cannot express. A strict proto3-JSON
        decoder refuses an undeclared name rather than folding it to 0, and
        this is the only way to see the difference."""
        ...

    @staticmethod
    def known_json_names() -> String:
        """Every declared value name, comma-separated — the accepted
        vocabulary, for a refusal that tells the reader what IS accepted.

        ⚠ ERROR PATH ONLY: it allocates. Never call it to decide anything."""
        ...


# =============================================================================
# WireEncoder — a comptime-selected encode-side wire backend.
#
# Two conformers ship in this package: `ProtoBinaryWire` (protobuf binary,
# delegating to the `komira_protobuf` primitives) and `Proto3JsonWire`
# (proto3 canonical JSON, on the direct-byte writers in `komira_json`).
#
# `E` is ALWAYS a comptime parameter on `Serializable.encode[E]` — fully
# monomorphized at each call site; never a runtime value, never a fn-ptr.
#
# Each field-level primitive takes BOTH the proto field number AND the proto3
# JSON name; each backend uses one and ignores the other:
#   - ProtoBinaryWire keys by `field_no`, ignores `json_name`.
#   - Proto3JsonWire   keys by `json_name`, ignores `field_no`.
#
# The generated `encode` body for a message is a flat sequence of
# `enc.write_*_field(...)` calls, one per set / non-default field. The same
# source body works for both backends — the "derive once, all formats"
# property.
# =============================================================================


trait WireEncoder(Movable):
    """A comptime-selected encode-side wire backend.

    A `WireEncoder` conformer is a stateful accumulator (a `List[UInt8]`
    output buffer plus per-format bookkeeping). The generated message body
    calls its `write_*_field` primitives; `write_message_field[M]` is the
    cross-trait recursion — it is itself parameterized on a `Serializable`
    and calls `v.encode[Self]` for the nested message.
    """

    def write_string_field(
        mut self, field_no: Int, json_name: StringSlice, v: String
    ) raises:
        ...

    def write_bytes_field(
        mut self, field_no: Int, json_name: StringSlice, v: List[UInt8]
    ) raises:
        ...

    def write_i64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        ...

    def write_i32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        ...

    def write_u64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        ...

    def write_u32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        ...

    def write_f64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float64
    ) raises:
        ...

    def write_f32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float32
    ) raises:
        ...

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    #
    # These carry the integral value's TRUE proto wire type — NOT the plain
    # varint of int32/uint32/int64/uint64. `sint*` is a ZIGZAG varint;
    # `fixed*` / `sfixed*` are FIXED-width (wire 5 / 1). The JSON backend's
    # rendering is identical to the same-width plain int (JSON has no wire
    # types) — only the binary backend differs.

    def write_sint64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        ...

    def write_sint32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        ...

    def write_fixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        ...

    def write_fixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        ...

    def write_sfixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        ...

    def write_sfixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        ...

    def write_bool_field(
        mut self, field_no: Int, json_name: StringSlice, v: Bool
    ) raises:
        ...

    # -- enum field (proto3-JSON name vs binary int32) --------------------
    #
    # A proto enum encodes as its int32 `number` on the binary wire and as its
    # value NAME string on the proto3-JSON wire. The single generated call
    # `enc.write_enum_field[En](n, "<jsonName>", self.<f>)` routes to the right
    # form per backend: `PbEncoder` writes the i32 varint (byte-identical to a
    # plain `write_i32_field`), `JsonEncoder` writes `v.json_name()` as a JSON
    # string. `En: ProtoEnum` is comptime — no fn-ptr, no vtable.
    def write_enum_field[
        En: ProtoEnum
    ](mut self, field_no: Int, json_name: StringSlice, v: En) raises:
        ...

    # The embedded-message field — the cross-trait recursion: a primitive
    # itself parameterized on `M: Serializable`, calling `v.encode[...]` for
    # the nested message.
    def write_message_field[
        M: Serializable
    ](mut self, field_no: Int, json_name: StringSlice, v: M) raises:
        ...

    # -- repeated (proto `repeated`) framing + element writers -------------
    #
    # A `repeated` field is a JSON array `[...]` (proto3-JSON) or a sequence
    # of same-tag fields (protobuf-binary). The generated body brackets the
    # element loop with `begin_list_field` / `end_list_field` and writes each
    # element via `write_*_element`. The JSON backend renders the array
    # punctuation; the binary backend treats `begin/end` as no-ops and writes
    # each element as a full tagged field keyed by `field_no`.

    def begin_list_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        ...

    def end_list_field(mut self) raises:
        ...

    def write_string_element(mut self, field_no: Int, v: String) raises:
        ...

    def write_i64_element(mut self, field_no: Int, v: Int64) raises:
        ...

    def write_i32_element(mut self, field_no: Int, v: Int32) raises:
        ...

    def write_u64_element(mut self, field_no: Int, v: UInt64) raises:
        ...

    def write_u32_element(mut self, field_no: Int, v: UInt32) raises:
        ...

    def write_f64_element(mut self, field_no: Int, v: Float64) raises:
        ...

    def write_f32_element(mut self, field_no: Int, v: Float32) raises:
        ...

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed.
    def write_sint64_element(mut self, field_no: Int, v: Int64) raises:
        ...

    def write_sint32_element(mut self, field_no: Int, v: Int32) raises:
        ...

    def write_fixed64_element(mut self, field_no: Int, v: UInt64) raises:
        ...

    def write_fixed32_element(mut self, field_no: Int, v: UInt32) raises:
        ...

    def write_sfixed64_element(mut self, field_no: Int, v: Int64) raises:
        ...

    def write_sfixed32_element(mut self, field_no: Int, v: Int32) raises:
        ...

    def write_bool_element(mut self, field_no: Int, v: Bool) raises:
        ...

    # A `repeated` enum element — the array form of `write_enum_field`. The
    # JSON backend emits a bare NAME string preceded by the element separator
    # (so the enclosing `begin/end_list_field` renders `["RUNNING","DONE"]`);
    # the binary backend writes the i32 varint keyed by `field_no`.
    def write_enum_element[
        En: ProtoEnum
    ](mut self, field_no: Int, v: En) raises:
        ...

    # The embedded-message ELEMENT — a `repeated` message element. Like
    # `write_message_field` but routed through the repeated-array framing:
    # the JSON backend emits a bare (un-keyed) object preceded by the element
    # separator, so the enclosing `begin/end_list_field` renders the
    # `"<name>":[{..},{..}]` array; the binary backend writes a full tagged
    # LEN record keyed by `field_no`, exactly as a same-tag repeated field.
    def write_message_element[
        M: Serializable
    ](mut self, field_no: Int, v: M) raises:
        ...

    # -- map (proto `map<K,V>`) framing ----------------------------------
    #
    # A proto3 `map<K,V>` is a JSON OBJECT `{"<key>": <value>, ...}` (the key
    # always a JSON string) or, on the binary wire, a sequence of repeated
    # length-delimited entry sub-messages (field 1 = key, field 2 = value).
    # The generated body brackets the entry loop with `begin_map_field` /
    # `end_map_field`, and each entry with `begin_map_entry` / `end_map_entry`,
    # writing the key + value via the ordinary `write_*_field(1, "key", ..)` /
    # `write_*_field(2, "value", ..)` primitives. Inside a map entry the JSON
    # backend uses the rendered key scalar as the object key; the binary
    # backend frames the two fields as an entry sub-message.

    def begin_map_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        ...

    def end_map_field(mut self) raises:
        ...

    def begin_map_entry(mut self) raises:
        ...

    def end_map_entry(mut self) raises:
        ...


# =============================================================================
# FieldKey — one decoded field's identity.
#
# The decoder's `next_field()` yields a `FieldKey` carrying BOTH the proto
# field number AND the proto3 JSON name. The generated `decode` body switches
# on whichever its backend populated (protobuf -> `field_no`; JSON ->
# `json_name`). The other is a benign empty default. `end` is the
# loop-termination sentinel.
# =============================================================================


@fieldwise_init
struct FieldKey(Copyable, Movable, ImplicitlyCopyable):
    """One decoded field's identity, yielded by `WireDecoder.next_field()`."""

    var field_no: Int
    var json_name: String
    var end: Bool

    @staticmethod
    def at_end() -> FieldKey:
        """The loop-termination sentinel — no more fields remain."""
        return FieldKey(0, String(""), True)


# =============================================================================
# WireDecoder — a comptime-selected decode-side wire backend.
#
# A `WireDecoder` is a uniform cursor over one message's encoded form. The
# generated `decode` body drives a single loop:
#
#     while True:
#         var key = dec.next_field()
#         if key.end: break
#         if key.<field>...: self.<field> = dec.read_<type>()
#         else: dec.skip()
#
# `next_field()` is tag-driven for protobuf (yields `field_no`) and
# key-driven for proto3-JSON (yields `json_name`); the per-type `read_*`
# accessors read the value the most recent `next_field()` positioned at.
# This uniform surface keeps `decode` a SINGLE generated body across both
# backends — the loop-shape difference (which key the body switches on) is a
# comptime constant the code generator bakes per backend, not a runtime branch.
# =============================================================================


trait WireDecoder(Copyable, Movable):
    """A comptime-selected decode-side wire backend (a uniform message cursor).
    """

    def next_field(mut self) raises -> FieldKey:
        """Advance to the next field; return its `FieldKey`, or
        `FieldKey.at_end()` when the message is exhausted."""
        ...

    def read_string(mut self) raises -> String:
        ...

    def read_bytes(mut self) raises -> List[UInt8]:
        ...

    def read_i64(mut self) raises -> Int64:
        ...

    def read_i32(mut self) raises -> Int32:
        ...

    def read_u64(mut self) raises -> UInt64:
        ...

    def read_u32(mut self) raises -> UInt32:
        ...

    def read_f64(mut self) raises -> Float64:
        ...

    def read_f32(mut self) raises -> Float32:
        ...

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    # `read_sint*` zigzag-decode a varint; `read_fixed*` / `read_sfixed*`
    # read FIXED-width values (wire 5 / 1). The binary backend validates the
    # wire type; the JSON backend parses the same-width number.
    def read_sint64(mut self) raises -> Int64:
        ...

    def read_sint32(mut self) raises -> Int32:
        ...

    def read_fixed64(mut self) raises -> UInt64:
        ...

    def read_fixed32(mut self) raises -> UInt32:
        ...

    def read_sfixed64(mut self) raises -> Int64:
        ...

    def read_sfixed32(mut self) raises -> Int32:
        ...

    def read_bool(mut self) raises -> Bool:
        ...

    # Read the current field as a proto enum. The binary backend reads the
    # i32 varint and maps via `En.from_number`; the JSON backend reads the
    # value (canonical NAME string -> `En.from_json_name`, with the spec's
    # integer-input robustness case -> `En.from_number`). `En: ProtoEnum` is
    # comptime — same generated call site, two monomorphic bodies.
    def read_enum[En: ProtoEnum](mut self) raises -> En:
        ...

    # Read the current field as an embedded message — the cross-trait
    # decode recursion. Returns a fresh `M` decoded from the sub-message.
    def read_message[M: Serializable](mut self) raises -> M:
        ...

    # -- repeated (proto `repeated`) decode -------------------------------
    #
    # `read_into_repeated_*` decodes the current field's elements into `out`.
    # The two backends differ in how many elements one `next_field()` yields:
    #   - protobuf-binary: a repeated field appears as repeated same-tag
    #     occurrences, so each `next_field()` carries ONE element — this
    #     appends exactly one.
    #   - proto3-JSON: the field is a single key whose value is a `[...]`
    #     array, so this appends ALL of the array's elements.
    # The generated body calls this once per `next_field()` either way; the
    # backend's own semantics make the count correct.

    def read_into_repeated_string(mut self, mut out: List[String]) raises:
        ...

    def read_into_repeated_i64(mut self, mut out: List[Int64]) raises:
        ...

    def read_into_repeated_i32(mut self, mut out: List[Int32]) raises:
        ...

    def read_into_repeated_u64(mut self, mut out: List[UInt64]) raises:
        ...

    def read_into_repeated_u32(mut self, mut out: List[UInt32]) raises:
        ...

    def read_into_repeated_f64(mut self, mut out: List[Float64]) raises:
        ...

    def read_into_repeated_f32(mut self, mut out: List[Float32]) raises:
        ...

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed.
    def read_into_repeated_sint64(mut self, mut out: List[Int64]) raises:
        ...

    def read_into_repeated_sint32(mut self, mut out: List[Int32]) raises:
        ...

    def read_into_repeated_fixed64(mut self, mut out: List[UInt64]) raises:
        ...

    def read_into_repeated_fixed32(mut self, mut out: List[UInt32]) raises:
        ...

    def read_into_repeated_sfixed64(mut self, mut out: List[Int64]) raises:
        ...

    def read_into_repeated_sfixed32(mut self, mut out: List[Int32]) raises:
        ...

    def read_into_repeated_bool(mut self, mut out: List[Bool]) raises:
        ...

    # Read a `repeated` ENUM field's element(s) into `out`. As with the scalar
    # `read_into_repeated_*`: the binary backend appends one per same-tag
    # varint occurrence; the JSON backend appends ALL of the `[...]` array's
    # elements (each a NAME string -> `En.from_json_name`, or an integer ->
    # `En.from_number`).
    def read_into_repeated_enum[
        En: ProtoEnum
    ](mut self, mut out: List[En]) raises:
        ...

    # Read a `repeated` MESSAGE field's element(s) into `out`. As with the
    # scalar `read_into_repeated_*`, the two backends differ in element count
    # per `next_field()`:
    #   - protobuf-binary: one same-tag LEN occurrence per `next_field()` —
    #     appends exactly one decoded `M`.
    #   - proto3-JSON: a single key whose value is a `[{..},{..}]` array, so
    #     this decodes and appends ALL of the array's element messages.
    def read_into_repeated_message[
        M: Serializable
    ](mut self, mut out: List[M]) raises:
        ...

    # -- map (proto `map<K,V>`) decode -----------------------------------
    #
    # `read_into_*_*_map` decodes the current field's entries into `out`.
    #   - protobuf-binary: one entry sub-message per `next_field()` — inserts
    #     one key/value pair.
    #   - proto3-JSON: a single key whose value is a `{...}` object — inserts
    #     ALL of the object's key/value pairs (the JSON object key is the map
    #     key; for an integral proto key the JSON key is its decimal text).
    # Only the key/value type combinations that appear in the proto corpus are
    # provided (`<string,string>` is the CRUD-API `config` shape).

    def read_into_string_string_map(
        mut self, mut out: Dict[String, String]
    ) raises:
        ...

    def read_into_string_i32_map(
        mut self, mut out: Dict[String, Int32]
    ) raises:
        ...

    def read_into_i64_string_map(
        mut self, mut out: Dict[Int64, String]
    ) raises:
        ...

    # A `map<string, M>` decode — the value is an embedded MESSAGE (the
    # googleapis surfaces use this, e.g. GCS `ObjectCustomContextPayload`).
    # Parametric on `V: Serializable`, mirroring `read_into_repeated_message`:
    #   - protobuf-binary: one entry sub-message per `next_field()` — the
    #     entry's field 1 is the string key, field 2 the embedded `V` message;
    #     inserts one pair.
    #   - proto3-JSON: a single key whose value is a `{...}` object whose
    #     values are nested objects — inserts ALL pairs, each value decoded
    #     as a `V`.
    def read_into_string_message_map[
        V: Serializable & Deinitable
    ](mut self, mut out: Dict[String, V]) raises:
        ...

    def skip(mut self) raises:
        """Skip the current field's value (unknown-field forward-compat).

        ⚠ A BACKEND MAY REFUSE HERE. The protobuf-BINARY wire skips unknown
        fields unconditionally — that is the proto3 forward-compat contract
        and it is not negotiable. The proto3-JSON wire's spec default is the
        opposite (*"reject unknown fields ... may provide an option to ignore
        unknown fields"*), so `JsonDecoder.skip` RAISES unless the decoder was
        built in its ignore-unknown mode."""
        ...

    def expect_fields(
        mut self, message_name: StringSlice, accepted: StringSlice
    ) raises:
        """Declare the message's ACCEPTED KEY VOCABULARY to the backend,
        once, before the `next_field()` loop begins.

        ⭐ WHY THIS EXISTS AND `skip()` IS NOT ENOUGH. Three reasons, each
        measured on a real document:

          1. `next_field()` legitimately SKIPS a JSON `null` (proto3: null
             means absent), so a misspelled key with a null value never
             reaches the loop body at all and `skip()` is never called for
             it. Only an up-front pass over the object's keys can see it.
          2. `skip()` knows the offending key but NOT what would have been
             acceptable, so its refusal cannot end in "accepts: ...". A
             refusal that names only the mistake makes the reader go find
             the schema; one that names the vocabulary does not.
          3. TWO SPELLINGS OF ONE FIELD IS AMBIGUOUS, NOT REDUNDANT, and
             `skip()` sees one key at a time so it can never notice. Since
             the decoder accepts both the `jsonName` and the `.proto` name,
             `{"logicalId":"a","logical_id":"b"}` would otherwise be admitted
             with the winner decided by key ORDER. That is a document with
             two meanings and no diagnostic — the same fail-open class this
             method exists to close.

        `accepted` is the message's field vocabulary: comma-separated
        GROUPS, each group the `|`-separated spellings of ONE field, in field
        declaration order —

            "logicalId|logical_id,kind,note,children"

        Both the proto3 `jsonName` and the original `.proto` field name are
        accepted spellings (canonical proto3-JSON parsers accept both); a
        field whose two spellings coincide is a one-member group. ⛔ THE
        GROUPING IS LOAD-BEARING, NOT DECORATION: it is the only thing that
        makes "these two keys are the same field" derivable, and a flat
        comma-separated list cannot express it. It is a static literal
        emitted by the codegen: no allocation, no vocabulary to keep in sync
        by hand.

        The protobuf-binary backend keys on field NUMBERS and has no use for
        a name vocabulary; its implementation is a no-op."""
        ...


# =============================================================================
# Serializable — the format-neutral codec trait.
#
# A generated struct conforms to `Serializable` ONCE. `encode[E]` and
# `decode[D]` are written once against the encoder / decoder abstractions and
# work for every backend. `msg.encode[PbEncoder](enc)` and
# `msg.encode[JsonEncoder](enc)` monomorphize to two distinct inlined
# zero-cost paths from the same source body.
#
# `encode` writes the message's FIELDS into `enc` (it does NOT frame itself as
# a length-delimited record — the enclosing `write_message_field` does the
# framing). `decode` consumes a decoder positioned over the message's encoded
# form and returns a fresh Self.
# =============================================================================


trait Serializable(Copyable, Movable):
    """The format-neutral codec trait every generated message conforms to.

    `encode[E]` writes `self`'s fields into a `WireEncoder`; `decode[D]`
    reads a fresh `Self` from a `WireDecoder`. `E` / `D` are comptime
    trait-bound parameters — the body is written once and monomorphizes per
    backend.
    """

    def encode[E: WireEncoder](self, mut enc: E) raises:
        ...

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        ...
