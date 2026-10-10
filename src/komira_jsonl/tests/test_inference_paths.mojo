# =============================================================================
# Schema inference: the tape walk's refusals, the merge of partial schemas,
# the parallel entries' fallbacks and dispatcher entry, and the key hash
# tables' collision tie-break.
# =============================================================================
#
#   * test_tape_refusals -- `_infer_partial_into` on the tape of a JSON
#     object cut short or retagged (each `t >= len or tag != X` guard both
#     ways: the tape ends, or the tag is another one), and the public
#     `infer_jsonl_schema` on `{1:2}`, `{"a" 1}` and `{"a":}`: each message
#     names its guard and byte.
#   * test_scalar_whitespace_and_classify -- a scalar with blanks before and
#     after it infers its type; `_classify_scalar` refuses an empty range.
#   * test_merge_partials -- `_merge_partial_into` keeps first-seen order,
#     promotes Int64 + Float64 to Float64 (existing Int64 and existing
#     Float64: the promoted type is stored, not the incoming one), keeps an
#     existing Bool against an incoming Null, and refuses Int64 vs Bool and
#     Float64 vs String naming both types; `_inferred_tag_name` of every tag.
#   * test_inferred_to_arrow_every_tag -- the lattice tag to Arrow type map,
#     MIXED included (STRING).
#   * test_with_index_and_bytes_to_string -- `infer_jsonl_schema_with_index`
#     returns the schema and the same tape `build_structural_index` builds;
#     `_bytes_to_string` copies a byte range.
#   * test_parallel_fallbacks -- `infer_jsonl_schema_parallel_into` below
#     4 MiB, and on a 4 MiB input of one line with the default worker count,
#     returns the serial schema and empties the partitions it was given.
#   * test_parallel_dispatcher_entry -- the dispatcher entry on a one-worker
#     runtime over two 4 MiB-plus line ranges: two partitions whose ranges
#     tile the input, and the serial schema.
#   * test_key_table_hash_tie_break -- a `KeyTable` of 8 keys (hash arm)
#     whose bucket for a probe key holds the probe's hash but another
#     key's index: the byte compare must reject it (-1), not return it.
#   * test_registry_tie_break_and_owned_insert -- the same forged bucket in
#     `KeyRegistryBuilder` (byte and owned lookups insert a new column
#     instead of returning the forged one), and `lookup_or_insert_owned`
#     over 40 keys (past two rehashes) returns each key's first index.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema

from komira_json_index.simd_primitives import (
    TAG_CLOSE_BRACE,
    TAG_COLON,
)
from komira_json_index.structural_index import (
    build_structural_index,
    JsonlPartitions,
    StructuralIndex,
)
from komira_jsonl.key_dispatch import KeyRegistryBuilder, KeyTable, _fnv1a_64
from komira_jsonl.schema_inference import (
    INF_BOOL,
    INF_FLOAT64,
    INF_INT64,
    INF_MIXED_STRING,
    INF_NULL,
    INF_STRING,
    _bytes_to_string,
    _classify_scalar,
    _infer_partial_into,
    _inferred_tag_name,
    _inferred_to_arrow,
    _merge_partial_into,
    infer_jsonl_schema,
    infer_jsonl_schema_parallel_into,
    infer_jsonl_schema_parallel_into_with_dispatcher,
    infer_jsonl_schema_with_index,
)


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _first(idx: StructuralIndex, k: Int) -> StructuralIndex:
    var o = List[UInt32]()
    var t = List[UInt8]()
    for i in range(k):
        o.append(idx.offsets[i])
        t.append(idx.tags[i])
    return StructuralIndex(o^, t^)


def _walk_err(text: String, idx: StructuralIndex) raises -> String:
    var b = _bytes_of(text)
    var names = List[String]()
    var inferred = List[UInt8]()
    try:
        _infer_partial_into(Span(b), idx, names, inferred)
    except e:
        return String(e)
    raise Error("not refused: " + text)


def _infer_err(text: String) raises -> String:
    var b = _bytes_of(text)
    try:
        _ = infer_jsonl_schema(Span(b))
    except e:
        return String(e)
    raise Error("not refused: " + text)


def test_tape_refusals() raises:
    var w = String("infer_jsonl_schema: ")
    # `{"a":"b"}`: { " " : " " } at 0 1 3 4 5 7 8.
    var text = String('{"a":"b"}')
    var full = build_structural_index(text.as_bytes())
    assert_equal(full.size(), 7)
    var key_msg = w + "missing TAG_QUOTE_CLOSE for key at byte 1"
    assert_equal(_walk_err(text, _first(full, 2)), key_msg)
    var retag = full.copy()
    retag.tags[2] = TAG_COLON
    assert_equal(_walk_err(text, retag), key_msg)
    var colon_msg = w + "expected TAG_COLON after key at byte 1"
    assert_equal(_walk_err(text, _first(full, 3)), colon_msg)
    assert_equal(_infer_err('{"a" 1}'), colon_msg)
    assert_equal(
        _walk_err(text, _first(full, 4)),
        w + "truncated input (expected value after colon at byte 4)",
    )
    var val_msg = w + "missing TAG_QUOTE_CLOSE for string value at byte 1"
    assert_equal(_walk_err(text, _first(full, 5)), val_msg)
    var retag2 = full.copy()
    retag2.tags[5] = TAG_CLOSE_BRACE
    assert_equal(_walk_err(text, retag2), val_msg)
    assert_equal(
        _infer_err("{1:2}"),
        w + "expected TAG_QUOTE_OPEN at tape position 1, got tag="
        + String(Int(TAG_COLON)),
    )
    var empty_msg = w + "empty scalar value after key at byte 1"
    assert_equal(_infer_err('{"a":}'), empty_msg)
    assert_equal(_infer_err('{"a": \t}'), empty_msg)


def test_scalar_whitespace_and_classify() raises:
    var b = _bytes_of(String('{"a": \t1 \r,"b":\n2.5\t}\n{"a":\n3,"b":4 }\n'))
    var s = infer_jsonl_schema(Span(b))
    assert_equal(s.num_columns(), 2)
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_true(s.field_arrow_type(1) == ArrowType.FLOAT64)
    var t = _bytes_of(String("abc"))
    var msg = String()
    try:
        _ = _classify_scalar(Span(t), 2, 2)
    except e:
        msg = String(e)
    assert_equal(msg, "_classify_scalar: empty scalar at byte 2")


def _merge_err(
    a: String, ta: UInt8, b: String, tb: UInt8
) raises -> String:
    var dn = List[String]()
    var di = List[UInt8]()
    dn.append(a)
    di.append(ta)
    var sn = List[String]()
    var si = List[UInt8]()
    sn.append(b)
    si.append(tb)
    try:
        _merge_partial_into(dn, di, sn, si)
    except e:
        return String(e)
    raise Error("merge not refused")


def test_merge_partials() raises:
    var dn = List[String]()
    var di = List[UInt8]()
    dn.append("x")
    di.append(INF_INT64)
    dn.append("y")
    di.append(INF_NULL)
    var sn = List[String]()
    var si = List[UInt8]()
    sn.append("z")
    si.append(INF_BOOL)
    sn.append("x")
    si.append(INF_FLOAT64)
    sn.append("y")
    si.append(INF_STRING)
    _merge_partial_into(dn, di, sn, si)
    assert_equal(len(dn), 3)
    assert_equal(dn[0], "x")
    assert_equal(dn[1], "y")
    assert_equal(dn[2], "z")
    assert_equal(Int(di[0]), Int(INF_FLOAT64))
    assert_equal(Int(di[1]), Int(INF_STRING))
    assert_equal(Int(di[2]), Int(INF_BOOL))
    # The existing type is the wider one: it must stay, whatever the
    # incoming partial observed (FLOAT64 absorbs INT64; NULL is bottom).
    var wn = List[String]()
    var wi = List[UInt8]()
    wn.append("f")
    wi.append(INF_FLOAT64)
    wn.append("b")
    wi.append(INF_BOOL)
    var on = List[String]()
    var oi = List[UInt8]()
    on.append("f")
    oi.append(INF_INT64)
    on.append("b")
    oi.append(INF_NULL)
    _merge_partial_into(wn, wi, on, oi)
    assert_equal(len(wn), 2)
    assert_equal(wn[0], "f")
    assert_equal(wn[1], "b")
    assert_equal(Int(wi[0]), Int(INF_FLOAT64))
    assert_equal(Int(wi[1]), Int(INF_BOOL))
    var tail = String(
        "). Wide-default inference requires uniform types per column."
        " Recovery: pass an explicit schema via ctx.read_json_batch(path,"
        " schema)."
    )
    assert_equal(
        _merge_err("c", INF_INT64, "c", INF_BOOL),
        "infer_jsonl_schema: heterogeneous types for column 'c' across"
        " records (existing=Int64, observed=Bool" + tail,
    )
    assert_equal(
        _merge_err("d", INF_FLOAT64, "d", INF_STRING),
        "infer_jsonl_schema: heterogeneous types for column 'd' across"
        " records (existing=Float64, observed=String" + tail,
    )
    assert_equal(_inferred_tag_name(INF_NULL), "NULL")
    assert_equal(_inferred_tag_name(INF_INT64), "Int64")
    assert_equal(_inferred_tag_name(INF_FLOAT64), "Float64")
    assert_equal(_inferred_tag_name(INF_BOOL), "Bool")
    assert_equal(_inferred_tag_name(INF_STRING), "String")
    assert_equal(_inferred_tag_name(INF_MIXED_STRING), "MIXED")


def test_inferred_to_arrow_every_tag() raises:
    assert_true(_inferred_to_arrow(INF_NULL) == ArrowType.NULL)
    assert_true(_inferred_to_arrow(INF_INT64) == ArrowType.INT64)
    assert_true(_inferred_to_arrow(INF_FLOAT64) == ArrowType.FLOAT64)
    assert_true(_inferred_to_arrow(INF_BOOL) == ArrowType.BOOL)
    assert_true(_inferred_to_arrow(INF_STRING) == ArrowType.STRING)
    assert_true(_inferred_to_arrow(INF_MIXED_STRING) == ArrowType.STRING)


def test_with_index_and_bytes_to_string() raises:
    var b = _bytes_of(String('{"k":true,"n":null}\n{"k":false,"s":"v"}\n'))
    var r = infer_jsonl_schema_with_index(Span(b))
    ref s = r[0]
    assert_equal(s.num_columns(), 3)
    assert_equal(String(s.field_name(2)), "s")
    assert_true(s.field_arrow_type(0) == ArrowType.BOOL)
    assert_true(s.field_arrow_type(1) == ArrowType.NULL)
    var again = build_structural_index(Span(b))
    assert_equal(r[1].size(), again.size())
    for i in range(again.size()):
        assert_equal(Int(r[1].offsets[i]), Int(again.offsets[i]))
        assert_equal(Int(r[1].tags[i]), Int(again.tags[i]))
    assert_equal(_bytes_to_string(Span(b), 2, 3), "k")
    assert_equal(_bytes_to_string(Span(b), 0, 0), "")


def _seeded_partitions() -> JsonlPartitions:
    var los = List[Int]()
    los.append(7)
    var his = List[Int]()
    his.append(9)
    var ix = List[StructuralIndex]()
    ix.append(StructuralIndex(List[UInt32](), List[UInt8]()))
    return JsonlPartitions(los^, his^, ix^)


def _big_one_line() -> List[UInt8]:
    # `{"a":1`, 4 MiB of spaces, `}`: one record and no LF.
    var out = _bytes_of(String('{"a":1'))
    for _ in range(4 * 1024 * 1024):
        out.append(UInt8(0x20))
    out.append(UInt8(0x7D))
    return out^


def test_parallel_fallbacks() raises:
    var small = _bytes_of(String('{"a":1}\n{"a":2.5}\n'))
    var parts = _seeded_partitions()
    var s = infer_jsonl_schema_parallel_into(Span(small), parts, 4)
    assert_equal(s.num_columns(), 1)
    assert_true(s.field_arrow_type(0) == ArrowType.FLOAT64)
    assert_equal(len(parts.los), 0)
    assert_equal(len(parts.his), 0)
    assert_equal(len(parts.indices), 0)
    var big = _big_one_line()
    var parts2 = _seeded_partitions()
    var s2 = infer_jsonl_schema_parallel_into(Span(big), parts2)
    assert_equal(s2.num_columns(), 1)
    assert_true(s2.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(len(parts2.los), 0)
    assert_equal(len(parts2.his), 0)
    assert_equal(len(parts2.indices), 0)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _big_lines() -> List[UInt8]:
    # Lines `{"a":<i>,` + 1000 spaces + `"b":true}` LF past 4 MiB; the last
    # line adds a "c" key with a float, so the second range brings a column
    # the first does not have.
    var pad = String()
    for _ in range(1000):
        pad += " "
    var out = List[UInt8]()
    var i = 0
    while len(out) <= 4 * 1024 * 1024:
        var line = '{"a":' + String(i) + "," + pad + '"b":true}\n'
        out.extend(Span(line.as_bytes()))
        i += 1
    out.extend(Span(String('{"a":0,"c":0.5}\n').as_bytes()))
    return out^


def test_parallel_dispatcher_entry() raises:
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var big = _big_lines()
    var parts = _seeded_partitions()
    var s = infer_jsonl_schema_parallel_into_with_dispatcher[origin_of(disp)](
        Span(big), parts, Pointer(to=disp), CancellationToken.never(), 2
    )
    var serial = infer_jsonl_schema(Span(big))
    assert_equal(s.num_columns(), 3)
    assert_equal(serial.num_columns(), 3)
    for c in range(3):
        assert_equal(String(s.field_name(c)), String(serial.field_name(c)))
        assert_true(s.field_arrow_type(c) == serial.field_arrow_type(c))
    assert_equal(String(s.field_name(2)), "c")
    assert_true(s.field_arrow_type(2) == ArrowType.FLOAT64)
    assert_equal(len(parts.los), 2)
    assert_equal(len(parts.indices), 2)
    assert_equal(parts.los[0], 0)
    assert_equal(parts.his[0], parts.los[1])
    assert_equal(parts.his[1], len(big))
    _ = rt^


def _keys(n: Int) -> List[String]:
    var k = List[String]()
    for i in range(n):
        k.append("k" + String(i))
    return k^


def test_key_table_hash_tie_break() raises:
    var t = KeyTable.from_field_names(_keys(8))
    var probe = String("zz")  # same length as "k0", not a key
    var h = _fnv1a_64(probe.as_bytes())
    assert_equal(t.lookup(probe.as_bytes()), -1)
    # Forge a colliding entry: the probe's home bucket now holds the
    # probe's hash but column 0 ("k0", same length, other bytes).
    var home = Int(h) & t._bucket_mask
    t._bucket_hashes[home] = h
    t._bucket_to_idx[home] = Int32(0)
    assert_equal(t.lookup(probe.as_bytes()), -1)


def _forged_registry(probe: String) -> KeyRegistryBuilder:
    """A registry holding "k0" at column 0 in the probe's home bucket,
    stored with the probe's hash."""
    var r = KeyRegistryBuilder()
    var h = _fnv1a_64(probe.as_bytes())
    var home = Int(h) & r._bucket_mask
    r._names.append("k0")
    r._bucket_hashes[home] = h
    r._bucket_to_idx[home] = Int32(0)
    r._occupied = 1
    return r^


def test_registry_tie_break_and_owned_insert() raises:
    var probe = String("zz")
    var r = _forged_registry(probe)
    assert_equal(r.lookup_or_insert_bytes(probe.as_bytes()), 1)
    assert_equal(r.size(), 2)
    assert_equal(r.name_at(1), "zz")
    var r2 = _forged_registry(probe)
    assert_equal(r2.lookup_or_insert_owned(probe.copy()), 1)
    assert_equal(r2.size(), 2)
    assert_equal(r2.name_at(1), "zz")
    # Owned inserts past two rehashes (16 -> 32 -> 64 -> 128 buckets).
    var r3 = KeyRegistryBuilder()
    for i in range(40):
        assert_equal(r3.lookup_or_insert_owned("k" + String(i)), i)
    for i in range(40):
        assert_equal(r3.lookup_or_insert_owned("k" + String(i)), i)
        var key = "k" + String(i)
        assert_equal(r3.lookup_or_insert_bytes(key.as_bytes()), i)
    assert_equal(r3.size(), 40)
    var names = r3^.into_names()
    assert_equal(len(names), 40)
    assert_equal(names[39], "k39")


def main() raises:
    test_tape_refusals()
    test_scalar_whitespace_and_classify()
    test_merge_partials()
    test_inferred_to_arrow_every_tag()
    test_with_index_and_bytes_to_string()
    test_parallel_fallbacks()
    test_parallel_dispatcher_entry()
    test_key_table_hash_tie_break()
    test_registry_tie_break_and_owned_insert()
    print("test_inference_paths: all passed")
