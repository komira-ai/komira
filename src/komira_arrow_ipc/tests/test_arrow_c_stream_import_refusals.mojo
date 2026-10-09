# =============================================================================
# FFI-BOUNDARY: a stand-in foreign producer of Arrow C Data Interface
# structs. The structs, children arrays and buffers below are allocated here
# with `alloc`, read by the importer (which copies, and frees nothing of a
# foreign struct), and left allocated for the life of the test process: each
# case's struct must outlive the importer's read, and none carries a release.
# Every hand-built struct has `release == NULL`, which a real producer's live
# struct never has. That is harmless here: `_import_column`,
# `_read_root_schema` and `_import_record_batch` never read `release`, and no
# hand-built struct is passed to anything that does.
# The two schemas the export cases at the end build are released through
# `release_c_schema` and their boxes freed.
#
# Arrow C Stream Interface: what the import side of `c_data_stream.mojo`
# refuses, and the small tables it decides by.
#
# Spec: https://arrow.apache.org/docs/format/CDataInterface.html. Each struct
# below is a well-formed one with ONE member broken, each break a sentence of
# the spec: `children` "MAY be NULL only if n_children is 0"; `format` is
# Mandatory; `dictionary` "MUST be present if the ArrowArray represents a
# dictionary-encoded array"; the number of buffers is fixed by the type. No
# structure is random: every case names the member it breaks and the message
# the importer must give, and each has a well-formed twin that imports.
#
#   * `_import_column`: a buffer count for another type; a NULL `buffers` array;
#     the validity bitmap's padding bits (left set by the producer) and an
#     empty bitmap; a dictionary without its value array or the value array's
#     buffers; and, for LIST / STRUCT / MAP / UNION, a missing schema, a child
#     count that disagrees, NULL children arrays, a NULL child on either side,
#     a NULL child format, and the default child names.
#   * `_read_root_schema`: a NULL schema or format, NULL children, a NULL
#     child, the dictionary index types (signed only) and value type (STRING).
#   * `_import_record_batch`: a NULL array, a child count that disagrees with
#     the schema, a NULL child, a nested column with no schema to recurse into.
#   * Decimal (precision, scale): the values handed in, and the defaults that
#     replace a missing or out-of-range one; `_parse_decimal_format`'s bit
#     widths and the formats it reads with defaults instead of refusing.
#   * Partial schema info (a parameter list missing, or one of a pair): the
#     schema falls back to Field defaults and the batch import to precision 0
#     and no declared union ids.
#   * The tables: format string to type, element width, buffer count; the
#     export refusals of a type outside the subset; the NULL-tolerant helpers.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    release_c_schema,
    _alloc_array_ptr_array,
    _alloc_buffers_array,
    _alloc_schema_ptr_array,
    _arrow_fixed_width_bytes,
    _arrow_type_n_buffers,
    _build_column_schema_from_field,
    _build_column_schema_from_field_and_column,
    _build_schema_from_info,
    _c_str_to_mojo,
    _column_format_string,
    _copy_string_to_c_int8,
    _format_string_to_arrow_type,
    _import_column,
    _import_record_batch,
    _null_ptr,
    _parse_decimal_format,
    _read_root_schema,
    _stream_error_text,
    _ImportedSchemaInfo,
)
from komira_buffer.heap_region import HeapRegion

comptime _VP = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _AP = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _CP = UnsafePointer[Int8, MutUntrackedOrigin]


# --- hand-built structs (release NULL: nothing here is released, only read) ---


def _arr(length: Int, n_buffers: Int, n_children: Int = 0, null_count: Int = 0) -> CArrowArray:
    var a = CArrowArray()
    a.length = Int64(length)
    a.null_count = Int64(null_count)
    a.n_buffers = Int64(n_buffers)
    a.n_children = Int64(n_children)
    a.buffers = _alloc_buffers_array(n_buffers)  # every slot NULL
    return a^


def _ha(var a: CArrowArray) -> _AP:
    var p = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(a^)
    return p


def _sch(fmt: String, name: String = "") -> CArrowSchema:
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(fmt)
    s.name = _copy_string_to_c_int8(name)
    return s^


def _hs(var s: CArrowSchema) -> _SP:
    var p = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(s^)
    return p


def _akids(mut a: CArrowArray, kids: List[_AP]):
    a.n_children = Int64(len(kids))
    a.children = _alloc_array_ptr_array(len(kids))
    for i in range(len(kids)):
        (a.children + i).unsafe_write(kids[i])


def _skids(mut s: CArrowSchema, kids: List[_SP]):
    s.n_children = Int64(len(kids))
    s.children = _alloc_schema_ptr_array(len(kids))
    for i in range(len(kids)):
        (s.children + i).unsafe_write(kids[i])


def _bytes(values: List[Int]) -> _VP:
    var p = alloc[UInt8](max(len(values), 1)).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(len(values)):
        (p + i).unsafe_write(UInt8(values[i]))
    return p.bitcast[NoneType]()


def _null_c() -> _CP:
    return _null_ptr[Int8, MutUntrackedOrigin]()


def _null_a() -> _AP:
    return _null_ptr[CArrowArray, MutUntrackedOrigin]()


def _null_s() -> _SP:
    return _null_ptr[CArrowSchema, MutUntrackedOrigin]()


def _import_error(ref a: CArrowArray, t: ArrowType, sch: _SP) -> String:
    try:
        _ = _import_column(a, t, 0, 0, sch)
    except e:
        return String(e)
    return String("(imported)")


def _unrecognized(fmt: String) -> String:
    return "UnsupportedArrowCABIType: Arrow C ABI format string '" + fmt + "' is not recognized."


# --- flat columns ---------------------------------------------------------------


def test_import_refuses_a_buffer_count_for_another_type() raises:
    var a = _arr(0, 3)
    assert_equal(
        _import_error(a, ArrowType.INT64, _null_s()),
        String("from_arrow_c_stream: child array for type 'int64' has 3 buffers, expected 2"),
    )


def test_import_reads_a_null_buffers_array_as_null_buffers() raises:
    # `buffers` is Mandatory in the spec; this importer reads a NULL array as
    # every buffer NULL and applies the per-buffer rule, so an empty column
    # imports and a non-empty one is refused for its missing data.
    var a = _arr(0, 2)
    a.buffers = _null_ptr[_VP, MutUntrackedOrigin]()
    var c = _import_column(a, ArrowType.INT64)
    assert_equal(c.length(), 0)
    assert_equal(c._data.len(), 0)
    assert_false(c.has_validity_buffer())
    var b = _arr(2, 2)
    b.buffers = _null_ptr[_VP, MutUntrackedOrigin]()
    assert_true(
        _import_error(b, ArrowType.INT64, _null_s()).startswith(
            "from_arrow_c_stream: array of type 'int64' has a NULL data buffer, but that"
            " buffer's size would be 16 bytes"
        )
    )


def test_import_clears_the_padding_bits_of_the_validity_bitmap() raises:
    # Tolerance, not a refusal: the spec leaves the contents of padding bits
    # unspecified, so a producer may leave them set and the import must accept
    # the bitmap and mask them.
    # Three rows, row 1 null; the producer left the five padding bits set.
    # Unmasked, a whole-byte popcount reads 7 valid of 3 rows.
    var a = _arr(3, 2, null_count=-1)
    (a.buffers + 0).unsafe_write(_bytes([0xFD]))
    (a.buffers + 1).unsafe_write(_bytes([1, 2, 3]))
    var c = _import_column(a, ArrowType.INT8)
    assert_equal(c.null_count(), 1)
    assert_true(c.is_null_at(1))
    assert_equal(Int(c._validity.value().buffer.read_u8_at(0)), 0x05)
    assert_equal(Int(c._data.read_u8_at(2)), 3)


def test_import_of_an_empty_column_with_a_bitmap() raises:
    # Tolerance, not a refusal: a length-0 column's bitmap byte is all
    # padding, whose contents the spec leaves unspecified, so 0xFF imports
    # as zero rows and zero nulls.
    var a = _arr(0, 2)
    (a.buffers + 0).unsafe_write(_bytes([0xFF]))
    var c = _import_column(a, ArrowType.INT32)
    assert_equal(c.length(), 0)
    assert_equal(c.null_count(), 0)
    assert_true(c.has_validity_buffer())


def test_import_dictionary_refusals() raises:
    var a = _arr(0, 2)
    assert_equal(
        _import_error(a, ArrowType.DICTIONARY, _null_s()),
        String("from_arrow_c_stream: dictionary column missing dictionary slot"),
    )
    var d = _arr(0, 3)
    d.buffers = _null_ptr[_VP, MutUntrackedOrigin]()
    a.dictionary = _ha(d^)
    assert_equal(
        _import_error(a, ArrowType.DICTIONARY, _null_s()),
        String("from_arrow_c_stream: dictionary value-array missing buffers"),
    )
    var d1 = _arr(1, 3)
    var b = _arr(0, 2)
    b.dictionary = _ha(d1^)
    assert_true(
        _import_error(b, ArrowType.DICTIONARY, _null_s()).startswith(
            "from_arrow_c_stream: array of type 'dictionary' has a NULL dictionary"
            " value offsets buffer, but that buffer's size would be 8 bytes"
        )
    )


def test_import_dictionary_with_an_empty_value_table() raises:
    # An empty value table that comes with a NULL offsets buffer imports, and
    # the importer writes the canonical offsets `[0]` itself.
    var a = _arr(0, 2)
    a.dictionary = _ha(_arr(0, 3))
    var c = _import_column(a, ArrowType.DICTIONARY)
    assert_true(c.arrow_type == ArrowType.DICTIONARY)
    assert_equal(c._dict_size, 0)
    assert_equal(c._offsets.value().len(), 4)
    assert_equal(Int(c._offsets.value().read_i32_le_at(0)), 0)
    assert_equal(c._dict_data.value().len(), 0)


# --- LIST / STRUCT / MAP / UNION ---------------------------------------------------


def _nested_error(t: ArrowType, fmt: String, mode: Int) -> String:
    """A one-child nested array of length 0 and its schema, broken by `mode`:
    0 no schema, 1 child count 0 (STRUCT/UNION: on the schema), 2 NULL array
    children, 3 NULL schema children, 4 NULL child array, 5 NULL child schema,
    6 NULL child format, 7 (MAP) entries format `l`, 8 (MAP) NULL entries
    format."""
    var is_map = t == ArrowType.MAP
    var nb = _arrow_type_n_buffers_or(t)
    var kid_a: _AP
    var kid_s: _SP
    if is_map:
        var e = _arr(0, 1)
        _akids(e, [_ha(_arr(0, 3)), _ha(_arr(0, 2))])
        kid_a = _ha(e^)
        var es = _sch("+s", "entries")
        _skids(es, [_hs(_sch("u", "key")), _hs(_sch("l", "value"))])
        kid_s = _hs(es^)
    else:
        kid_a = _ha(_arr(0, 2))
        kid_s = _hs(_sch("l", "x"))
    var a = _arr(0, nb)
    _akids(a, [kid_a])
    var s = _sch(fmt, "p")
    _skids(s, [kid_s])
    var counted_on_schema = t == ArrowType.STRUCT or t == ArrowType.UNION_SPARSE
    if mode == 1:
        if counted_on_schema:
            s.n_children = 0
        else:
            a.n_children = 0
    elif mode == 2:
        a.children = _null_ptr[_AP, MutUntrackedOrigin]()
    elif mode == 3:
        s.children = _null_ptr[_SP, MutUntrackedOrigin]()
    elif mode == 4:
        (a.children + 0).unsafe_write(_null_a())
    elif mode == 5:
        (s.children + 0).unsafe_write(_null_s())
    elif mode == 6:
        kid_s[].format = _null_c()
    elif mode == 7:
        kid_s[].format = _copy_string_to_c_int8(String("l"))
    elif mode == 8:
        kid_s[].format = _null_c()
    var sp = _hs(s^)
    return _import_error(a, t, _null_s() if mode == 0 else sp)


def _arrow_type_n_buffers_or(t: ArrowType) -> Int:
    try:
        return _arrow_type_n_buffers(t)
    except:
        return -1


def _p(msg: String) -> String:
    return "from_arrow_c_stream: " + msg


def test_import_list_refusals() raises:
    var t = ArrowType.LIST
    assert_equal(_nested_error(t, "+l", 0), _p("LIST column requires a matching CArrowSchema for child-type recursion"))
    assert_equal(_nested_error(t, "+l", 1), _p("LIST array must have 1 child, got 0"))
    assert_equal(_nested_error(t, "+l", 2), _p("LIST array has NULL children array"))
    assert_equal(_nested_error(t, "+l", 4), _p("LIST child array is NULL"))
    assert_equal(_nested_error(t, "+l", 3), _p("LIST schema has NULL children array"))
    assert_equal(_nested_error(t, "+l", 5), _p("LIST child schema is NULL"))
    assert_equal(_nested_error(t, "+l", 6), _unrecognized(""))


def test_import_struct_refusals() raises:
    var t = ArrowType.STRUCT
    assert_equal(_nested_error(t, "+s", 0), _p("STRUCT column requires a matching CArrowSchema for child-type recursion"))
    assert_equal(_nested_error(t, "+s", 1), _p("STRUCT schema/array children mismatch: 0 vs 1"))
    assert_equal(_nested_error(t, "+s", 2), _p("STRUCT array has NULL children array"))
    assert_equal(_nested_error(t, "+s", 3), _p("STRUCT schema has NULL children array"))
    assert_equal(_nested_error(t, "+s", 4), _p("STRUCT child #0 has NULL schema or array"))
    assert_equal(_nested_error(t, "+s", 5), _p("STRUCT child #0 has NULL schema or array"))
    assert_equal(_nested_error(t, "+s", 6), _unrecognized(""))


def test_import_map_refusals() raises:
    var t = ArrowType.MAP
    assert_equal(_nested_error(t, "+m", 0), _p("MAP column requires a matching CArrowSchema for child-type recursion"))
    assert_equal(_nested_error(t, "+m", 1), _p("MAP array must have 1 entries child, got 0"))
    assert_equal(_nested_error(t, "+m", 2), _p("MAP array has NULL children array"))
    assert_equal(_nested_error(t, "+m", 3), _p("MAP schema has NULL children array"))
    assert_equal(_nested_error(t, "+m", 4), _p("MAP entries child is NULL"))
    assert_equal(_nested_error(t, "+m", 5), _p("MAP entries child is NULL"))
    assert_equal(_nested_error(t, "+m", 7), _p("MAP entries child must be STRUCT, got format 'l'"))
    # A NULL entries format fails as an unrecognized format before the STRUCT
    # check reads it.
    assert_equal(_nested_error(t, "+m", 8), _unrecognized(""))


def test_import_union_refusals() raises:
    var t = ArrowType.UNION_SPARSE
    assert_equal(_nested_error(t, "+us:4", 0), _p("UNION column requires a matching CArrowSchema for child-type recursion"))
    assert_equal(_nested_error(t, "+us:4", 1), _p("UNION schema/array children mismatch: 0 vs 1"))
    assert_equal(_nested_error(t, "+us:4", 2), _p("UNION array has NULL children array"))
    assert_equal(_nested_error(t, "+us:4", 3), _p("UNION schema has NULL children array"))
    assert_equal(_nested_error(t, "+us:4", 4), _p("UNION child #0 has NULL schema or array"))
    assert_equal(_nested_error(t, "+us:4", 5), _p("UNION child #0 has NULL schema or array"))
    assert_equal(_nested_error(t, "+us:4", 6), _unrecognized(""))


def test_import_nested_defaults_with_null_child_names() raises:
    # A NULL child `name` (Optional in the spec) takes the default name; a NULL
    # offsets buffer of an empty LIST / MAP becomes the canonical `[0]`.
    var la = _arr(0, 2)
    _akids(la, [_ha(_arr(0, 2))])
    var ls = _sch("+l")
    var lk = _sch("l")
    lk.name = _null_c()
    _skids(ls, [_hs(lk^)])
    var lsp = _hs(ls^)
    var l = _import_column(la, ArrowType.LIST, 0, 0, lsp)
    assert_equal(l.field_name(0), String("item"))
    assert_equal(l._offsets.value().len(), 4)
    assert_equal(Int(l._offsets.value().read_i32_le_at(0)), 0)
    assert_true(l.child_at(0).arrow_type == ArrowType.INT64)

    var sa = _arr(0, 1)
    _akids(sa, [_ha(_arr(0, 2))])
    var ss = _sch("+s")
    var sk = _sch("l")
    sk.name = _null_c()
    _skids(ss, [_hs(sk^)])
    var s = _import_column(sa, ArrowType.STRUCT, 0, 0, _hs(ss^))
    assert_equal(s.field_name(0), String("f0"))

    var ua = _arr(0, 1)
    _akids(ua, [_ha(_arr(0, 2))])
    var us = _sch("+us:4")
    var uk = _sch("l")
    uk.name = _null_c()
    _skids(us, [_hs(uk^)])
    var usp = _hs(us^)
    var u = _import_column(ua, ArrowType.UNION_SPARSE, 0, 0, usp, False, [4])
    assert_equal(u.field_name(0), String("f0"))
    assert_equal(u.type_ids()[0], 4, "declared ids, one per child")
    var u2 = _import_column(ua, ArrowType.UNION_SPARSE, 0, 0, usp, False, [4, 5])
    assert_equal(u2.type_ids()[0], 0, "a count that disagrees falls back to 0..n-1")

    var ma = _arr(0, 2)
    var e = _arr(0, 1)
    _akids(e, [_ha(_arr(0, 3)), _ha(_arr(0, 2))])
    _akids(ma, [_ha(e^)])
    var ms = _sch("+m")
    var es = _sch("+s", "entries")
    _skids(es, [_hs(_sch("u", "key")), _hs(_sch("l", "value"))])
    _skids(ms, [_hs(es^)])
    var m = _import_column(ma, ArrowType.MAP, 0, 0, _hs(ms^), True)
    assert_true(m.keys_sorted())
    assert_equal(m.field_name(0), String("entries"))
    assert_equal(Int(m._offsets.value().read_i32_le_at(0)), 0)
    assert_equal(m.child_at(0).field_name(1), String("value"))


# --- the root schema ------------------------------------------------------------


def _root(var kid: CArrowSchema) -> _SP:
    var r = _sch("+s")
    _skids(r, [_hs(kid^)])
    return _hs(r^)


def _root_error(sp: _SP) -> String:
    try:
        _ = _read_root_schema(sp)
    except e:
        return String(e)
    return String("(read)")


def _dict_kid(index_fmt: String, value_fmt: String) -> CArrowSchema:
    var k = _sch(index_fmt, "d")
    k.dictionary = _hs(_sch(value_fmt))
    return k^


def test_read_root_schema_refusals() raises:
    assert_equal(_root_error(_null_s()), _p("get_schema returned a NULL ArrowSchema"))
    var nf = _sch("+s")
    nf.format = _null_c()
    assert_equal(_root_error(_hs(nf^)), _p("ArrowSchema has a NULL format string"))
    var nc = _sch("+s")
    nc.n_children = 1
    assert_equal(_root_error(_hs(nc^)), _p("struct schema has NULL children array"))
    var nk = _sch("+s")
    _skids(nk, [_null_s()])
    assert_equal(_root_error(_hs(nk^)), _p("child schema #0 is NULL"))
    var kf = _sch("l")
    kf.format = _null_c()
    assert_equal(_root_error(_root(kf^)), _unrecognized(""))
    assert_equal(
        _root_error(_root(_dict_kid("I", "u"))),
        _p("dictionary index type must be signed int (INT8/16/32/64), got 'I'"),
    )
    assert_equal(
        _root_error(_root(_dict_kid("i", "l"))),
        _p("dictionary value type 'l' — only STRING ('u') values are supported; other value types are not"),
    )
    var dv = _dict_kid("i", "u")
    dv.dictionary[].format = _null_c()
    assert_equal(
        _root_error(_root(dv^)),
        _p("dictionary value type '' — only STRING ('u') values are supported; other value types are not"),
    )


def test_read_root_schema_defaults_and_index_types() raises:
    var k = _sch("l")
    k.name = _null_c()
    var info = _read_root_schema(_root(k^))
    assert_equal(info.names[0], String("f0"))
    assert_true(info.arrow_types[0] == ArrowType.INT64)
    assert_false(info.nullables[0])
    var fmts: List[String] = ["c", "s", "i", "l"]
    var want = [ArrowType.INT8, ArrowType.INT16, ArrowType.INT32, ArrowType.INT64]
    for i in range(4):
        var di = _read_root_schema(_root(_dict_kid(fmts[i], "u")))
        assert_true(di.arrow_types[0] == ArrowType.DICTIONARY)
        assert_true(di.dict_index_types[0] == want[i], fmts[i])


# --- the root array -------------------------------------------------------------


def _batch_error(arr: _AP, kid_fmt: String, sch_mode: Int) -> String:
    """`_import_record_batch` over a one-column schema of `kid_fmt`; the root
    schema handed to it is 0 none, 1 the real one, 2 one with NULL children."""
    var root = _root(_sch(kid_fmt, "c"))
    var sch = root
    if sch_mode == 0:
        sch = _null_s()
    elif sch_mode == 2:
        var r = _sch("+s")
        r.n_children = 1
        sch = _hs(r^)
    try:
        var info = _read_root_schema(root)
        _ = _import_record_batch(arr, info, _build_schema_from_info(info), sch)
    except e:
        return String(e)
    return String("(imported)")


def test_import_record_batch_refusals() raises:
    assert_equal(_batch_error(_null_a(), "l", 1), _p("get_next returned a NULL ArrowArray"))
    assert_equal(_batch_error(_ha(_arr(0, 1)), "l", 1), _p("ArrowArray has 0 children, schema has 1"))
    var nk = _arr(0, 1)
    _akids(nk, [_null_a()])
    assert_equal(_batch_error(_ha(nk^), "l", 1), _p("child array #0 is NULL"))
    # A MAP column with no schema to recurse into: none handed in, or one
    # whose children array is NULL.
    for mode in [0, 2]:
        var m = _arr(0, 1)
        _akids(m, [_ha(_arr(0, 2, 1))])
        assert_equal(
            _batch_error(_ha(m^), "+m", mode),
            _p("MAP column requires a matching CArrowSchema for child-type recursion"),
        )


# --- the tables --------------------------------------------------------------------


def test_format_strings_the_import_accepts() raises:
    var fmts: List[String] = [
        "n", "b", "i", "g", "u", "z", "U", "Z", "tdD", "tdm", "tsn:", "d:5,2",
        "d:5,2,256", "tts", "tDs", "tiM", "+l", "+s", "+m", "+us:1", "+ud:1",
    ]
    var want = [
        ArrowType.NULL, ArrowType.BOOL, ArrowType.INT32, ArrowType.FLOAT64,
        ArrowType.STRING, ArrowType.BINARY, ArrowType.LARGE_STRING,
        ArrowType.LARGE_BINARY, ArrowType.DATE32, ArrowType.DATE64,
        ArrowType.TIMESTAMP_NS, ArrowType.DECIMAL128, ArrowType.DECIMAL256,
        ArrowType.TIME32_S, ArrowType.DURATION_S, ArrowType.INTERVAL_YEAR_MONTH,
        ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP, ArrowType.UNION_SPARSE,
        ArrowType.UNION_DENSE,
    ]
    for i in range(len(fmts)):
        assert_true(_format_string_to_arrow_type(fmts[i]) == want[i], fmts[i])


def test_format_strings_the_import_refuses() raises:
    # `parse_format_string` answers NULL for every string it does not map to a
    # type of the drain subset (`+L`, the views, `w:`), so all of them are
    # refused as unrecognized; the "not in the supported drain subset" arm
    # after it has no input that reaches it.
    for fmt in [String(""), String("xyz"), String("+L"), String("vu"), String("w:4")]:
        var msg = String("")
        try:
            _ = _format_string_to_arrow_type(fmt)
        except e:
            msg = String(e)
        assert_equal(msg, _unrecognized(fmt))


def test_decimal_format_bit_widths() raises:
    var a = _parse_decimal_format("d:10,2")
    assert_equal(a[0], 10)
    assert_equal(a[1], 2)
    var b = _parse_decimal_format("d:10,2,128")
    assert_equal(b[0], 10)
    assert_equal(b[1], 2)
    var c = _parse_decimal_format("d:50,4,256")
    assert_equal(c[0], 50)
    assert_equal(c[1], 4)
    var msg = String("")
    try:
        _ = _parse_decimal_format("d:10,2,64")
    except e:
        msg = String(e)
    assert_equal(msg, String("UnsupportedArrowCABIType: decimal bitwidth '64' (only 128 and 256 supported)"))


def _unsupported_text(t: String, where: String) -> String:
    return (
        "UnsupportedArrowCABIType: Arrow type '" + t
        + "' is not in the supported Arrow C Data Interface subset (" + where + ")"
    )


def test_element_widths() raises:
    var types = [
        ArrowType.INT8, ArrowType.UINT8, ArrowType.INT16, ArrowType.UINT16,
        ArrowType.FLOAT16, ArrowType.INT32, ArrowType.UINT32, ArrowType.FLOAT32,
        ArrowType.DATE32, ArrowType.TIME32_S, ArrowType.TIME32_MS,
        ArrowType.INTERVAL_YEAR_MONTH, ArrowType.INT64, ArrowType.UINT64,
        ArrowType.FLOAT64, ArrowType.DATE64, ArrowType.TIMESTAMP_NS,
        ArrowType.TIME64_US, ArrowType.TIME64_NS, ArrowType.DURATION_MS,
        ArrowType.INTERVAL_DAY_TIME, ArrowType.INTERVAL_MONTH_DAY_NANO,
        ArrowType.DECIMAL256,
    ]
    var widths = [1, 1, 2, 2, 2, 4, 4, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8, 8, 8, 8, 8, 16, 32]
    for i in range(len(types)):
        assert_equal(_arrow_fixed_width_bytes(types[i]), widths[i], String(types[i]))
    var msg = String("")
    try:
        _ = _arrow_fixed_width_bytes(ArrowType.STRING)
    except e:
        msg = String(e)
    assert_true(msg.startswith(_unsupported_text("string", "drain")), msg)


def test_buffer_counts() raises:
    var types = [
        ArrowType.INT16, ArrowType.FLOAT32, ArrowType.BOOL, ArrowType.DATE32,
        ArrowType.DATE64, ArrowType.TIMESTAMP_MS, ArrowType.DECIMAL128,
        ArrowType.DECIMAL256, ArrowType.TIME64_NS, ArrowType.DURATION_NS,
        ArrowType.INTERVAL_DAY_TIME, ArrowType.STRING, ArrowType.BINARY,
        ArrowType.LARGE_STRING, ArrowType.LARGE_BINARY, ArrowType.DICTIONARY,
        ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP, ArrowType.UNION_SPARSE,
        ArrowType.UNION_DENSE,
    ]
    var counts = [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 2, 2, 1, 2, 1, 2]
    for i in range(len(types)):
        assert_equal(_arrow_type_n_buffers(types[i]), counts[i], String(types[i]))
    for t in [ArrowType.NULL, ArrowType.FIXED_SIZE_BINARY, ArrowType.LARGE_LIST]:
        var msg = String("")
        try:
            _ = _arrow_type_n_buffers(t)
        except e:
            msg = String(e)
        assert_true(msg.startswith(_unsupported_text(String(t), "export")), msg)


def test_export_format_of_a_type_outside_the_subset() raises:
    # These three are reached only after `_arrow_type_n_buffers` has accepted
    # the type, so on the stream paths their "n" refusal never fires; called
    # directly, each refuses rather than export the NULL format `n`.
    var fsb = Column[HeapRegion]()
    fsb.arrow_type = ArrowType.FIXED_SIZE_BINARY
    var msg = String("")
    try:
        _ = _column_format_string(fsb)
    except e:
        msg = String(e)
    assert_true(msg.startswith(_unsupported_text("fixed_size_binary", "export")), msg)
    msg = String("")
    try:
        _ = _build_column_schema_from_field(Field("f", ArrowType.FIXED_SIZE_BINARY, True))
    except e:
        msg = String(e)
    assert_true(msg.startswith(_unsupported_text("fixed_size_binary", "export")), msg)
    msg = String("")
    try:
        _ = _build_column_schema_from_field_and_column(
            Field("f", ArrowType.FIXED_SIZE_BINARY, True), fsb
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith(_unsupported_text("fixed_size_binary", "export")), msg)
    # The NULL type itself is the one "n" that is not a refusal.
    assert_equal(_column_format_string(Column[HeapRegion]()), String("n"))
    var fc = _build_column_schema_from_field_and_column(
        Field("z", ArrowType.NULL, True), Column[HeapRegion]()
    )
    assert_equal(_c_str_to_mojo(fc.format), String("n"))
    var fcp = _hs(fc^)
    release_c_schema(fcp)
    fcp.free()
    var s = _build_column_schema_from_field(Field("z", ArrowType.NULL, True))
    assert_equal(_c_str_to_mojo(s.format), String("n"))
    var sp = _hs(s^)
    release_c_schema(sp)
    assert_true(sp[].is_released())
    sp.free()


def _dec_array(width: Int) -> CArrowArray:
    var a = _arr(1, 2)
    var bytes = List[Int]()
    bytes.append(9)
    for _ in range(width - 1):
        bytes.append(0)
    (a.buffers + 1).unsafe_write(_bytes(bytes))
    return a^


def test_import_decimal_precision_and_scale_defaults() raises:
    # (precision, scale) handed in by the caller; out of range they fall back
    # to the bit width's default precision and scale 0.
    # The last two rows pin a KNOWN CORRUPTION, not expected behaviour: Arrow
    # allows a negative scale and a scale greater than the precision, yet
    # `scale -1 -> 0` and `scale 11 > precision 10 -> 0` silently rewrite the
    # value's meaning (komira-ai/komira#904 item 5). A fix for #904 flips
    # these two asserts on purpose; update them with that fix.
    for w in [16, 32]:
        var t = ArrowType.DECIMAL128 if w == 16 else ArrowType.DECIMAL256
        var dflt = 38 if w == 16 else 76
        var a = _dec_array(w)
        var c = _import_column(a, t, 10, 2)
        assert_equal(c.decimal_precision(), 10)
        assert_equal(c.decimal_scale(), 2)
        assert_equal(Int(c._data.read_u8_at(0)), 9)
        var d = _import_column(a, t)
        assert_equal(d.decimal_precision(), dflt, "no precision: the default")
        assert_equal(d.decimal_scale(), 0)
        assert_equal(_import_column(a, t, 10, -1).decimal_scale(), 0, "scale below 0")
        assert_equal(_import_column(a, t, 10, 11).decimal_scale(), 0, "scale above precision")


def test_decimal_format_defaults() raises:
    # `_parse_decimal_format` keeps a format it cannot honour rather than
    # refusing it: precision 0 or above the width's bound becomes the bound,
    # a scale above the precision becomes the precision, and a malformed
    # `d:` string (which `extract_decimal_params` reads as width 0) is
    # Decimal128(38, 0). The C Data Interface gives none of these a default.
    var cases: List[String] = ["d:0,2", "d:40,2", "d:5,7", "d:80,2,256", "d:x,2"]
    var want_p = [38, 38, 5, 76, 38]
    var want_s = [2, 2, 5, 2, 0]
    for i in range(len(cases)):
        var ps = _parse_decimal_format(cases[i])
        assert_equal(ps[0], want_p[i], cases[i])
        assert_equal(ps[1], want_s[i], cases[i])


def _partial_info() -> _ImportedSchemaInfo:
    """Names, types and nullability only: every parameter list left empty."""
    var info = _ImportedSchemaInfo()
    var names: List[String] = ["d", "t", "u", "x", "y"]
    var types = [
        ArrowType.DICTIONARY, ArrowType.TIMESTAMP_MS, ArrowType.UNION_SPARSE,
        ArrowType.DECIMAL128, ArrowType.DECIMAL256,
    ]
    for i in range(len(names)):
        info.names.append(names[i])
        info.arrow_types.append(types[i])
        info.nullables.append(True)
    return info^


def test_schema_from_partial_info_uses_field_defaults() raises:
    var s = _build_schema_from_info(_partial_info())
    assert_equal(s.num_columns(), 5)
    assert_true(s.field_at(0).dict_index_type() == ArrowType.INT32)
    assert_equal(s.field_at(1).timezone(), String(""))
    assert_equal(len(s.field_at(2).union_type_ids()), 0)
    assert_equal(s.field_at(3).decimal_precision, 0, "no (p, s) to stamp")
    assert_equal(Int(s.field_at(3).flags()), 0)
    assert_equal(s.field_at(4).metadata_count(), 0)

    # One list of a pair present and its twin missing reads as neither.
    var info = _ImportedSchemaInfo()
    info.names.append("x")
    info.arrow_types.append(ArrowType.DECIMAL128)
    info.nullables.append(True)
    info.dec_precisions.append(10)
    info.metadata_keys.append(["k"])
    var s2 = _build_schema_from_info(info)
    assert_equal(s2.field_at(0).decimal_precision, 0, "precisions without scales")
    assert_equal(s2.field_at(0).metadata_count(), 0, "keys without values")


def test_import_record_batch_from_partial_info() raises:
    # Without the per-column decimal and union lists the batch import passes
    # precision 0 (the width's default) and no declared union ids.
    var info = _ImportedSchemaInfo()
    var names: List[String] = ["x", "y", "u"]
    var types = [ArrowType.DECIMAL128, ArrowType.DECIMAL256, ArrowType.UNION_SPARSE]
    for i in range(3):
        info.names.append(names[i])
        info.arrow_types.append(types[i])
        info.nullables.append(True)
    var root = _arr(1, 1)
    _akids(root, [_ha(_dec_array(16)), _ha(_dec_array(32)), _ha(_arr(0, 1))])
    var rs = _sch("+s")
    _skids(rs, [_hs(_sch("d:10,2", "x")), _hs(_sch("d:10,2,256", "y")), _hs(_sch("+us:", "u"))])
    var b = _import_record_batch(_ha(root^), info, _build_schema_from_info(info), _hs(rs^))
    assert_equal(b.num_columns(), 3)
    assert_equal(b.column_at(0).decimal_precision(), 38)
    assert_equal(b.column_at(1).decimal_precision(), 76)
    assert_equal(len(b.column_at(2).type_ids()), 0)

    # Precisions without scales: the pair is not used.
    var info2 = _ImportedSchemaInfo()
    info2.names.append("x")
    info2.arrow_types.append(ArrowType.DECIMAL128)
    info2.nullables.append(True)
    info2.dec_precisions.append(10)
    var root2 = _arr(1, 1)
    _akids(root2, [_ha(_dec_array(16))])
    var b2 = _import_record_batch(_ha(root2^), info2, _build_schema_from_info(info2))
    assert_equal(b2.column_at(0).decimal_precision(), 38)


def test_null_tolerant_helpers() raises:
    assert_equal(_c_str_to_mojo(_null_c()), String(""))
    assert_equal(Int(_alloc_buffers_array(0)), 0)
    assert_equal(Int(_alloc_schema_ptr_array(0)), 0)
    assert_equal(Int(_alloc_array_ptr_array(0)), 0)
    assert_equal(
        _stream_error_text(_null_ptr[CArrowArrayStream, MutUntrackedOrigin]()),
        String("(no stream)"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
