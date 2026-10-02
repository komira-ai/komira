# =============================================================================
# test_wkt_json_codec_path.mojo — WKT fields through the GENERATED code path.
# =============================================================================
#
# `test_wkt_runtime.mojo` calls `to_/from_proto3_json` by hand. A generated
# client never does: it calls `encode_json` / `decode_json` on a message that
# CONTAINS a WKT field, and the codec decides the field's JSON shape. This
# suite drives exactly that path, through a hand-written message shaped like
# what the code generator emits for Cloud Logging v2's `LogEntry`:
#
#   - `write_message_field` / `write_message_element` + `read_message` /
#     `read_into_repeated_message` / `read_into_string_message_map` -- the
#     plain message arms, which give a WKT its canonical form;
#   - `Optional[T]` message fields, `expect_fields` + the `next_field` loop;
#   - a `map<string, string>` (labels) next to a `map<string, Value>`.
#
# Every assertion is on EXACT canonical bytes (encode) or on the decoded
# field values (decode), and the decode cases include a SERVER-SHAPED body:
# RFC 3339 timestamps, a free-form `jsonPayload` object and an `@type`d
# `protoPayload`, none of which the binary-shaped message bodies can read.
# The protobuf-binary twin of every case asserts the arms are wire-identical
# to the plain message arms.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    encode_json,
    decode_json,
    decode_json_lenient,
    encode_proto,
    decode_proto,
)
from komira_wkt import (
    Any,
    Timestamp,
    Duration,
    Empty,
    FieldMask,
    Struct,
    Value,
    ListValue,
    BoolValue,
    Int64Value,
    UInt64Value,
    Int32Value,
    UInt32Value,
    DoubleValue,
    FloatValue,
    StringValue,
    BytesValue,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
    VALUE_KIND_BOOL,
    VALUE_KIND_STRUCT,
    VALUE_KIND_LIST,
)


# =============================================================================
# Generated-equivalent messages.
# =============================================================================


@fieldwise_init
struct HttpRequestLike(Serializable, Copyable, Movable):
    """`google.logging.type.HttpRequest`, reduced to its Duration field."""

    var request_method: String
    var latency: Optional[Duration]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.request_method != "":
            enc.write_string_field(1, "requestMethod", self.request_method)
        if self.latency:
            enc.write_message_field[Duration](14, "latency", self.latency.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields(
            "HttpRequest", "requestMethod|request_method,latency"
        )
        var request_method = String("")
        var latency = Optional[Duration](None)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "requestMethod" or key.json_name == "request_method":
                request_method = dec.read_string()
            elif key.field_no == 14 or key.json_name == "latency":
                latency = dec.read_message[Duration]()
            else:
                dec.skip()
        return Self(request_method^, latency^)


@fieldwise_init
struct LogEntryLike(Serializable, Copyable, Movable):
    """`google.logging.v2.LogEntry`, with every WKT shape it carries plus the
    repeated / map forms of a WKT field."""

    var log_name: String
    var timestamp: Optional[Timestamp]
    var receive_timestamp: Optional[Timestamp]
    var json_payload: Optional[Struct]
    var proto_payload: Optional[Any]
    var labels: Dict[String, String]
    var http_request: Optional[HttpRequestLike]
    var update_mask: Optional[FieldMask]
    var trace_sampled: Optional[BoolValue]
    var severity_number: Optional[Int64Value]
    var checkpoints: List[Timestamp]
    var attrs: Dict[String, Value]

    @staticmethod
    def new() -> Self:
        return Self(
            String(""),
            None,
            None,
            None,
            None,
            Dict[String, String](),
            None,
            None,
            None,
            None,
            List[Timestamp](),
            Dict[String, Value](),
        )

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.log_name != "":
            enc.write_string_field(12, "logName", self.log_name)
        if self.timestamp:
            enc.write_message_field[Timestamp](9, "timestamp", self.timestamp.value())
        if self.receive_timestamp:
            enc.write_message_field[Timestamp](
                24, "receiveTimestamp", self.receive_timestamp.value()
            )
        if self.json_payload:
            enc.write_message_field[Struct](6, "jsonPayload", self.json_payload.value())
        if self.proto_payload:
            enc.write_message_field[Any](2, "protoPayload", self.proto_payload.value())
        if len(self.labels) > 0:
            enc.begin_map_field(11, "labels")
            for entry in self.labels.items():
                enc.begin_map_entry()
                enc.write_string_field(1, "key", entry.key)
                enc.write_string_field(2, "value", entry.value)
                enc.end_map_entry()
            enc.end_map_field()
        if self.http_request:
            enc.write_message_field[HttpRequestLike](
                7, "httpRequest", self.http_request.value()
            )
        if self.update_mask:
            enc.write_message_field[FieldMask](30, "updateMask", self.update_mask.value())
        if self.trace_sampled:
            enc.write_message_field[BoolValue](31, "traceSampled", self.trace_sampled.value())
        if self.severity_number:
            enc.write_message_field[Int64Value](
                32, "severityNumber", self.severity_number.value()
            )
        if len(self.checkpoints) > 0:
            enc.begin_list_field(33, "checkpoints")
            for i in range(len(self.checkpoints)):
                enc.write_message_element[Timestamp](33, self.checkpoints[i])
            enc.end_list_field()
        if len(self.attrs) > 0:
            enc.begin_map_field(34, "attrs")
            for entry in self.attrs.items():
                enc.begin_map_entry()
                enc.write_string_field(1, "key", entry.key)
                enc.write_message_field[Value](2, "value", entry.value)
                enc.end_map_entry()
            enc.end_map_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields(
            "LogEntry",
            "logName|log_name,timestamp,receiveTimestamp|receive_timestamp,"
            + "jsonPayload|json_payload,protoPayload|proto_payload,labels,"
            + "httpRequest|http_request,updateMask|update_mask,"
            + "traceSampled|trace_sampled,severityNumber|severity_number,"
            + "checkpoints,attrs",
        )
        var out = Self.new()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            var n = key.json_name
            if key.field_no == 12 or n == "logName" or n == "log_name":
                out.log_name = dec.read_string()
            elif key.field_no == 9 or n == "timestamp":
                out.timestamp = dec.read_message[Timestamp]()
            elif key.field_no == 24 or n == "receiveTimestamp" or n == "receive_timestamp":
                out.receive_timestamp = dec.read_message[Timestamp]()
            elif key.field_no == 6 or n == "jsonPayload" or n == "json_payload":
                out.json_payload = dec.read_message[Struct]()
            elif key.field_no == 2 or n == "protoPayload" or n == "proto_payload":
                out.proto_payload = dec.read_message[Any]()
            elif key.field_no == 11 or n == "labels":
                dec.read_into_string_string_map(out.labels)
            elif key.field_no == 7 or n == "httpRequest" or n == "http_request":
                out.http_request = dec.read_message[HttpRequestLike]()
            elif key.field_no == 30 or n == "updateMask" or n == "update_mask":
                out.update_mask = dec.read_message[FieldMask]()
            elif key.field_no == 31 or n == "traceSampled" or n == "trace_sampled":
                out.trace_sampled = dec.read_message[BoolValue]()
            elif key.field_no == 32 or n == "severityNumber" or n == "severity_number":
                out.severity_number = dec.read_message[Int64Value]()
            elif key.field_no == 33 or n == "checkpoints":
                dec.read_into_repeated_message[Timestamp](out.checkpoints)
            elif key.field_no == 34 or n == "attrs":
                dec.read_into_string_message_map[Value](out.attrs)
            else:
                dec.skip()
        return out^


@fieldwise_init
struct ListEntriesResponseLike(Serializable, Copyable, Movable):
    """`google.logging.v2.ListLogEntriesResponse`."""

    var entries: List[LogEntryLike]
    var next_page_token: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "entries")
        for i in range(len(self.entries)):
            enc.write_message_element[LogEntryLike](1, self.entries[i])
        enc.end_list_field()
        if self.next_page_token != "":
            enc.write_string_field(2, "nextPageToken", self.next_page_token)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields(
            "ListLogEntriesResponse", "entries,nextPageToken|next_page_token"
        )
        var entries = List[LogEntryLike]()
        var token = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "entries":
                dec.read_into_repeated_message[LogEntryLike](entries)
            elif key.field_no == 2 or key.json_name == "nextPageToken" or key.json_name == "next_page_token":
                token = dec.read_string()
            else:
                dec.skip()
        return Self(entries^, token^)


# A message carrying every remaining WKT once, so each one's JSON arm is
# byte-checked through the codec (not through its own method).
@fieldwise_init
struct AllWktLike(Serializable, Copyable, Movable):
    var empty: Optional[Empty]
    var u64: Optional[UInt64Value]
    var i32: Optional[Int32Value]
    var dbl: Optional[DoubleValue]
    var str: Optional[StringValue]
    var byt: Optional[BytesValue]
    var lst: Optional[ListValue]
    var val: Optional[Value]
    var f32: Optional[FloatValue]
    var u32: Optional[UInt32Value]

    @staticmethod
    def new() -> Self:
        return Self(None, None, None, None, None, None, None, None, None, None)

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.empty:
            enc.write_message_field[Empty](1, "empty", self.empty.value())
        if self.u64:
            enc.write_message_field[UInt64Value](2, "u64", self.u64.value())
        if self.i32:
            enc.write_message_field[Int32Value](3, "i32", self.i32.value())
        if self.dbl:
            enc.write_message_field[DoubleValue](4, "dbl", self.dbl.value())
        if self.str:
            enc.write_message_field[StringValue](5, "str", self.str.value())
        if self.byt:
            enc.write_message_field[BytesValue](6, "byt", self.byt.value())
        if self.lst:
            enc.write_message_field[ListValue](7, "lst", self.lst.value())
        if self.val:
            enc.write_message_field[Value](8, "val", self.val.value())
        if self.f32:
            enc.write_message_field[FloatValue](9, "f32", self.f32.value())
        if self.u32:
            enc.write_message_field[UInt32Value](10, "u32", self.u32.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields(
            "AllWkt", "empty,u64,i32,dbl,str,byt,lst,val,f32,u32"
        )
        var out = Self.new()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            var n = key.json_name
            if key.field_no == 1 or n == "empty":
                out.empty = dec.read_message[Empty]()
            elif key.field_no == 2 or n == "u64":
                out.u64 = dec.read_message[UInt64Value]()
            elif key.field_no == 3 or n == "i32":
                out.i32 = dec.read_message[Int32Value]()
            elif key.field_no == 4 or n == "dbl":
                out.dbl = dec.read_message[DoubleValue]()
            elif key.field_no == 5 or n == "str":
                out.str = dec.read_message[StringValue]()
            elif key.field_no == 6 or n == "byt":
                out.byt = dec.read_message[BytesValue]()
            elif key.field_no == 7 or n == "lst":
                out.lst = dec.read_message[ListValue]()
            elif key.field_no == 8 or n == "val":
                out.val = dec.read_message[Value]()
            elif key.field_no == 9 or n == "f32":
                out.f32 = dec.read_message[FloatValue]()
            elif key.field_no == 10 or n == "u32":
                out.u32 = dec.read_message[UInt32Value]()
            else:
                dec.skip()
        return out^


# A `map<string, Timestamp>`: the map arm's error-path suffix needs a value
# type that CAN refuse, and `attrs` (`map<string, Value>`) cannot — every
# JSON value is a valid `google.protobuf.Value`.
@fieldwise_init
struct StampMapLike(Serializable, Copyable, Movable):
    var stamps: Dict[String, Timestamp]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if len(self.stamps) > 0:
            enc.begin_map_field(1, "stamps")
            for entry in self.stamps.items():
                enc.begin_map_entry()
                enc.write_string_field(1, "key", entry.key)
                enc.write_message_field[Timestamp](2, "value", entry.value)
                enc.end_map_entry()
            enc.end_map_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("StampMap", "stamps")
        var stamps = Dict[String, Timestamp]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "stamps":
                dec.read_into_string_message_map[Timestamp](stamps)
            else:
                dec.skip()
        return Self(stamps^)


# =============================================================================
# Fixtures.
# =============================================================================


def _bytes2(a: UInt8, b: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(a)
    out.append(b)
    return out^


def _bytes4(a: UInt8, b: UInt8, c: UInt8, d: UInt8) -> List[UInt8]:
    var out = _bytes2(a, b)
    out.append(c)
    out.append(d)
    return out^


def _sample_entry() raises -> LogEntryLike:
    var e = LogEntryLike.new()
    e.log_name = String("projects/example-project/logs/app")
    e.timestamp = Timestamp(Int64(1790812800), Int32(500000000))
    e.receive_timestamp = Timestamp(Int64(1790812801), Int32(123000))
    var inner = Struct.new()
    inner.put(String("b"), Value.boolean(True))
    var arr = ListValue.new()
    arr.add(Value.number(Float64(1.5)))
    arr.add(Value.string(String("x")))
    arr.add(Value.null())
    arr.add(Value.struct_(inner^))
    var payload = Struct.new()
    payload.put(String("message"), Value.string(String("hi")))
    payload.put(String("a"), Value.list(arr^))
    e.json_payload = payload^
    e.labels[String("env")] = String("gamma")
    var hr = HttpRequestLike(String("GET"), Duration(Int64(0), Int32(250000000)))
    e.http_request = hr^
    var fm = FieldMask.new()
    fm.paths.append(String("log_name"))
    fm.paths.append(String("json_payload.message"))
    e.update_mask = fm^
    e.trace_sampled = BoolValue(False)
    e.severity_number = Int64Value(Int64(9007199254740993))
    e.checkpoints.append(Timestamp(Int64(0), Int32(0)))
    e.checkpoints.append(Timestamp(Int64(86400), Int32(1)))
    e.attrs[String("n")] = Value.number(Float64(2.0))
    return e^


comptime _SAMPLE_JSON = (
    '{"logName":"projects/example-project/logs/app",'
    + '"timestamp":"2026-10-01T00:00:00.500Z",'
    + '"receiveTimestamp":"2026-10-01T00:00:01.000123Z",'
    + '"jsonPayload":{"message":"hi","a":[1.5,"x",null,{"b":true}]},'
    + '"labels":{"env":"gamma"},'
    + '"httpRequest":{"requestMethod":"GET","latency":"0.250s"},'
    + '"updateMask":"logName,jsonPayload.message",'
    + '"traceSampled":false,'
    + '"severityNumber":"9007199254740993",'
    + '"checkpoints":["1970-01-01T00:00:00Z","1970-01-02T00:00:00.000000001Z"],'
    + '"attrs":{"n":2}}'
)


# =============================================================================
# M2: the LogEntry round trip through encode_json / decode_json.
# =============================================================================


def test_logentry_encode_json_is_canonical() raises:
    """encode_json renders every WKT field in its canonical JSON form."""
    assert_equal(encode_json[LogEntryLike](_sample_entry()), String(_SAMPLE_JSON))


def test_logentry_decode_json_roundtrip() raises:
    """decode_json reads the canonical form back to the same values, and
    re-encoding reproduces the bytes."""
    var e = decode_json[LogEntryLike](String(_SAMPLE_JSON))
    assert_equal(e.log_name, String("projects/example-project/logs/app"))
    assert_equal(e.timestamp.value().seconds, Int64(1790812800))
    assert_equal(e.timestamp.value().nanos, Int32(500000000))
    assert_equal(e.receive_timestamp.value().nanos, Int32(123000))
    var p = e.json_payload.value().copy()
    assert_equal(len(p.keys), 2)
    assert_equal(p.keys[1], String("a"))
    assert_equal(p.values[1].kind, VALUE_KIND_LIST)
    assert_equal(p.values[1].list_value[0].values[2].kind, VALUE_KIND_NULL)
    assert_equal(e.labels[String("env")], String("gamma"))
    assert_equal(
        e.http_request.value().latency.value().nanos, Int32(250000000)
    )
    assert_equal(e.update_mask.value().paths[1], String("json_payload.message"))
    assert_false(e.trace_sampled.value().value)
    assert_equal(e.severity_number.value().value, Int64(9007199254740993))
    assert_equal(len(e.checkpoints), 2)
    assert_equal(e.checkpoints[1].nanos, Int32(1))
    assert_equal(e.attrs[String("n")].number_value, Float64(2.0))
    assert_equal(encode_json[LogEntryLike](e), String(_SAMPLE_JSON))


def test_logentry_binary_is_wire_identical() raises:
    """On protobuf-binary the WKT arms ARE the message arms: the bytes equal
    a hand-framed message-field encoding, and they round-trip."""
    var e = _sample_entry()
    var b = encode_proto[LogEntryLike](e)
    var back = decode_proto[LogEntryLike](b^)
    assert_equal(encode_json[LogEntryLike](back), String(_SAMPLE_JSON))
    # Field 9 (timestamp) framed by hand: tag 0x4A, len, then the Timestamp's
    # own binary body — the exact bytes `write_message_field` produces.
    var one = LogEntryLike.new()
    one.timestamp = Timestamp(Int64(1), Int32(2))
    var got = encode_proto[LogEntryLike](one)
    var body = encode_proto[Timestamp](Timestamp(Int64(1), Int32(2)))
    assert_equal(len(got), 2 + len(body))
    assert_equal(got[0], UInt8(0x4A))
    assert_equal(Int(got[1]), len(body))
    for i in range(len(body)):
        assert_equal(got[2 + i], body[i])


def test_server_shaped_logging_response() raises:
    """A Cloud Logging `entries.list`-shaped body as the server sends it."""
    var body = String(
        '{"entries":[{"logName":"projects/example-project/logs/app",'
        + '"timestamp":"2026-10-01T00:00:00.123Z",'
        + '"receiveTimestamp":"2026-10-01T00:00:00.456789Z",'
        + '"jsonPayload":{"a":[1,"x",null,{"b":true}]},'
        + '"protoPayload":{"@type":"type.googleapis.com/google.cloud.audit.AuditLog",'
        + '"methodName":"SetIamPolicy","status":{"code":7}},'
        + '"labels":{"zone":"us-central1-a"},'
        + '"httpRequest":{"latency":"0.250s"}},'
        + '{"logName":"projects/example-project/logs/app"}],'
        + '"nextPageToken":"tok"}'
    )
    var resp = decode_json_lenient[ListEntriesResponseLike](body)
    assert_equal(len(resp.entries), 2)
    assert_equal(resp.next_page_token, String("tok"))
    ref e = resp.entries[0]
    assert_equal(e.timestamp.value().seconds, Int64(1790812800))
    assert_equal(e.timestamp.value().nanos, Int32(123000000))
    assert_equal(e.receive_timestamp.value().nanos, Int32(456789000))
    # A REAL object decodes to a POPULATED Struct (not an empty one).
    var p = e.json_payload.value().copy()
    assert_equal(len(p.keys), 1)
    assert_equal(p.keys[0], String("a"))
    ref arr = p.values[0].list_value[0]
    assert_equal(len(arr.values), 4)
    assert_equal(arr.values[0].kind, VALUE_KIND_NUMBER)
    assert_equal(arr.values[0].number_value, Float64(1.0))
    assert_equal(arr.values[1].string_value, String("x"))
    assert_equal(arr.values[2].kind, VALUE_KIND_NULL)
    assert_equal(arr.values[3].kind, VALUE_KIND_STRUCT)
    assert_true(arr.values[3].struct_value[0].values[0].bool_value)
    # The opaque Any keeps its type and every member it did not interpret.
    var a = e.proto_payload.value().copy()
    assert_equal(
        a.type_url, String("type.googleapis.com/google.cloud.audit.AuditLog")
    )
    assert_equal(e.labels[String("zone")], String("us-central1-a"))
    assert_equal(e.http_request.value().latency.value().nanos, Int32(250000000))
    assert_false(Bool(resp.entries[1].timestamp))
    # Re-encoding preserves the Any's unknown content byte-for-byte.
    var again = encode_json[LogEntryLike](resp.entries[0])
    assert_true(
        String(
            '"protoPayload":{"@type":"type.googleapis.com/google.cloud.audit.AuditLog",'
            + '"methodName":"SetIamPolicy","status":{"code":7}}'
        )
        in again
    )
    assert_true(String('"timestamp":"2026-10-01T00:00:00.123Z"') in again)
    assert_true(String('"jsonPayload":{"a":[1,"x",null,{"b":true}]}') in again)


# =============================================================================
# The remaining WKTs through the codec.
# =============================================================================


def test_all_wkt_json_forms() raises:
    var lv = ListValue.new()
    lv.add(Value.boolean(True))
    var m = AllWktLike(
        Empty.new(),
        UInt64Value(UInt64(18446744073709551615)),
        Int32Value(Int32(-7)),
        DoubleValue(Float64(0.5)),
        StringValue(String('a"b')),
        BytesValue(_bytes4(0x00, 0x01, 0xFF, 0x42)),
        lv^,
        Value.string(String("v")),
        FloatValue(Float32(-0.25)),
        UInt32Value(UInt32(4294967295)),
    )
    var doc = String(
        '{"empty":{},"u64":"18446744073709551615","i32":-7,"dbl":0.5,'
        + '"str":"a\\"b","byt":"AAH/Qg==","lst":[true],"val":"v",'
        + '"f32":-0.25,"u32":4294967295}'
    )
    assert_equal(encode_json[AllWktLike](m), doc)
    var back = decode_json[AllWktLike](doc)
    assert_equal(back.u64.value().value, UInt64(18446744073709551615))
    assert_equal(back.i32.value().value, Int32(-7))
    assert_equal(back.str.value().value, String('a"b'))
    assert_equal(back.byt.value().value[2], UInt8(0xFF))
    assert_true(back.lst.value().values[0].bool_value)
    assert_equal(back.f32.value().value, Float32(-0.25))
    assert_equal(back.u32.value().value, UInt32(4294967295))
    assert_equal(encode_json[AllWktLike](back), doc)
    # UInt32Value's range check: 2^32 is refused, never truncated to 0.
    with assert_raises(contains="UInt32Value out of range"):
        _ = decode_json[AllWktLike](String('{"u32":4294967296}'))
    with assert_raises(contains="UInt32Value out of range"):
        _ = decode_json[AllWktLike](String('{"u32":"4294967296"}'))
    # Binary round trip of the same message.
    var b = encode_proto[AllWktLike](m)
    assert_equal(encode_json[AllWktLike](decode_proto[AllWktLike](b^)), doc)


def test_wrapper_json_accepts_spec_spellings() raises:
    """64-bit wrappers accept a JSON number as well as a string; a double
    wrapper reads and writes the spec's NaN / Infinity strings; a JSON null
    leaves the wrapper ABSENT (distinct from a zero wrapper)."""
    var back = decode_json[AllWktLike](
        String('{"u64":42,"dbl":"-Infinity","i32":null}')
    )
    assert_equal(back.u64.value().value, UInt64(42))
    assert_true(back.dbl.value().value < Float64(-1.0e308))
    assert_false(Bool(back.i32))
    var zero = decode_json[AllWktLike](String('{"i32":0}'))
    assert_equal(zero.i32.value().value, Int32(0))
    var ninf = AllWktLike.new()
    ninf.dbl = DoubleValue(back.dbl.value().value)
    assert_equal(encode_json[AllWktLike](ninf), String('{"dbl":"-Infinity"}'))
    # The other two non-finite spellings, both directions. A missing write
    # branch would fall through to the number formatter, which renders a
    # non-finite double as `null` — turning a PRESENT wrapper into an absent
    # one on the next decode.
    var pinf_doc = String('{"dbl":"Infinity"}')
    var pinf = decode_json[AllWktLike](pinf_doc)
    assert_true(pinf.dbl.value().value > Float64(1.7976931348623157e308))
    assert_equal(encode_json[AllWktLike](pinf), pinf_doc)
    var nan_doc = String('{"dbl":"NaN"}')
    var nan = decode_json[AllWktLike](nan_doc)
    var nv = nan.dbl.value().value
    assert_true(nv != nv)
    assert_equal(encode_json[AllWktLike](nan), nan_doc)
    var fresh = AllWktLike.new()
    var big = Float64(1.0e308) * Float64(10.0)
    fresh.dbl = DoubleValue(big - big)
    assert_equal(encode_json[AllWktLike](fresh), nan_doc)
    fresh.dbl = DoubleValue(big)
    assert_equal(encode_json[AllWktLike](fresh), pinf_doc)
    with assert_raises():
        _ = decode_json[AllWktLike](String('{"i32":2147483648}'))


def test_any_json_and_binary() raises:
    """The opaque Any: `@type` + raw bytes on binary, `@type` + the opaque
    remaining members on JSON; neither form is transcoded without a type
    registry, and that refusal is loud."""
    var doc = String(
        '{"protoPayload":{"@type":"type.googleapis.com/x.Y","k":[1,{"z":null}]}}'
    )
    var e = decode_json[LogEntryLike](doc)
    assert_equal(encode_json[LogEntryLike](e), doc)
    with assert_raises(contains="type registry"):
        _ = encode_proto[LogEntryLike](e)

    var bin = LogEntryLike.new()
    bin.proto_payload = Any(
        String("type.googleapis.com/x.Y"),
        _bytes2(0x08, 0x01),
    )
    var bytes = encode_proto[LogEntryLike](bin)
    var bback = decode_proto[LogEntryLike](bytes^)
    var a = bback.proto_payload.value().copy()
    assert_equal(a.type_url, String("type.googleapis.com/x.Y"))
    assert_equal(len(a.value), 2)
    assert_equal(a.value[1], UInt8(0x01))
    with assert_raises(contains="type registry"):
        _ = encode_json[LogEntryLike](bback)
    # An Any with a type and no payload is representable in both forms.
    var bare = LogEntryLike.new()
    bare.proto_payload = Any(String("type.googleapis.com/x.Y"), List[UInt8]())
    assert_equal(
        encode_json[LogEntryLike](bare),
        String('{"protoPayload":{"@type":"type.googleapis.com/x.Y"}}'),
    )
    with assert_raises(contains="@type"):
        _ = decode_json[LogEntryLike](String('{"protoPayload":{"k":1}}'))


# =============================================================================
# Refusals the canonical forms require.
# =============================================================================


def test_timestamp_json_refusals() raises:
    var bad = List[String]()
    bad.append(String('{"timestamp":"2026-10-01T00:00:00Zjunk"}'))
    bad.append(String('{"timestamp":"2026-13-01T00:00:00Z"}'))
    bad.append(String('{"timestamp":"2026-02-30T00:00:00Z"}'))
    # February's length is DERIVED: 2026 is not a leap year, 1900 is a
    # century that is not one; and a 30-day month has no 31st.
    bad.append(String('{"timestamp":"2026-02-29T00:00:00Z"}'))
    bad.append(String('{"timestamp":"1900-02-29T00:00:00Z"}'))
    bad.append(String('{"timestamp":"2026-04-31T00:00:00Z"}'))
    bad.append(String('{"timestamp":"2026-10-01T24:00:00Z"}'))
    bad.append(String('{"timestamp":"2026-10-01T00:60:00Z"}'))
    bad.append(String('{"timestamp":"0000-01-01T00:00:00Z"}'))
    bad.append(String('{"timestamp":1790812800}'))
    for i in range(len(bad)):
        with assert_raises():
            _ = decode_json[LogEntryLike](bad[i])
    # ... and the leap days that DO exist are accepted: 2024 (divisible by
    # 4) and 2000 (a century divisible by 400).
    var leap = decode_json[LogEntryLike](
        String('{"timestamp":"2024-02-29T00:00:00Z"}')
    )
    assert_equal(leap.timestamp.value().seconds, Int64(1709164800))
    var leap400 = decode_json[LogEntryLike](
        String('{"timestamp":"2000-02-29T00:00:00Z"}')
    )
    assert_equal(leap400.timestamp.value().seconds, Int64(951782400))
    # An offset is accepted on input and normalized to UTC.
    var e = decode_json[LogEntryLike](
        String('{"timestamp":"2026-10-01T02:30:00.5+02:30"}')
    )
    assert_equal(e.timestamp.value().seconds, Int64(1790812800))
    assert_equal(e.timestamp.value().nanos, Int32(500000000))
    # Outside 0001..9999 cannot be rendered.
    var far = LogEntryLike.new()
    far.timestamp = Timestamp(Int64(253402300800), Int32(0))
    with assert_raises():
        _ = encode_json[LogEntryLike](far)


def test_duration_json_refusals() raises:
    var bad = List[String]()
    bad.append(String('{"httpRequest":{"latency":"315576000001s"}}'))
    bad.append(String('{"httpRequest":{"latency":"1.5"}}'))
    bad.append(String('{"httpRequest":{"latency":"--1s"}}'))
    for i in range(len(bad)):
        with assert_raises():
            _ = decode_json[LogEntryLike](bad[i])
    var neg = decode_json[LogEntryLike](
        String('{"httpRequest":{"latency":"-1.5s"}}')
    )
    var d = neg.http_request.value().latency.value()
    assert_equal(d.seconds, Int64(-1))
    assert_equal(d.nanos, Int32(-500000000))
    # Mismatched signs cannot be rendered.
    var e = LogEntryLike.new()
    e.http_request = HttpRequestLike(String(""), Duration(Int64(1), Int32(-1)))
    with assert_raises():
        _ = encode_json[LogEntryLike](e)


def test_value_refuses_nan_and_struct_last_wins() raises:
    var e = LogEntryLike.new()
    var s = Struct.new()
    s.put(String("x"), Value.number(Float64(1.0e308) * Float64(10.0)))
    e.json_payload = s^
    with assert_raises(contains="cannot be Infinity"):
        _ = encode_json[LogEntryLike](e)
    # -Infinity: the `v < -max` half of the check.
    var big = Float64(1.0e308) * Float64(10.0)
    var en = LogEntryLike.new()
    var sn = Struct.new()
    sn.put(String("x"), Value.number(-big))
    en.json_payload = sn^
    with assert_raises(contains="cannot be Infinity"):
        _ = encode_json[LogEntryLike](en)
    # NaN: the `v != v` check (NaN fails BOTH range comparisons, so the
    # Infinity check alone would let it through to the formatter).
    var ea = LogEntryLike.new()
    var sa = Struct.new()
    sa.put(String("x"), Value.number(big - big))
    ea.json_payload = sa^
    with assert_raises(contains="cannot be NaN"):
        _ = encode_json[LogEntryLike](ea)
    # map<string, Value> semantics: a repeated key REPLACES, in place.
    var t = Struct.new()
    t.put(String("k"), Value.number(Float64(1.0)))
    t.put(String("j"), Value.boolean(True))
    t.put(String("k"), Value.string(String("last")))
    assert_equal(len(t.keys), 2)
    assert_equal(t.values[0].string_value, String("last"))
    var d = decode_json[LogEntryLike](
        String('{"jsonPayload":{"k":1,"j":true,"k":"last"}}')
    )
    var p = d.json_payload.value().copy()
    assert_equal(len(p.keys), 2)
    assert_equal(p.values[0].kind, VALUE_KIND_STRING)


def test_field_mask_json_refusals() raises:
    with assert_raises():
        _ = decode_json[LogEntryLike](String('{"updateMask":"log_name"}'))
    var fm = LogEntryLike.new()
    var m = FieldMask.new()
    m.paths.append(String("fooBar"))
    fm.update_mask = m^
    with assert_raises():
        _ = encode_json[LogEntryLike](fm)


def test_wkt_refusals_name_the_json_path() raises:
    """Each WKT arm appends the offending field's JSON path to the error:
    the plain field, the repeated element's index, the map entry's key."""
    with assert_raises(contains="at $.timestamp"):
        _ = decode_json[LogEntryLike](
            String('{"timestamp":"2026-13-01T00:00:00Z"}')
        )
    with assert_raises(contains="at $.checkpoints[1]"):
        _ = decode_json[LogEntryLike](
            String('{"checkpoints":["1970-01-01T00:00:00Z","1970-13-01T00:00:00Z"]}')
        )
    with assert_raises(contains='at $.stamps["late"]'):
        _ = decode_json[StampMapLike](
            String(
                '{"stamps":{"ok":"1970-01-01T00:00:00Z",'
                + '"late":"2026-04-31T00:00:00Z"}}'
            )
        )
    # The good map round-trips, so the refusal above is the value's fault.
    var good = String('{"stamps":{"ok":"1970-01-01T00:00:00Z"}}')
    assert_equal(encode_json[StampMapLike](decode_json[StampMapLike](good)), good)


def main() raises:
    test_logentry_encode_json_is_canonical()
    test_logentry_decode_json_roundtrip()
    test_logentry_binary_is_wire_identical()
    test_server_shaped_logging_response()
    test_all_wkt_json_forms()
    test_wrapper_json_accepts_spec_spellings()
    test_any_json_and_binary()
    test_timestamp_json_refusals()
    test_duration_json_refusals()
    test_value_refuses_nan_and_struct_last_wins()
    test_field_mask_json_refusals()
    test_wkt_refusals_name_the_json_path()
    print("test_wkt_json_codec_path: all tests passed")
