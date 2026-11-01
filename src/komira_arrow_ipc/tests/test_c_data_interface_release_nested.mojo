# =============================================================================
# test_c_data_interface_release_nested.mojo: the release callbacks on
# structs with metadata, children and a dictionary, and decode_metadata's
# refusals
# =============================================================================
#
# export_schema / export_primitive produce flat structs, so
# test_c_data_interface_release.mojo reaches only the format, name and
# buffers frees. A struct this module releases may also carry metadata,
# a children array (whose slots may be NULL) and a dictionary, all of them
# heap allocations the release must free and NULL. These tests build such
# structs out of exported ones (heap-stored and read through their pointer,
# as test_c_data_interface_release.mojo explains), release them, and check
# every member the release must reset. A NULL struct pointer is a no-op.
#
# decode_metadata refuses a negative or implausibly large key count, key
# length and value length; each refusal is driven by a hand-packed buffer.
#
# FFI-BOUNDARY: the Arrow C Data Interface structs (and the children arrays
# of struct pointers) this file builds by hand as a stand-in foreign
# producer, and the metadata buffers it packs for decode_metadata, are
# spelled with MutUntrackedOrigin, as release_c_schema / release_c_array
# take them (tests/pointer_lint_ffi.tsv lists this file). Ownership: each
# test frees its root struct and its packed metadata buffer with `.free()`;
# the children arrays, child and dictionary structs it hangs off a root are
# handed to the struct and freed (and NULLed) by its release callback.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.memory import alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow_ipc.c_data_interface import (
    CArrowSchema,
    CArrowArray,
    _null_ptr,
    decode_metadata,
    encode_metadata,
    export_primitive,
    export_schema,
    release_c_array,
    release_c_schema,
)


comptime _SchemaP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _ArrayP = UnsafePointer[CArrowArray, MutUntrackedOrigin]


def _schema(name: String) -> _SchemaP:
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(export_schema(Field(name, ArrowType.INT32, False)))
    return sp


def _array(n: Int) -> _ArrayP:
    var arr = PrimitiveArray[DType.int32].allocate(n)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(export_primitive[DType.int32](arr))
    return ap


def test_schema_release_frees_metadata_children_and_dictionary() raises:
    """A schema with metadata, a three-slot children array (the middle slot
    NULL, the last child itself holding a child) and a dictionary: after
    the release every one of them is NULL and n_children is 0."""
    var sp = _schema("parent")
    var keys = List[String]()
    keys.append(String("k"))
    var vals = List[String]()
    vals.append(String("v"))
    sp[].metadata = encode_metadata(keys, vals)
    assert_true(Int(sp[].metadata) != 0)

    var grandchild = _schema("grandchild")
    var last = _schema("last")
    var last_kids = alloc[_SchemaP](1).unsafe_origin_cast[MutUntrackedOrigin]()
    last_kids.unsafe_write(grandchild)
    last[].children = last_kids
    last[].n_children = 1

    var kids = alloc[_SchemaP](3).unsafe_origin_cast[MutUntrackedOrigin]()
    kids.unsafe_write(_schema("first"))
    (kids + 1).unsafe_write(_null_ptr[CArrowSchema, MutUntrackedOrigin]())
    (kids + 2).unsafe_write(last)
    sp[].children = kids
    sp[].n_children = 3
    sp[].dictionary = _schema("dict")

    release_c_schema(sp)
    assert_true(sp[].is_released())
    assert_equal(Int(sp[].format), 0)
    assert_equal(Int(sp[].name), 0)
    assert_equal(Int(sp[].metadata), 0)
    assert_equal(Int(sp[].children), 0)
    assert_equal(Int(sp[].dictionary), 0)
    assert_equal(sp[].n_children, 0)
    # Idempotent: a second release frees nothing twice.
    release_c_schema(sp)
    assert_true(sp[].is_released())
    sp.free()


def test_schema_release_with_children_count_but_no_array() raises:
    """n_children > 0 with a NULL children pointer: nothing to walk; the
    release still completes and zeroes the count."""
    var sp = _schema("p")
    sp[].n_children = 2
    release_c_schema(sp)
    assert_true(sp[].is_released())
    assert_equal(sp[].n_children, 0)
    sp.free()


def test_array_release_frees_children_and_dictionary() raises:
    var ap = _array(4)
    var grandchild = _array(1)
    var last = _array(2)
    var last_kids = alloc[_ArrayP](1).unsafe_origin_cast[MutUntrackedOrigin]()
    last_kids.unsafe_write(grandchild)
    last[].children = last_kids
    last[].n_children = 1

    var kids = alloc[_ArrayP](3).unsafe_origin_cast[MutUntrackedOrigin]()
    kids.unsafe_write(_array(3))
    (kids + 1).unsafe_write(_null_ptr[CArrowArray, MutUntrackedOrigin]())
    (kids + 2).unsafe_write(last)
    ap[].children = kids
    ap[].n_children = 3
    ap[].dictionary = _array(5)

    release_c_array(ap)
    assert_true(ap[].is_released())
    assert_equal(Int(ap[].children), 0)
    assert_equal(Int(ap[].dictionary), 0)
    assert_equal(Int(ap[].buffers), 0)
    assert_equal(ap[].n_children, 0)
    assert_equal(ap[].n_buffers, 0)
    release_c_array(ap)
    assert_true(ap[].is_released())
    ap.free()


def test_release_of_a_null_pointer_is_a_no_op() raises:
    release_c_schema(_null_ptr[CArrowSchema, MutUntrackedOrigin]())
    release_c_array(_null_ptr[CArrowArray, MutUntrackedOrigin]())


# ---------------------------------------------------------------------------
# decode_metadata refusals
# ---------------------------------------------------------------------------


def _packed(words: List[Int32]) -> UnsafePointer[Int8, MutUntrackedOrigin]:
    """Little-endian i32 words, one after another (no key or value bytes:
    every refusal below fires on the length word before any bytes are
    read)."""
    var p = alloc[Int8](4 * len(words)).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(len(words)):
        var u = UInt32(Int(words[i]) & 0xFFFFFFFF)
        for b in range(4):
            (p + i * 4 + b).unsafe_write(Int8(Int((u >> UInt32(8 * b)) & 0xFF)))
    return p


def _decode_error(var words: List[Int32]) -> String:
    var p = _packed(words)
    var msg = String("no error")
    try:
        _ = decode_metadata(p)
    except e:
        msg = String(e)
    p.free()
    return msg


def _w(a: Int, b: Int = -999, c: Int = -999) -> List[Int32]:
    var out = List[Int32]()
    out.append(Int32(a))
    if b != -999:
        out.append(Int32(b))
    if c != -999:
        out.append(Int32(c))
    return out^


def test_decode_metadata_refuses_implausible_lengths() raises:
    # A negative word is refused. The number the message gives for it is
    # not pinned: the library build reads the i32 -1 as 4294967295
    # (komira-ai/komira#1063), which this test must not encode.
    assert_true(
        _decode_error(_w(-1)).startswith(
            "decode_metadata: implausible key count "
        )
    )
    assert_true(
        _decode_error(_w(1, -1)).startswith(
            "decode_metadata: implausible key length "
        )
    )
    assert_true(
        _decode_error(_w(1, 0, -1)).startswith(
            "decode_metadata: implausible value length "
        )
    )
    assert_equal(
        _decode_error(_w((1 << 20) + 1)),
        "decode_metadata: implausible key count 1048577",
    )
    assert_equal(
        _decode_error(_w(1, (1 << 28) + 1)),
        "decode_metadata: implausible key length 268435457",
    )
    assert_equal(
        _decode_error(_w(1, 0, (1 << 28) + 1)),
        "decode_metadata: implausible value length 268435457",
    )


def test_decode_metadata_accepts_empty_key_and_value() raises:
    """The control for the refusals: count 1, key length 0, value length 0
    decodes to one empty pair."""
    var p = _packed(_w(1, 0, 0))
    var kv = decode_metadata(p)
    p.free()
    assert_equal(len(kv[0]), 1)
    assert_equal(kv[0][0], String(""))
    assert_equal(kv[1][0], String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
