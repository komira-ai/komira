# =============================================================================
# proto_binary.mojo — the protobuf-binary WireEncoder / WireDecoder backend.
# =============================================================================
#
# `PbEncoder` / `PbDecoder` are the protobuf-binary wire backend. They
# delegate straight to the `komira_protobuf` wire primitives — they add NO new
# wire codec, only the `WireEncoder` / `WireDecoder` trait shape over them.
#
# -- The pooled scratch buffer -----------------------------------------------
# `write_message_field` frames a nested message as a length-delimited record:
# it must encode the child into a temporary buffer to learn its byte length
# *before* it can write the length prefix. A naive implementation allocates a
# fresh `List[UInt8]` per call — O(messages) heap churn on a deep tree.
#
# Instead `PbEncoder` owns a `_scratch_pool: List[List[UInt8]]` — a free-list
# of reusable buffers. A nested encode borrows a cleared buffer (capacity
# retained), encodes the child into a child `PbEncoder` over it, length-
# prefixes the child's bytes into the parent, and returns the buffer to the
# pool. A message tree of depth D and width W reuses at most D buffers total,
# not D*W allocations. (The alternative two-pass size-then-write technique is
# also valid; the pool is chosen because it needs no second traversal of the
# generated body.)
#
# -- string / bytes decode copy note -----------------------------------------
# `read_string` / `read_bytes` COPY the payload span into an owned `String` /
# `List[UInt8]` (via the `komira_protobuf` readers). This is the safe
# default: the decoded message outlives the source buffer. The escalation
# path — should a zero-copy profile ever demand it — is a `Span`-view-backed
# string/bytes field whose origin is tied to the source buffer; that is a
# future change, NOT taken here (it would put a borrowed view on a generated
# struct field, which needs an explicit lifetime design).
#
# Encapsulation: `PbEncoder` / `PbDecoder` expose only owned values, typed
# scalars, and the `FieldKey` handle. No UnsafePointer crosses the module
# boundary; the decoder walks a `Span` view with pure index arithmetic.
# =============================================================================

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    pb_read_tag,
    pb_read_varint,
    pb_read_len_field,
    pb_read_string,
    pb_read_bytes,
    pb_read_float,
    pb_read_double,
    pb_read_fixed32,
    pb_read_fixed64,
    pb_skip_field,
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_bool_field,
    pb_write_double_field,
    pb_write_float_field,
    pb_write_string_field,
    pb_write_bytes_field,
    pb_write_sint64_field,
    pb_write_sint32_field,
    pb_write_fixed64_field,
    pb_write_fixed32_field,
    zigzag_decode,
    zigzag_decode32,
)

from .wire_format import (
    FieldKey,
    ProtoEnum,
    Proto3JsonWkt,
    Serializable,
    WireDecoder,
    WireEncoder,
)


# =============================================================================
# PbEncoder — the protobuf-binary WireEncoder.
#
# A stateful accumulator: `buf` is the output byte stream; `_scratch_pool` is
# the free-list of reusable buffers for `write_message_field` framing.
# `field_no` keys the wire; `json_name` is ignored (it is the JSON backend's
# key).
# =============================================================================


struct PbEncoder(WireEncoder):
    """The protobuf-binary `WireEncoder` (delegates to `komira_protobuf`)."""

    var buf: List[UInt8]
    var _scratch_pool: List[List[UInt8]]
    # Map-entry framing state. While inside a `begin_map_entry` … `end_map_entry`
    # bracket, `buf` is swapped out to `_entry_buf` so the ordinary
    # `write_*_field(1, "key", ..)` / `write_*_field(2, "value", ..)` calls land
    # in the entry sub-message buffer; `_map_field_no` is the parent field tag
    # the framed entry is appended under.
    var _entry_buf: List[UInt8]
    var _map_field_no: Int
    var _in_entry: Bool

    def __init__(out self):
        """A fresh empty encoder with an empty scratch pool."""
        self.buf = List[UInt8]()
        self._scratch_pool = List[List[UInt8]]()
        self._entry_buf = List[UInt8]()
        self._map_field_no = 0
        self._in_entry = False

    def into_buf(mut self) -> List[UInt8]:
        """Extract the accumulated byte stream, leaving the encoder's `buf`
        empty. `swap` keeps the struct in a destructor-safe state — a bare
        `self.buf^` would partial-move a field out of the middle of a value
        that still has a synthesized destructor."""
        var out = List[UInt8]()
        swap(out, self.buf)
        return out^

    def _take_scratch(mut self) -> List[UInt8]:
        """Borrow a cleared scratch buffer from the pool (or make a new one).
        """
        if len(self._scratch_pool) > 0:
            return self._scratch_pool.pop()
        return List[UInt8]()

    def _return_scratch(mut self, var scratch: List[UInt8]):
        """Return a scratch buffer to the pool, cleared for the next borrow.

        `clear()` resets the length to zero but keeps the allocated capacity
        — the next `_take_scratch()` reuses that capacity. This retained
        capacity is what makes the pooled-buffer reuse free."""
        scratch.clear()
        self._scratch_pool.append(scratch^)

    # -- scalar field encoders --------------------------------------------

    def write_string_field(
        mut self, field_no: Int, json_name: StringSlice, v: String
    ) raises:
        pb_write_string_field(self.buf, field_no, v)

    def write_bytes_field(
        mut self, field_no: Int, json_name: StringSlice, v: List[UInt8]
    ) raises:
        pb_write_bytes_field(self.buf, field_no, Span(v))

    def write_i64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        # proto `int64`: a plain 2's-complement varint (negatives are a full
        # 10-byte varint — this is NOT the zigzag `sint64`).
        pb_write_varint_field(self.buf, field_no, UInt64(v))

    def write_i32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        # proto `int32`: a varint; a negative int32 sign-extends to 64 bits
        # on the wire (the protobuf spec quirk), so widen through Int64.
        pb_write_varint_field(self.buf, field_no, UInt64(Int64(v)))

    def write_u64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        pb_write_varint_field(self.buf, field_no, v)

    def write_u32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        pb_write_varint_field(self.buf, field_no, UInt64(v))

    def write_f64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float64
    ) raises:
        pb_write_double_field(self.buf, field_no, v)

    def write_f32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Float32
    ) raises:
        pb_write_float_field(self.buf, field_no, v)

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    #
    # `sint*`  -> zigzag varint (wire 0).
    # `fixed*` -> FIXED-width LE bytes (wire 5 / 1), unsigned.
    # `sfixed*`-> FIXED-width LE bytes (wire 5 / 1) of the 2's-complement
    #             bit pattern — reinterpret the signed value's bits as the
    #             matching-width unsigned and emit those bytes.

    def write_sint64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        pb_write_sint64_field(self.buf, field_no, v)

    def write_sint32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        pb_write_sint32_field(self.buf, field_no, v)

    def write_fixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt64
    ) raises:
        pb_write_fixed64_field(self.buf, field_no, v)

    def write_fixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: UInt32
    ) raises:
        pb_write_fixed32_field(self.buf, field_no, v)

    def write_sfixed64_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int64
    ) raises:
        pb_write_fixed64_field(self.buf, field_no, UInt64(v))

    def write_sfixed32_field(
        mut self, field_no: Int, json_name: StringSlice, v: Int32
    ) raises:
        # Reinterpret the Int32's 2's-complement bits as UInt32 (mask the
        # sign-extended Int64 widening back to 32 bits).
        pb_write_fixed32_field(
            self.buf, field_no, UInt32(UInt64(Int64(v)) & 0xFFFFFFFF)
        )

    def write_bool_field(
        mut self, field_no: Int, json_name: StringSlice, v: Bool
    ) raises:
        pb_write_bool_field(self.buf, field_no, v)

    # -- enum field (binary wire = int32 varint, UNCHANGED) ---------------
    #
    # A proto enum on the binary wire is its int32 `number` as a varint —
    # byte-identical to a plain `write_i32_field`. The proto3-JSON NAME mapping
    # is the JSON backend's concern; here the name is ignored.
    def write_enum_field[
        En: ProtoEnum
    ](mut self, field_no: Int, json_name: StringSlice, v: En) raises:
        # `ProtoEnum.number()` returns a SIGNED `Int` (wire_format.mojo), so
        # this is a genuine 64->32 truncation, not an unsigned->same-width-signed
        # round trip.
        pb_write_varint_field(self.buf, field_no, UInt64(Int64(Int32(v.number()))))

    # -- the embedded-message field (cross-trait recursion) ---------------
    #
    # `M.encode[PbEncoder]` writes the child's
    # fields into a child `PbEncoder` whose `buf` is borrowed from this
    # encoder's pool; the child's byte stream is then length-prefixed into
    # the parent and the buffer returned to the pool.

    def write_message_field[
        M: Serializable
    ](mut self, field_no: Int, json_name: StringSlice, v: M) raises:
        # Borrow a child encoder whose `buf` comes from this pool. The pool
        # is moved into the child so nested encodes inside `v.encode` keep
        # reusing buffers, then moved back.
        var child = PbEncoder()
        child.buf = self._take_scratch()
        swap(child._scratch_pool, self._scratch_pool)
        v.encode[PbEncoder](child)
        swap(child._scratch_pool, self._scratch_pool)
        # Frame the child's bytes into the parent: tag + varint(len) + bytes.
        pb_write_tag(self.buf, field_no, PB_WIRE_LEN)
        pb_write_varint(self.buf, UInt64(len(child.buf)))
        for i in range(len(child.buf)):
            self.buf.append(child.buf[i])
        # Recycle the child buffer back into the pool — `into_buf` extracts
        # `buf` via swap so no field is partial-moved.
        self._return_scratch(child.into_buf())

    # -- repeated framing + element writers -------------------------------
    #
    # On the binary wire a `repeated` field is just the same tag repeated, so
    # `begin/end_list_field` are no-ops and each `write_*_element` writes a
    # full tagged field keyed by `field_no`. A packed encoding is NOT used — repeated scalars
    # decode correctly either way, and the unpacked form is the simplest.

    def begin_list_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        pass

    def end_list_field(mut self) raises:
        pass

    def write_string_element(mut self, field_no: Int, v: String) raises:
        pb_write_string_field(self.buf, field_no, v)

    def write_i64_element(mut self, field_no: Int, v: Int64) raises:
        pb_write_varint_field(self.buf, field_no, UInt64(v))

    def write_i32_element(mut self, field_no: Int, v: Int32) raises:
        pb_write_varint_field(self.buf, field_no, UInt64(Int64(v)))

    def write_u64_element(mut self, field_no: Int, v: UInt64) raises:
        pb_write_varint_field(self.buf, field_no, v)

    def write_u32_element(mut self, field_no: Int, v: UInt32) raises:
        pb_write_varint_field(self.buf, field_no, UInt64(v))

    def write_f64_element(mut self, field_no: Int, v: Float64) raises:
        pb_write_double_field(self.buf, field_no, v)

    def write_f32_element(mut self, field_no: Int, v: Float32) raises:
        pb_write_float_field(self.buf, field_no, v)

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed.
    def write_sint64_element(mut self, field_no: Int, v: Int64) raises:
        pb_write_sint64_field(self.buf, field_no, v)

    def write_sint32_element(mut self, field_no: Int, v: Int32) raises:
        pb_write_sint32_field(self.buf, field_no, v)

    def write_fixed64_element(mut self, field_no: Int, v: UInt64) raises:
        pb_write_fixed64_field(self.buf, field_no, v)

    def write_fixed32_element(mut self, field_no: Int, v: UInt32) raises:
        pb_write_fixed32_field(self.buf, field_no, v)

    def write_sfixed64_element(mut self, field_no: Int, v: Int64) raises:
        pb_write_fixed64_field(self.buf, field_no, UInt64(v))

    def write_sfixed32_element(mut self, field_no: Int, v: Int32) raises:
        pb_write_fixed32_field(
            self.buf, field_no, UInt32(UInt64(Int64(v)) & 0xFFFFFFFF)
        )

    def write_bool_element(mut self, field_no: Int, v: Bool) raises:
        pb_write_bool_field(self.buf, field_no, v)

    def write_enum_element[
        En: ProtoEnum
    ](mut self, field_no: Int, v: En) raises:
        # A repeated enum element on the binary wire is just another same-tag
        # int32 varint — byte-identical to `write_i32_element`.
        # Same as `write_enum_field` above: `ProtoEnum.number()` returns a
        # SIGNED `Int`, so this is a real 64->32 truncation.
        pb_write_varint_field(self.buf, field_no, UInt64(Int64(Int32(v.number()))))

    def write_message_element[
        M: Serializable
    ](mut self, field_no: Int, v: M) raises:
        # A repeated-message element on the binary wire is just another
        # same-tag length-delimited record — identical framing to
        # `write_message_field` (the `begin/end_list_field` no-ops add no
        # array structure on the wire).
        var child = PbEncoder()
        child.buf = self._take_scratch()
        swap(child._scratch_pool, self._scratch_pool)
        v.encode[PbEncoder](child)
        swap(child._scratch_pool, self._scratch_pool)
        pb_write_tag(self.buf, field_no, PB_WIRE_LEN)
        pb_write_varint(self.buf, UInt64(len(child.buf)))
        for i in range(len(child.buf)):
            self.buf.append(child.buf[i])
        self._return_scratch(child.into_buf())

    # -- well-known-type fields: WIRE-IDENTICAL to the message arms -------
    #
    # A WKT is an ordinary embedded message on the binary wire; only its
    # proto3-JSON form is special. Forwarding (not re-implementing) is what
    # keeps the two spellings byte-identical by construction.

    @always_inline
    def write_wkt_field[
        T: Proto3JsonWkt
    ](mut self, field_no: Int, json_name: StringSlice, v: T) raises:
        self.write_message_field[T](field_no, json_name, v)

    @always_inline
    def write_wkt_element[
        T: Proto3JsonWkt
    ](mut self, field_no: Int, v: T) raises:
        self.write_message_element[T](field_no, v)

    # -- map framing -----------------------------------------------------
    #
    # A proto3 `map<K,V>` is a repeated length-delimited entry sub-message,
    # one per key/value pair, under the map field's tag. Each entry is a
    # 2-field message: field 1 = key, field 2 = value. `begin_map_entry`
    # swaps `buf` out to `_entry_buf` so the generated body's
    # `write_*_field(1, "key", k)` / `write_*_field(2, "value", v)` land in the
    # entry buffer; `end_map_entry` length-frames the entry under
    # `_map_field_no` into the real `buf`.

    def begin_map_field(
        mut self, field_no: Int, json_name: StringSlice
    ) raises:
        self._map_field_no = field_no

    def end_map_field(mut self) raises:
        pass

    def begin_map_entry(mut self) raises:
        # Redirect subsequent key/value writes into a fresh entry buffer.
        self._entry_buf = self._take_scratch()
        swap(self.buf, self._entry_buf)
        self._in_entry = True

    def end_map_entry(mut self) raises:
        # Restore the real output buffer; `_entry_buf` now holds the entry
        # sub-message bytes.
        swap(self.buf, self._entry_buf)
        self._in_entry = False
        pb_write_tag(self.buf, self._map_field_no, PB_WIRE_LEN)
        pb_write_varint(self.buf, UInt64(len(self._entry_buf)))
        for i in range(len(self._entry_buf)):
            self.buf.append(self._entry_buf[i])
        var spent = List[UInt8]()
        swap(spent, self._entry_buf)
        self._return_scratch(spent^)


# =============================================================================
# PbDecoder — the protobuf-binary WireDecoder.
#
# A tag-driven cursor over one message's field stream. `PbDecoder` OWNS its
# byte buffer (`backing: List[UInt8]`) and threads its own `pos` / `end`
# indices — it does NOT hold a `PbFieldCursor` with a borrowed `Span`,
# because that would require a wildcard origin on the stored Span (a
# stale-pointer hazard across destroy and recreate). Instead each accessor
# builds a fresh `Span(self.backing)` — whose origin is `self` and is correctly tracked —
# and calls the free `komira_protobuf` reader functions on it. No pointer,
# no wildcard, no stored view.
#
# `next_field()` reads the next tag and returns a `FieldKey` carrying the
# proto `field_no`; `_cur_wire` records the wire type so the per-type `read_*`
# accessors can validate it.
# =============================================================================


# =============================================================================
# ★ THE RECURSION BOUND — ON THE DECODER, NOT BESIDE IT
# =============================================================================
#
# On an 8 MiB main-thread stack, a protobuf message of under a kilobyte that
# nests a few hundred sub-messages deep KILLS THE PROCESS. Not an exception —
# SIGSEGV, so the `try: decode_proto(b) except:` that every caller writes never
# runs. There is no stack left to raise onto.
#
# The crash is the mutual recursion between `read_message` below and the
# generated `M.decode`: ONE NATIVE FRAME PER NESTING LEVEL. Every caller that
# decodes a response body off a socket (gRPC clients, REST clients, plan
# readers) is one hostile response away from that dump unless something counts
# the frames.
#
# ★ WHY THE BOUND IS HERE AND NOT IN A PRESCAN. A prescan that walks the bytes
# ahead of the parse and refuses anything past a depth budget can be defeated
# by a single appended byte, if the prescan's walk stops where the decoder's
# keeps going: the prescan then honestly reports a shallow depth about a
# traversal nobody performs. A bound that lives beside the recursion has to
# agree with it forever; a bound that lives ON the recursion cannot disagree
# with it at all. A prescan is still worth having — it refuses earlier, by a
# better name, and can carry budgets (node count) that are a property of the
# payload and not of protobuf — but the guarantee is here.
#
# The counter is a FIELD, not a threaded parameter: `read_message` is the only
# place a sub-decoder is born, so the depth threads itself. The generated
# `decode` bodies are untouched and do not need to know.

comptime PB_MAX_DECODE_DEPTH: Int = 64
"""Maximum nesting of decoded sub-messages, counting the outermost as 1.

DERIVED FROM THE CRASH, not chosen. The decoder dies at roughly 320 nested
`read_message` frames on an 8 MiB stack — about 25 KiB of frame per level. 64
keeps a 5x margin under that.

⚠ THE MARGIN IS NOT DECORATION, because the crash point is a property of the
STACK, not of the format. A decoder running on a pooled worker thread with
512 KiB would die at a small fraction of 320. This bound is what makes the
failure a NAMED REFUSAL on every stack big enough to run the codec at all; it
is not tuned to one stack size.

⚠ AND IT IS A CEILING NOBODY LEGITIMATE IS NEAR. A message can only exceed
this bound if its schema is RECURSIVE (for example `descriptor.proto`'s
`DescriptorProto`, or a query-plan tree). A non-recursive schema fixes its
nesting depth, typically at a single digit, and cannot reach 64 at any input.
A plan that nests two records per plan node gets 32 plan levels.

A prescan that bounds plan depth should use THE SAME NUMBER IN THE SAME UNIT,
so a plan its prescan admits can never be refused here: such a prescan
descends into a SUPERSET of the records this counts (it cannot tell a nested
message from a string, so it descends into both), which makes its apparent
depth >= this one pointwise. The two bounds then cannot fight."""

comptime PB_DECODE_TOO_DEEP: String = "ProtobufError.TOO_DEEP"
"""The refusal token. Named in the `ProtobufError.*` family the rest of this
backend raises, so a caller that already classifies protobuf failures by prefix
classifies this one without a change."""


struct PbDecoder(WireDecoder):
    """The protobuf-binary `WireDecoder` — a tag-driven, self-owning cursor.
    """

    var backing: List[UInt8]
    var pos: Int
    var end: Int
    var _cur_wire: Int
    var _depth: Int
    """How many messages enclose this one, this one included. 1 at the top.

    ⚠ THE WHOLE RECURSION BOUND IS THIS FIELD. It is set exactly once, by
    `_sub_decoder`, which is the only place a nested decoder is constructed —
    so there is no path that recurses without incrementing it."""

    def __init__(out self, var bytes: List[UInt8]):
        """A decoder owning `bytes` — one message's encoded field stream.

        Depth 1: a decoder built by a public entry point IS the outermost
        message. Nesting is created only through `_sub_decoder`."""
        self.end = len(bytes)
        self.backing = bytes^
        self.pos = 0
        self._cur_wire = -1
        self._depth = 1

    def copy(self) -> Self:
        """Deep clone — `WireDecoder` requires `Copyable`."""
        var out = Self(self.backing.copy())
        out.pos = self.pos
        out._cur_wire = self._cur_wire
        out._depth = self._depth
        return out^

    def _sub_decoder(self, var sub: List[UInt8]) raises -> Self:
        """★ THE ONE PLACE NESTING IS CREATED — and therefore the one place it
        can be counted.

        Refuses BEFORE constructing the child, so the frame that would have
        overflowed the stack is never entered."""
        if self._depth >= PB_MAX_DECODE_DEPTH:
            raise Error(
                PB_DECODE_TOO_DEEP
                + ": this message nests more than "
                + String(PB_MAX_DECODE_DEPTH)
                + " levels of sub-messages. The decoder recurses once per"
                " level and would exhaust the stack — measured, that is a"
                " SIGSEGV and not an exception, so this refusal is the only"
                " form the failure can take that a caller is able to catch."
            )
        var out = Self(sub^)
        out._depth = self._depth + 1
        return out^

    def next_field(mut self) raises -> FieldKey:
        if self.pos >= self.end:
            return FieldKey.at_end()
        var tag = pb_read_tag(Span(self.backing), self.pos)
        self.pos = tag.new_pos
        self._cur_wire = tag.wire_type
        return FieldKey(tag.field_number, String(""), False)

    def _read_varint_raw(mut self) raises -> UInt64:
        var v = pb_read_varint(Span(self.backing), self.pos)
        self.pos = v.new_pos
        return v.value

    def read_string(mut self) raises -> String:
        if self._cur_wire != PB_WIRE_LEN:
            raise Error("ProtobufError.WIRE_MISMATCH: expected LEN (string)")
        var f = pb_read_len_field(Span(self.backing), self.pos)
        self.pos = f.new_pos
        return pb_read_string(
            Span(self.backing), f.payload_start, f.payload_end
        )

    def read_bytes(mut self) raises -> List[UInt8]:
        if self._cur_wire != PB_WIRE_LEN:
            raise Error("ProtobufError.WIRE_MISMATCH: expected LEN (bytes)")
        var f = pb_read_len_field(Span(self.backing), self.pos)
        self.pos = f.new_pos
        return pb_read_bytes(Span(self.backing), f.payload_start, f.payload_end)

    def read_i64(mut self) raises -> Int64:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        return Int64(self._read_varint_raw())

    def read_i32(mut self) raises -> Int32:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        # int32 on the wire is a varint sign-extended to 64 bits; narrow.
        return Int32(Int64(self._read_varint_raw()))

    def read_u64(mut self) raises -> UInt64:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        return self._read_varint_raw()

    def read_u32(mut self) raises -> UInt32:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        return UInt32(self._read_varint_raw() & 0xFFFFFFFF)

    def read_f64(mut self) raises -> Float64:
        if self._cur_wire != PB_WIRE_FIXED64:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED64")
        var v = pb_read_double(Span(self.backing), self.pos)
        self.pos += 8
        return v

    def read_f32(mut self) raises -> Float32:
        if self._cur_wire != PB_WIRE_FIXED32:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED32")
        var v = pb_read_float(Span(self.backing), self.pos)
        self.pos += 4
        return v

    # -- WIRE-CORRECTNESS: sint / fixed / sfixed ----------
    #
    # `sint*`   -> a zigzag-decoded VARINT (wire 0).
    # `fixed*`  -> FIXED-width LE bytes (wire 5 / 1), unsigned.
    # `sfixed*` -> FIXED-width LE bytes (wire 5 / 1), reinterpreted as the
    #              signed 2's-complement value of the same width.

    def read_sint64(mut self) raises -> Int64:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT (sint64)")
        return zigzag_decode(self._read_varint_raw())

    def read_sint32(mut self) raises -> Int32:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT (sint32)")
        return zigzag_decode32(UInt32(self._read_varint_raw() & 0xFFFFFFFF))

    def read_fixed64(mut self) raises -> UInt64:
        if self._cur_wire != PB_WIRE_FIXED64:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED64 (fixed64)")
        var s = pb_read_fixed64(Span(self.backing), self.pos)
        self.pos = s.new_pos
        return s.value

    def read_fixed32(mut self) raises -> UInt32:
        if self._cur_wire != PB_WIRE_FIXED32:
            raise Error("ProtobufError.WIRE_MISMATCH: expected FIXED32 (fixed32)")
        var s = pb_read_fixed32(Span(self.backing), self.pos)
        self.pos = s.new_pos
        return s.value

    def read_sfixed64(mut self) raises -> Int64:
        if self._cur_wire != PB_WIRE_FIXED64:
            raise Error(
                "ProtobufError.WIRE_MISMATCH: expected FIXED64 (sfixed64)"
            )
        var s = pb_read_fixed64(Span(self.backing), self.pos)
        self.pos = s.new_pos
        return Int64(s.value)

    def read_sfixed32(mut self) raises -> Int32:
        if self._cur_wire != PB_WIRE_FIXED32:
            raise Error(
                "ProtobufError.WIRE_MISMATCH: expected FIXED32 (sfixed32)"
            )
        var s = pb_read_fixed32(Span(self.backing), self.pos)
        self.pos = s.new_pos
        # Reinterpret the 32-bit pattern as a signed 2's-complement Int32.
        return Int32(Int64(s.value))

    def read_bool(mut self) raises -> Bool:
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT")
        return self._read_varint_raw() != 0

    def read_enum[En: ProtoEnum](mut self) raises -> En:
        # A proto enum on the binary wire is an int32 varint; map via number.
        if self._cur_wire != PB_WIRE_VARINT:
            raise Error("ProtobufError.WIRE_MISMATCH: expected VARINT (enum)")
        return En.from_number(Int(Int32(Int64(self._read_varint_raw()))))

    def read_message[M: Serializable](mut self) raises -> M:
        if self._cur_wire != PB_WIRE_LEN:
            raise Error("ProtobufError.WIRE_MISMATCH: expected LEN (message)")
        var f = pb_read_len_field(Span(self.backing), self.pos)
        self.pos = f.new_pos
        # Copy the sub-message bytes into an owned buffer for the sub-decoder
        # (see the decode-side copy note in the header; the escalation path is
        # a Span-view sub-decoder tied to this decoder's origin).
        var sub = List[UInt8]()
        for i in range(f.payload_start, f.payload_end):
            sub.append(self.backing[i])
        # ★ `_sub_decoder`, never `PbDecoder(...)` — this is THE recursive call
        # site, and it is bounded before the frame is entered.
        var sub_dec = self._sub_decoder(sub^)
        return M.decode[PbDecoder](sub_dec)

    # -- repeated decode --------------------------------------------------
    #
    # ★★ BOTH ENCODINGS. A repeated scalar arrives in one of TWO forms and a
    # conformant parser MUST accept either:
    #
    #   UNPACKED  one tag occurrence per element — what this package's encoder
    #             writes (`PbEncoder`'s `write_*_element`).
    #   PACKED    ONE tag, wire type 2, whose payload is the elements back to
    #             back with no tags — ★ THE PROTO3 DEFAULT, and therefore what
    #             protoc, python-protobuf, Go, Java and C# emit unless a field
    #             says `[packed = false]`.
    #
    # ⚠ A DECODER THAT ACCEPTS ONLY THE FIRST REFUSES ORDINARY FOREIGN BYTES.
    # A message carrying `repeated bool descending` (a sort-direction list),
    # encoded by protoc, arrives PACKED, and an unpacked-only reader refuses it
    # with `ProtobufError.WIRE_MISMATCH: expected VARINT`. Any schema field of
    # type `repeated <scalar>` — including repeated int64 / uint32 / bool type
    # metadata on a schema description — makes the whole message unreadable
    # to such a reader.
    #
    # A test corpus can only falsify the encodings it contains: fixtures whose
    # repeated scalar fields are all EMPTY (proto3 omits an empty repeated field
    # entirely) never exercise either form.
    #
    # ★ "REPEATED SCALARS DECODE CORRECTLY EITHER WAY" (the encoder's note) IS A
    # STATEMENT ABOUT A CONFORMANT PARSER — the compatibility rule the spec
    # imposes so that a producer may choose. It is only true of THIS parser
    # because this parser reads both forms.
    #
    # ⚠ NOT CHANGED ON THE ENCODE SIDE, DELIBERATELY. Emitting unpacked is
    # legal — the spec's requirement is on the READER — and switching the
    # encoder would change the bytes of every message with a repeated scalar.
    # The conformance requirement is on the reader, and the reader handles it.
    #
    # ⚠ STRINGS, BYTES AND MESSAGES ARE NEVER PACKED. Their elements are
    # already length-delimited, so "packed" has no meaning for them and wire
    # type 2 is the ELEMENT, not a container. Their readers below read
    # one element per occurrence, and must stay that way: treating a repeated-string field as
    # packed would read one string's bytes as a stream of elements.

    def _begin_packed(mut self) raises -> Int:
        """Consume the LEN header of a PACKED repeated field.

        Leaves `self.pos` at the first element and returns the offset one past
        the last. The element loop that follows must end exactly at that
        offset, which is also where `pb_read_len_field` would have left the
        cursor — so the packed and unpacked paths agree on where the next field
        begins."""
        var f = pb_read_len_field(Span(self.backing), self.pos)
        self.pos = f.payload_start
        return f.payload_end

    def _packed_bound(mut self, end: Int, what: String) raises:
        """⚠ THE ELEMENT READERS ARE BOUNDED BY THE BUFFER, NOT BY THE PAYLOAD.

        `pb_read_varint` / `pb_read_fixed*` are bounded by the whole backing
        buffer, so a packed payload whose LAST element is truncated would read
        on into the bytes of the FOLLOWING field and silently produce a value
        assembled from two different fields. That is a wrong answer, not a
        crash, which makes it the worse failure — so every element loop checks
        that it did not overrun, and refuses by name if it did."""
        if self.pos > end:
            raise Error(
                "ProtobufError.TRUNCATED: a packed repeated "
                + what
                + " field's last element runs "
                + String(self.pos - end)
                + " byte(s) past the payload it was declared to occupy."
                " Refused rather than assembled from the following field's"
                " bytes."
            )

    def read_into_repeated_string(mut self, mut out: List[String]) raises:
        # NEVER packed — see the note above.
        out.append(self.read_string())

    def read_into_repeated_i64(mut self, mut out: List[Int64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(Int64(self._read_varint_raw()))
                self._packed_bound(e, String("int64"))
            return
        out.append(self.read_i64())

    def read_into_repeated_i32(mut self, mut out: List[Int32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(Int32(Int64(self._read_varint_raw())))
                self._packed_bound(e, String("int32"))
            return
        out.append(self.read_i32())

    def read_into_repeated_u64(mut self, mut out: List[UInt64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(self._read_varint_raw())
                self._packed_bound(e, String("uint64"))
            return
        out.append(self.read_u64())

    def read_into_repeated_u32(mut self, mut out: List[UInt32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(UInt32(self._read_varint_raw() & 0xFFFFFFFF))
                self._packed_bound(e, String("uint32"))
            return
        out.append(self.read_u32())

    def read_into_repeated_f64(mut self, mut out: List[Float64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(pb_read_double(Span(self.backing), self.pos))
                self.pos += 8
                self._packed_bound(e, String("double"))
            return
        out.append(self.read_f64())

    def read_into_repeated_f32(mut self, mut out: List[Float32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(pb_read_float(Span(self.backing), self.pos))
                self.pos += 4
                self._packed_bound(e, String("float"))
            return
        out.append(self.read_f32())

    # WIRE-CORRECTNESS: repeated sint / fixed / sfixed.
    def read_into_repeated_sint64(mut self, mut out: List[Int64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(zigzag_decode(self._read_varint_raw()))
                self._packed_bound(e, String("sint64"))
            return
        out.append(self.read_sint64())

    def read_into_repeated_sint32(mut self, mut out: List[Int32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(
                    zigzag_decode32(
                        UInt32(self._read_varint_raw() & 0xFFFFFFFF)
                    )
                )
                self._packed_bound(e, String("sint32"))
            return
        out.append(self.read_sint32())

    def read_into_repeated_fixed64(mut self, mut out: List[UInt64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                var s = pb_read_fixed64(Span(self.backing), self.pos)
                self.pos = s.new_pos
                out.append(s.value)
                self._packed_bound(e, String("fixed64"))
            return
        out.append(self.read_fixed64())

    def read_into_repeated_fixed32(mut self, mut out: List[UInt32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                var s = pb_read_fixed32(Span(self.backing), self.pos)
                self.pos = s.new_pos
                out.append(s.value)
                self._packed_bound(e, String("fixed32"))
            return
        out.append(self.read_fixed32())

    def read_into_repeated_sfixed64(mut self, mut out: List[Int64]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                var s = pb_read_fixed64(Span(self.backing), self.pos)
                self.pos = s.new_pos
                out.append(Int64(s.value))
                self._packed_bound(e, String("sfixed64"))
            return
        out.append(self.read_sfixed64())

    def read_into_repeated_sfixed32(mut self, mut out: List[Int32]) raises:
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                var s = pb_read_fixed32(Span(self.backing), self.pos)
                self.pos = s.new_pos
                out.append(Int32(Int64(s.value)))
                self._packed_bound(e, String("sfixed32"))
            return
        out.append(self.read_sfixed32())

    def read_into_repeated_bool(mut self, mut out: List[Bool]) raises:
        # The common packed case: per-key sort-direction and nulls-first flag
        # lists are `repeated bool`, and protoc packs them.
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(self._read_varint_raw() != 0)
                self._packed_bound(e, String("bool"))
            return
        out.append(self.read_bool())

    def read_into_repeated_enum[
        En: ProtoEnum
    ](mut self, mut out: List[En]) raises:
        # ⚠ AN ENUM IS AN int32 VARINT, SO IT IS PACKABLE and protoc packs it.
        # Same two-form contract as every numeric reader above.
        if self._cur_wire == PB_WIRE_LEN:
            var e = self._begin_packed()
            while self.pos < e:
                out.append(
                    En.from_number(
                        Int(Int32(Int64(self._read_varint_raw())))
                    )
                )
                self._packed_bound(e, String("enum"))
            return
        out.append(self.read_enum[En]())

    def read_into_repeated_message[
        M: Serializable
    ](mut self, mut out: List[M]) raises:
        # One same-tag LEN occurrence per `next_field()` — append one decoded
        # message.
        out.append(self.read_message[M]())

    # -- map decode ------------------------------------------------------
    #
    # A `map<K,V>` entry on the wire is ONE length-delimited 2-field entry
    # sub-message (field 1 = key, field 2 = value) per `next_field()`. Decode
    # the entry sub-message into a fresh `PbDecoder` and insert one pair.

    def _entry_decoder(mut self) raises -> PbDecoder:
        """Carve the current LEN field's payload into a sub-decoder."""
        if self._cur_wire != PB_WIRE_LEN:
            raise Error("ProtobufError.WIRE_MISMATCH: expected LEN (map entry)")
        var f = pb_read_len_field(Span(self.backing), self.pos)
        self.pos = f.new_pos
        var sub = List[UInt8]()
        for i in range(f.payload_start, f.payload_end):
            sub.append(self.backing[i])
        # A map ENTRY is a sub-message and costs a level like any other — a
        # `map<string, M>` whose values are themselves maps recurses through
        # here, not only through `read_message`.
        return self._sub_decoder(sub^)

    def read_into_string_string_map(
        mut self, mut out: Dict[String, String]
    ) raises:
        var sub = self._entry_decoder()
        var k = String("")
        var val = String("")
        while True:
            var key = sub.next_field()
            if key.end:
                break
            if key.field_no == 1:
                k = sub.read_string()
            elif key.field_no == 2:
                val = sub.read_string()
            else:
                sub.skip()
        out[k] = val

    def read_into_string_i32_map(
        mut self, mut out: Dict[String, Int32]
    ) raises:
        var sub = self._entry_decoder()
        var k = String("")
        var val = Int32(0)
        while True:
            var key = sub.next_field()
            if key.end:
                break
            if key.field_no == 1:
                k = sub.read_string()
            elif key.field_no == 2:
                val = sub.read_i32()
            else:
                sub.skip()
        out[k] = val

    def read_into_i64_string_map(
        mut self, mut out: Dict[Int64, String]
    ) raises:
        var sub = self._entry_decoder()
        var k = Int64(0)
        var val = String("")
        while True:
            var key = sub.next_field()
            if key.end:
                break
            if key.field_no == 1:
                k = sub.read_i64()
            elif key.field_no == 2:
                val = sub.read_string()
            else:
                sub.skip()
        out[k] = val

    def read_into_string_message_map[
        V: Serializable & Deinitable
    ](mut self, mut out: Dict[String, V]) raises:
        # One entry sub-message per `next_field()`: field 1 = string key,
        # field 2 = the embedded `V` message (read via `read_message[V]`,
        # which carves the nested LEN payload into its own sub-decoder).
        var sub = self._entry_decoder()
        var k = String("")
        var val = Optional[V](None)
        while True:
            var key = sub.next_field()
            if key.end:
                break
            if key.field_no == 1:
                k = sub.read_string()
            elif key.field_no == 2:
                val = sub.read_message[V]()
            else:
                sub.skip()
        # An entry always carries a value field; a missing field-2 leaves the
        # value default (a V decoded from an empty buffer — all fields zero).
        if val:
            out[k] = val.take()
        else:
            # ⚠ DELIBERATELY NOT `_sub_decoder`. This decodes a default `V`
            # from ZERO bytes, so it cannot recurse at all — there is no field
            # to descend into — and routing it through the bound would let a
            # map entry with a missing value field be refused for depth at
            # exactly the level where nothing is nested.
            var empty_sub = PbDecoder(List[UInt8]())
            out[k] = V.decode[PbDecoder](empty_sub)

    # -- well-known-type fields: WIRE-IDENTICAL to the message arms -------

    @always_inline
    def read_wkt[T: Proto3JsonWkt](mut self) raises -> T:
        return self.read_message[T]()

    @always_inline
    def read_into_repeated_wkt[
        T: Proto3JsonWkt
    ](mut self, mut out: List[T]) raises:
        self.read_into_repeated_message[T](out)

    @always_inline
    def read_into_string_wkt_map[
        T: Proto3JsonWkt & Deinitable
    ](mut self, mut out: Dict[String, T]) raises:
        self.read_into_string_message_map[T](out)

    def skip(mut self) raises:
        self.pos = pb_skip_field(Span(self.backing), self.pos, self._cur_wire)

    def expect_fields(
        mut self, message_name: StringSlice, accepted: StringSlice
    ) raises:
        """No-op — the binary wire keys on field NUMBERS, not names.

        ⛔ THIS IS NOT AN UNIMPLEMENTED STUB. An unknown field NUMBER on the
        protobuf-binary wire MUST be skipped: that is the proto3 forward-
        compatibility contract, the whole reason a `skip()` exists on this
        backend, and refusing here would break every reader talking to a
        newer writer. The name vocabulary this method carries has no meaning
        on a wire that never transmits a name."""
        pass
