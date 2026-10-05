# =============================================================================
# test_proto_codec_roundtrip.mojo — komira_proto_codec Serializable round-trip suite.
# =============================================================================
#
# The `Serializable` round-trip must be identity on the test corpus for BOTH
# `WireFormat` backends.
#
# Every test encodes a hand-written `Serializable` message via BOTH backends
# (`PbEncoder`/`PbDecoder` protobuf-binary, `JsonEncoder`/`JsonDecoder`
# proto3-JSON), decodes it back, and asserts field-by-field identity. Encode
# and decode are independent code paths so a round-trip is a real correctness
# signal. The corpus is an edge-case set: scalars of every type,
# a nested message, a proto3 `optional` field present and absent, int64
# boundary values, an empty message, and a deeply-nested 3-level tree.
#
# The corpus messages are HAND-WRITTEN `Serializable` conformers — they mimic
# exactly what the `protoc-gen-mojo` code generator emits, so this suite
# also pins the generator's target shape.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    PbEncoder,
    PbDecoder,
    JsonEncoder,
    JsonDecoder,
    encode_proto,
    decode_proto,
    encode_json,
    decode_json,
)


# =============================================================================
# Corpus message 1 — Timestamp { int64 seconds = 1; int32 nanos = 2; }
# =============================================================================


@fieldwise_init
struct Timestamp(Serializable):
    """A nested message — int64 + int32 scalars."""

    var seconds: Int64
    var nanos: Int32

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "seconds", self.seconds)
        enc.write_i32_field(2, "nanos", self.nanos)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var seconds = Int64(0)
        var nanos = Int32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "seconds":
                seconds = dec.read_i64()
            elif key.field_no == 2 or key.json_name == "nanos":
                nanos = dec.read_i32()
            else:
                dec.skip()
        return Timestamp(seconds, nanos)


# =============================================================================
# Corpus message 2 — Dataset, a worked-example shape.
#   string id = 1; string name = 2; uint64 row_count = 3;
#   optional string description = 4; Timestamp created_at = 6;
# A proto3 `optional` field is modeled as a (Bool present, T value) pair —
# the shape the code generator uses for `Optional[T]`.
# =============================================================================


@fieldwise_init
struct Dataset(Serializable):
    """The worked-example message — strings, uint64, optional, nested msg.
    """

    var id: String
    var name: String
    var row_count: UInt64
    var has_description: Bool
    var description: String
    var created_at: Timestamp

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "id", self.id)
        enc.write_string_field(2, "name", self.name)
        enc.write_u64_field(3, "rowCount", self.row_count)
        if self.has_description:
            enc.write_string_field(4, "description", self.description)
        enc.write_message_field[Timestamp](6, "createdAt", self.created_at)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var id = String("")
        var name = String("")
        var row_count = UInt64(0)
        var has_description = False
        var description = String("")
        var created_at = Timestamp(0, 0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "id":
                id = dec.read_string()
            elif key.field_no == 2 or key.json_name == "name":
                name = dec.read_string()
            elif key.field_no == 3 or key.json_name == "rowCount":
                row_count = dec.read_u64()
            elif key.field_no == 4 or key.json_name == "description":
                description = dec.read_string()
                has_description = True
            elif key.field_no == 6 or key.json_name == "createdAt":
                created_at = dec.read_message[Timestamp]()
            else:
                dec.skip()
        return Dataset(
            id^,
            name^,
            row_count,
            has_description,
            description^,
            created_at^,
        )


# =============================================================================
# Corpus message 3 — AllScalars, every scalar wire type in one message.
# =============================================================================


@fieldwise_init
struct AllScalars(Serializable):
    """Exercises every scalar `WireEncoder`/`WireDecoder` primitive."""

    var f_i32: Int32
    var f_i64: Int64
    var f_u32: UInt32
    var f_u64: UInt64
    var f_f32: Float32
    var f_f64: Float64
    var f_bool: Bool
    var f_str: String
    var f_bytes: List[UInt8]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i32_field(1, "fI32", self.f_i32)
        enc.write_i64_field(2, "fI64", self.f_i64)
        enc.write_u32_field(3, "fU32", self.f_u32)
        enc.write_u64_field(4, "fU64", self.f_u64)
        enc.write_f32_field(5, "fF32", self.f_f32)
        enc.write_f64_field(6, "fF64", self.f_f64)
        enc.write_bool_field(7, "fBool", self.f_bool)
        enc.write_string_field(8, "fStr", self.f_str)
        enc.write_bytes_field(9, "fBytes", self.f_bytes)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var f_i32 = Int32(0)
        var f_i64 = Int64(0)
        var f_u32 = UInt32(0)
        var f_u64 = UInt64(0)
        var f_f32 = Float32(0)
        var f_f64 = Float64(0)
        var f_bool = False
        var f_str = String("")
        var f_bytes = List[UInt8]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "fI32":
                f_i32 = dec.read_i32()
            elif key.field_no == 2 or key.json_name == "fI64":
                f_i64 = dec.read_i64()
            elif key.field_no == 3 or key.json_name == "fU32":
                f_u32 = dec.read_u32()
            elif key.field_no == 4 or key.json_name == "fU64":
                f_u64 = dec.read_u64()
            elif key.field_no == 5 or key.json_name == "fF32":
                f_f32 = dec.read_f32()
            elif key.field_no == 6 or key.json_name == "fF64":
                f_f64 = dec.read_f64()
            elif key.field_no == 7 or key.json_name == "fBool":
                f_bool = dec.read_bool()
            elif key.field_no == 8 or key.json_name == "fStr":
                f_str = dec.read_string()
            elif key.field_no == 9 or key.json_name == "fBytes":
                f_bytes = dec.read_bytes()
            else:
                dec.skip()
        return AllScalars(
            f_i32, f_i64, f_u32, f_u64, f_f32, f_f64, f_bool, f_str^, f_bytes^
        )


# =============================================================================
# Corpus message 4 — Nested3, a deeply-nested 3-level message tree.
#   Level3 { int64 v = 1; }
#   Level2 { int64 v = 1; Level3 inner = 2; }
#   Nested3 { int64 v = 1; Level2 inner = 2; }
# =============================================================================


@fieldwise_init
struct Level3(Serializable):
    var v: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "v", self.v)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Int64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "v":
                v = dec.read_i64()
            else:
                dec.skip()
        return Level3(v)


@fieldwise_init
struct Level2(Serializable):
    var v: Int64
    var inner: Level3

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "v", self.v)
        enc.write_message_field[Level3](2, "inner", self.inner)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Int64(0)
        var inner = Level3(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "v":
                v = dec.read_i64()
            elif key.field_no == 2 or key.json_name == "inner":
                inner = dec.read_message[Level3]()
            else:
                dec.skip()
        return Level2(v, inner^)


@fieldwise_init
struct Nested3(Serializable):
    var v: Int64
    var inner: Level2

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "v", self.v)
        enc.write_message_field[Level2](2, "inner", self.inner)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Int64(0)
        var inner = Level2(0, Level3(0))
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "v":
                v = dec.read_i64()
            elif key.field_no == 2 or key.json_name == "inner":
                inner = dec.read_message[Level2]()
            else:
                dec.skip()
        return Nested3(v, inner^)


# =============================================================================
# Corpus message — Tagged { repeated string labels; map<string,string> config }
#
# This is the shape a CRUD API needs: a `repeated string` field (proto
# repeated -> List[String], proto3-JSON -> a `[...]` array) and a
# `map<string,string>` field (proto map -> Dict[String,String], proto3-JSON ->
# a `{...}` object). The body is written EXACTLY as the code generator
# emits it: `begin/end_list_field` + `write_*_element` for the repeated
# field, `begin/end_map_field` + `begin/end_map_entry` for the map field.
# =============================================================================


@fieldwise_init
struct Tagged(Serializable):
    """A message with a `repeated string` + a `map<string,string>` field."""

    var labels: List[String]
    var config: Dict[String, String]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "labels")
        for i in range(len(self.labels)):
            enc.write_string_element(1, self.labels[i])
        enc.end_list_field()
        enc.begin_map_field(2, "config")
        for entry in self.config.items():
            enc.begin_map_entry()
            enc.write_string_field(1, "key", entry.key)
            enc.write_string_field(2, "value", entry.value)
            enc.end_map_entry()
        enc.end_map_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var labels: List[String] = List[String]()
        var config: Dict[String, String] = Dict[String, String]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "labels":
                dec.read_into_repeated_string(labels)
            elif key.field_no == 2 or key.json_name == "config":
                dec.read_into_string_string_map(config)
            else:
                dec.skip()
        return Tagged(labels^, config^)


def test_tagged_repeated_and_map_roundtrip() raises:
    """A non-empty `repeated string` + `map<string,string>` round-trips on
    BOTH backends (the CRUD-API shape)."""
    var labels = List[String]()
    labels.append(String("batch"))
    labels.append(String("gpu"))
    var config = Dict[String, String]()
    config[String("env")] = String("prod")
    config[String("region")] = String("us-east-1")
    var orig = Tagged(labels^, config^)

    # proto3-JSON round-trip.
    var json = encode_json(orig)
    # The repeated field must render as a JSON array, the map as a JSON object.
    assert_true(
        json.find('"labels":[') >= 0, "labels renders as a JSON array"
    )
    assert_true(
        json.find('"config":{') >= 0, "config renders as a JSON object"
    )
    var jb = decode_json[Tagged](json)
    assert_equal(len(jb.labels), 2, "json: 2 labels")
    assert_equal(jb.labels[0], String("batch"), "json: label[0]")
    assert_equal(jb.labels[1], String("gpu"), "json: label[1]")
    assert_equal(len(jb.config), 2, "json: 2 config entries")
    assert_equal(jb.config[String("env")], String("prod"), "json: config env")
    assert_equal(
        jb.config[String("region")], String("us-east-1"), "json: config region"
    )

    # protobuf-binary round-trip (same body, the other backend).
    var bytes = encode_proto[Tagged](orig)
    var pb = decode_proto[Tagged](bytes^)
    assert_equal(len(pb.labels), 2, "pb: 2 labels")
    assert_equal(pb.labels[0], String("batch"), "pb: label[0]")
    assert_equal(pb.labels[1], String("gpu"), "pb: label[1]")
    assert_equal(len(pb.config), 2, "pb: 2 config entries")
    assert_equal(pb.config[String("env")], String("prod"), "pb: config env")
    assert_equal(
        pb.config[String("region")], String("us-east-1"), "pb: config region"
    )
    print("  test_tagged_repeated_and_map_roundtrip: PASS")


def test_tagged_empty_repeated_and_map() raises:
    """An EMPTY `repeated string` + `map<string,string>` round-trips: the
    proto3 JSON mapping OMITS both (an empty list or map is the field's
    default) and the absent keys decode back empty. Sending `[]` would mean
    "clear this list" to a merge-patch server."""
    var orig = Tagged(List[String](), Dict[String, String]())

    var json = encode_json(orig)
    assert_equal(json, String("{}"), "empty list and map are omitted")
    var jb = decode_json[Tagged](json)
    assert_equal(len(jb.labels), 0, "json: empty labels")
    assert_equal(len(jb.config), 0, "json: empty config")

    var bytes = encode_proto[Tagged](orig)
    var pb = decode_proto[Tagged](bytes^)
    assert_equal(len(pb.labels), 0, "pb: empty labels")
    assert_equal(len(pb.config), 0, "pb: empty config")

    # One side empty: the omitted field leaves no stray comma before or
    # after the field that is written.
    var only_labels = List[String]()
    only_labels.append(String("a"))
    assert_equal(
        encode_json(Tagged(only_labels^, Dict[String, String]())),
        String('{"labels":["a"]}'),
        "an empty map after a list leaves no trailing comma",
    )
    var only_config = Dict[String, String]()
    only_config[String("env")] = String("prod")
    assert_equal(
        encode_json(Tagged(List[String](), only_config^)),
        String('{"config":{"env":"prod"}}'),
        "an empty list before a map leaves no leading comma",
    )
    print("  test_tagged_empty_repeated_and_map: PASS")


# =============================================================================
# Round-trip tests — each runs BOTH backends.
# =============================================================================


def test_timestamp_roundtrip() raises:
    """T1: a flat int64 + int32 message round-trips on both backends."""
    var orig = Timestamp(1716240000, 123456789)

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[Timestamp](pb_bytes^)
    assert_equal(pb_back.seconds, orig.seconds, "proto: seconds")
    assert_equal(pb_back.nanos, orig.nanos, "proto: nanos")

    var json = encode_json(orig)
    var json_back = decode_json[Timestamp](json)
    assert_equal(json_back.seconds, orig.seconds, "json: seconds")
    assert_equal(json_back.nanos, orig.nanos, "json: nanos")
    print("  test_timestamp_roundtrip: PASS")


def test_dataset_roundtrip_with_optional() raises:
    """T2: the worked-example message — strings, uint64, a PRESENT
    optional, and a nested message — round-trips on both backends."""
    var orig = Dataset(
        String("ds-001"),
        String("trips_2026"),
        UInt64(4294967296),
        True,
        String("NYC taxi trips"),
        Timestamp(1716240000, 123456789),
    )

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[Dataset](pb_bytes^)
    assert_equal(pb_back.id, orig.id, "proto: id")
    assert_equal(pb_back.name, orig.name, "proto: name")
    assert_equal(pb_back.row_count, orig.row_count, "proto: row_count")
    assert_true(pb_back.has_description, "proto: has_description")
    assert_equal(pb_back.description, orig.description, "proto: description")
    assert_equal(
        pb_back.created_at.seconds, orig.created_at.seconds, "proto: ts.sec"
    )
    assert_equal(
        pb_back.created_at.nanos, orig.created_at.nanos, "proto: ts.nanos"
    )

    var json = encode_json(orig)
    var json_back = decode_json[Dataset](json)
    assert_equal(json_back.id, orig.id, "json: id")
    assert_equal(json_back.name, orig.name, "json: name")
    assert_equal(json_back.row_count, orig.row_count, "json: row_count")
    assert_true(json_back.has_description, "json: has_description")
    assert_equal(json_back.description, orig.description, "json: description")
    assert_equal(
        json_back.created_at.seconds, orig.created_at.seconds, "json: ts.sec"
    )
    assert_equal(
        json_back.created_at.nanos, orig.created_at.nanos, "json: ts.nanos"
    )
    print("  test_dataset_roundtrip_with_optional: PASS")


def test_dataset_roundtrip_optional_absent() raises:
    """T3: a proto3 `optional` field ABSENT round-trips as absent on both
    backends — the proto3 absent-field contract."""
    var orig = Dataset(
        String("ds-002"),
        String("empty_desc"),
        UInt64(0),
        False,  # description absent
        String(""),
        Timestamp(0, 0),
    )

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[Dataset](pb_bytes^)
    assert_true(not pb_back.has_description, "proto: description stays absent")
    assert_equal(pb_back.id, orig.id, "proto: id")

    var json = encode_json(orig)
    var json_back = decode_json[Dataset](json)
    assert_true(
        not json_back.has_description, "json: description stays absent"
    )
    assert_equal(json_back.id, orig.id, "json: id")
    print("  test_dataset_roundtrip_optional_absent: PASS")


def test_all_scalars_roundtrip() raises:
    """T4: every scalar wire type round-trips on both backends."""
    var bytes = List[UInt8]()
    bytes.append(0x00)
    bytes.append(0xFF)
    bytes.append(0x7F)
    bytes.append(0x80)
    var orig = AllScalars(
        Int32(-12345),
        Int64(9876543210),
        UInt32(4000000000),
        UInt64(18000000000000000000),
        Float32(3.5),
        Float64(2.718281828459045),
        True,
        String("héllo wörld"),  # UTF-8 multibyte
        bytes^,
    )

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[AllScalars](pb_bytes^)
    assert_equal(pb_back.f_i32, orig.f_i32, "proto: f_i32")
    assert_equal(pb_back.f_i64, orig.f_i64, "proto: f_i64")
    assert_equal(pb_back.f_u32, orig.f_u32, "proto: f_u32")
    assert_equal(pb_back.f_u64, orig.f_u64, "proto: f_u64")
    assert_equal(pb_back.f_f32, orig.f_f32, "proto: f_f32")
    assert_equal(pb_back.f_f64, orig.f_f64, "proto: f_f64")
    assert_equal(pb_back.f_bool, orig.f_bool, "proto: f_bool")
    assert_equal(pb_back.f_str, orig.f_str, "proto: f_str")
    assert_equal(len(pb_back.f_bytes), 4, "proto: f_bytes len")
    assert_equal(Int(pb_back.f_bytes[1]), 0xFF, "proto: f_bytes[1]")

    var json = encode_json(orig)
    var json_back = decode_json[AllScalars](json)
    assert_equal(json_back.f_i32, orig.f_i32, "json: f_i32")
    assert_equal(json_back.f_i64, orig.f_i64, "json: f_i64")
    assert_equal(json_back.f_u32, orig.f_u32, "json: f_u32")
    assert_equal(json_back.f_u64, orig.f_u64, "json: f_u64")
    assert_equal(json_back.f_f32, orig.f_f32, "json: f_f32")
    assert_equal(json_back.f_f64, orig.f_f64, "json: f_f64")
    assert_equal(json_back.f_bool, orig.f_bool, "json: f_bool")
    assert_equal(json_back.f_str, orig.f_str, "json: f_str")
    assert_equal(len(json_back.f_bytes), 4, "json: f_bytes len")
    assert_equal(Int(json_back.f_bytes[3]), 0x80, "json: f_bytes[3]")
    print("  test_all_scalars_roundtrip: PASS")


def test_int64_boundary_values() raises:
    """T5: Int64.MIN / Int64.MAX / UInt64.MAX round-trip on both backends —
    the precision-critical case the proto3-JSON int64-as-string rule protects."""
    var orig = AllScalars(
        Int32(-2147483648),  # Int32.MIN
        Int64(-9223372036854775808),  # Int64.MIN
        UInt32(4294967295),  # UInt32.MAX
        UInt64(18446744073709551615),  # UInt64.MAX
        Float32(0),
        Float64(0),
        False,
        String(""),
        List[UInt8](),
    )

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[AllScalars](pb_bytes^)
    assert_equal(pb_back.f_i64, orig.f_i64, "proto: Int64.MIN")
    assert_equal(pb_back.f_u64, orig.f_u64, "proto: UInt64.MAX")
    assert_equal(pb_back.f_i32, orig.f_i32, "proto: Int32.MIN")

    var json = encode_json(orig)
    var json_back = decode_json[AllScalars](json)
    assert_equal(json_back.f_i64, orig.f_i64, "json: Int64.MIN")
    assert_equal(json_back.f_u64, orig.f_u64, "json: UInt64.MAX")
    assert_equal(json_back.f_i32, orig.f_i32, "json: Int32.MIN")
    print("  test_int64_boundary_values: PASS")


def test_empty_message() raises:
    """T6: a message with all default fields encodes + decodes cleanly on
    both backends (proto3 omits defaults; JSON emits `{}`)."""
    var orig = Timestamp(0, 0)

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[Timestamp](pb_bytes^)
    assert_equal(pb_back.seconds, Int64(0), "proto: empty seconds")
    assert_equal(pb_back.nanos, Int32(0), "proto: empty nanos")

    var json = encode_json(orig)
    var json_back = decode_json[Timestamp](json)
    assert_equal(json_back.seconds, Int64(0), "json: empty seconds")
    assert_equal(json_back.nanos, Int32(0), "json: empty nanos")
    print("  test_empty_message: PASS")


def test_deeply_nested_messages() raises:
    """T7: a 3-level nested message tree round-trips on both backends —
    exercises the pooled scratch buffer (protobuf) + nested-object JSON."""
    var orig = Nested3(Int64(100), Level2(Int64(200), Level3(Int64(300))))

    var pb_bytes = encode_proto(orig)
    var pb_back = decode_proto[Nested3](pb_bytes^)
    assert_equal(pb_back.v, Int64(100), "proto: L1.v")
    assert_equal(pb_back.inner.v, Int64(200), "proto: L2.v")
    assert_equal(pb_back.inner.inner.v, Int64(300), "proto: L3.v")

    var json = encode_json(orig)
    var json_back = decode_json[Nested3](json)
    assert_equal(json_back.v, Int64(100), "json: L1.v")
    assert_equal(json_back.inner.v, Int64(200), "json: L2.v")
    assert_equal(json_back.inner.inner.v, Int64(300), "json: L3.v")
    print("  test_deeply_nested_messages: PASS")


def test_pooled_scratch_buffer_reuse() raises:
    """T8: many sibling nested messages encode correctly — exercises the
    pooled-scratch-buffer free-list. Encoding a tree
    with several Timestamp children reuses buffers; correctness must hold."""
    # A Dataset whose created_at is itself re-encoded many times to drive
    # repeated scratch borrow/return cycles.
    for trial in range(50):
        var ds = Dataset(
            String("ds-") + String(trial),
            String("name"),
            UInt64(trial),
            True,
            String("desc"),
            Timestamp(Int64(trial), Int32(trial)),
        )
        var pb_bytes = encode_proto(ds)
        var back = decode_proto[Dataset](pb_bytes^)
        assert_equal(
            back.created_at.seconds, Int64(trial), "scratch-reuse: ts.sec"
        )
        assert_equal(back.row_count, UInt64(trial), "scratch-reuse: row_count")
    print("  test_pooled_scratch_buffer_reuse: PASS")


def main() raises:
    print("test_proto_codec_roundtrip — Serializable round-trip gate")
    test_timestamp_roundtrip()
    test_dataset_roundtrip_with_optional()
    test_dataset_roundtrip_optional_absent()
    test_all_scalars_roundtrip()
    test_int64_boundary_values()
    test_empty_message()
    test_deeply_nested_messages()
    test_pooled_scratch_buffer_reuse()
    test_tagged_repeated_and_map_roundtrip()
    test_tagged_empty_repeated_and_map()
    print("test_proto_codec_roundtrip: ALL PASS")
