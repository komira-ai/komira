# =============================================================================
# komira_db/proto_json.mojo — proto3-canonical-JSON serde for nested fields.
# =============================================================================
#
# The DbStorable codegen stores nested protobuf fields (a
# nested `message`, a `repeated`, a `map`) as a single native JSON column
# (native JSON only). The generated `to_row()` / `from_row()` call:
#
#   out.append(DbValue.jsonb(to_proto_json(self.config)))               # serialize
#   config = from_proto_json[Dict[String,String]](row.get_jsonb(col))   # parse
#
# This module supplies `to_proto_json` / `from_proto_json[T]` for the shapes
# the code generator emits:
#
#   * `Dict[K, V]` maps          — JSON object keyed by the string form of K
#                                  (proto3 map → JSON object):
#       Dict[String, String], Dict[String, Int64], Dict[Int32, String]
#   * a nested struct `M`        — JSON object; M conforms to `ProtoJsonable`
#   * `List[M]` of nested structs — JSON array of objects
#
# DISPATCH (Mojo 1.0.0b1): Mojo cannot overload a function on RETURN TYPE only,
# and `Dict` is a stdlib type we cannot give trait conformance. So the map
# decode path is ONE generic `from_proto_json[T]` that branches on the concrete
# `T` via `_type_is_eq` and `rebind`s the built Dict to `T`. The nested-struct path is a SEPARATE
# function name (`message_from_proto_json[M: ProtoJsonable]` /
# `repeated_from_proto_json[M]`) the codegen targets for ProtoJsonable fields —
# this avoids an [AnyType] vs [ProtoJsonable] overload ambiguity on the shared
# `from_proto_json` name. (Emitter contract: emit the message/repeated decode via
# the `*_from_proto_json` helpers; the map decode via `from_proto_json[Dict..]`.)
#
# proto3-canonical-JSON is the cross-language wire contract. The emitter
# is deterministic: map keys are emitted in SORTED order so generated output
# and round-trips are stable.
#
# Encapsulation: String in / typed value out. No UnsafePointer, no
# wildcard origin, no cross-module pointer flow.
# =============================================================================

from std.collections.dict import Dict

from komira_serde.json_value import JsonValue, parse_json_value


# =============================================================================
# ProtoJsonable — the trait a generated NESTED struct conforms to.
# =============================================================================
trait ProtoJsonable(Copyable, Movable, Deinitable):
    """A nested protobuf message → a generated Mojo struct that renders itself
    to / from proto3-canonical-JSON. The DB codegen emits this conformance on
    the nested struct. Keeping the
    (de)serialization ON the struct lets the nested helpers work for ANY user
    nested type without komira_db knowing its fields."""

    def to_json_object(self) -> String:
        """Render `self` to a proto3-canonical-JSON object text."""
        ...

    @staticmethod
    def from_json_value(v: JsonValue) raises -> Self:
        """Reconstruct `Self` from a parsed JSON value."""
        ...


# =============================================================================
# JSON string escaping (proto3-canonical — minimal RFC 8259 escapes).
# =============================================================================
def json_escape(s: String) -> String:
    """Escape a string for embedding in a JSON document (returns the quoted,
    escaped literal)."""
    var out = String('"')
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord('"')):
            out += '\\"'
        elif c == UInt8(ord("\\")):
            out += "\\\\"
        elif c == UInt8(ord("\n")):
            out += "\\n"
        elif c == UInt8(ord("\r")):
            out += "\\r"
        elif c == UInt8(ord("\t")):
            out += "\\t"
        elif c < UInt8(0x20):
            out += "\\u00"
            out += _hex2(Int(c))
        else:
            out += String(chr(Int(c)))
    out += '"'
    return out^


def _hex2(v: Int) -> String:
    return _hexd((v >> 4) & 0x0F) + _hexd(v & 0x0F)


def _hexd(n: Int) -> String:
    if n < 10:
        return String(chr(ord("0") + n))
    return String(chr(ord("a") + (n - 10)))


# =============================================================================
# to_proto_json — serialize each supported shape to canonical JSON text.
# =============================================================================
#
# Map keys are emitted in SORTED order so the output is deterministic. proto3
# JSON maps map<K,V> by the string form of K; an integer key is the decimal
# string, and an int64 VALUE is encoded as a JSON string (the proto3 JSON mapping).

def to_proto_json(d: Dict[String, String]) -> String:
    var keys = List[String]()
    for entry in d.items():
        keys.append(entry.key)
    _sort_strings(keys)
    var out = String("{")
    for i in range(len(keys)):
        if i > 0:
            out += ","
        out += json_escape(keys[i])
        out += ":"
        try:
            out += json_escape(d[keys[i]])
        except:
            out += '""'
    out += "}"
    return out^


def to_proto_json(d: Dict[String, Int64]) -> String:
    var keys = List[String]()
    for entry in d.items():
        keys.append(entry.key)
    _sort_strings(keys)
    var out = String("{")
    for i in range(len(keys)):
        if i > 0:
            out += ","
        out += json_escape(keys[i])
        out += ":"
        try:
            out += json_escape(String(Int(d[keys[i]])))  # int64 -> JSON string
        except:
            out += '"0"'
    out += "}"
    return out^


def to_proto_json(d: Dict[Int32, String]) -> String:
    var keys = List[Int32]()
    for entry in d.items():
        keys.append(entry.key)
    _sort_int32(keys)
    var out = String("{")
    for i in range(len(keys)):
        if i > 0:
            out += ","
        out += json_escape(String(Int(keys[i])))  # int key -> decimal string
        out += ":"
        try:
            out += json_escape(d[keys[i]])
        except:
            out += '""'
    out += "}"
    return out^


def to_proto_json[M: ProtoJsonable](v: M) -> String:
    """A nested struct (proto message) → its canonical JSON object."""
    return v.to_json_object()


def to_proto_json[M: ProtoJsonable](v: List[M]) -> String:
    """A `repeated M` (message elems) → a JSON array of objects."""
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += v[i].to_json_object()
    out += "]"
    return out^


# =============================================================================
# from_proto_json[T] — parse canonical JSON for the MAP shapes (return-type
# dispatch via `_type_is_eq` + rebind, the only Mojo 1.0.0b1 way to select the
# concrete map type from an explicit `[T]` parameter on ONE function name).
# =============================================================================
def from_proto_json[T: Copyable & Movable](s: String) raises -> T:
    var v = parse_json_value(s)

    comptime if (T == Dict[String, String]):
        var out = Dict[String, String]()
        if v.is_object():
            for i in range(len(v.obj_keys)):
                out[v.obj_keys[i]] = v.children[i].as_string()
        return rebind[T](out).copy()
    elif (T == Dict[String, Int64]):
        var out = Dict[String, Int64]()
        if v.is_object():
            for i in range(len(v.obj_keys)):
                out[v.obj_keys[i]] = v.children[i].as_int64()
        return rebind[T](out).copy()
    elif (T == Dict[Int32, String]):
        var out = Dict[Int32, String]()
        if v.is_object():
            for i in range(len(v.obj_keys)):
                out[Int32(_parse_i64(v.obj_keys[i]))] = v.children[i].as_string()
        return rebind[T](out).copy()
    else:
        raise Error(
            "komira_db.from_proto_json[T]: no map codec for this type — for a"
            " nested ProtoJsonable struct use message_from_proto_json /"
            " repeated_from_proto_json instead"
        )


# =============================================================================
# Nested-struct decode — SEPARATE names so there is no [AnyType]-vs-
# [ProtoJsonable] overload ambiguity on the `from_proto_json` name.
# =============================================================================
def message_from_proto_json[M: ProtoJsonable](s: String) raises -> M:
    """A nested struct (proto message) ← its canonical JSON object."""
    return M.from_json_value(parse_json_value(s))


def repeated_from_proto_json[M: ProtoJsonable](s: String) raises -> List[M]:
    """A `repeated M` ← a JSON array of objects."""
    var v = parse_json_value(s)
    var out = List[M]()
    if v.is_array():
        for i in range(len(v.children)):
            out.append(M.from_json_value(v.children[i]))
    return out^


# =============================================================================
# Local sort + parse helpers.
# =============================================================================
def _sort_strings(mut xs: List[String]):
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            xs[j - 1], xs[j] = xs[j], xs[j - 1]
            j -= 1


def _sort_int32(mut xs: List[Int32]):
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            xs[j - 1], xs[j] = xs[j], xs[j - 1]
            j -= 1


def _parse_i64(s: String) raises -> Int64:
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("proto_json: empty integer key")
    var i = 0
    var neg = False
    if b[0] == UInt8(ord("-")):
        neg = True
        i = 1
    var acc: Int64 = 0
    while i < n:
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            raise Error("proto_json: non-numeric integer key byte")
        acc = acc * Int64(10) + Int64(Int(c) - ord("0"))
        i += 1
    return -acc if neg else acc
