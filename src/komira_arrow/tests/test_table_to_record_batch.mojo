# =============================================================================
# Tests for `Table.to_record_batch()` -- the door that CONCATENATES
# =============================================================================
#
# ⭐ WHY THIS IS A SEPARATE FILE FROM `test_arrow_table.mojo`, AND WHY THAT IS
# THE POINT. `Table` has TWO doors to one contiguous batch and they have
# OPPOSITE contracts:
#
#   `into_single_batch()`   ASSERTS      -- raises on >1 chunk, because its
#                                           callers drive the producer at a
#                                           budget that cannot segment, so >1
#                                           chunk there is a ROUTING BUG. `test_arrow_table.mojo`
#                                           pins that raise and must keep
#                                           pinning it.
#   `to_record_batch()`     CONCATENATES -- for the caller that asked for one
#                                           buffer on purpose. THIS file.
#
# Keeping the two test surfaces textually apart is deliberate: the single
# cheapest way to destroy the design is for someone to "unify" the two methods,
# and that edit is much easier to make when both contracts are asserted in one
# file under one header.
#
# WHAT IS PINNED HERE
#   1. n == 0 -> a ZERO-ROW batch carrying the FULL schema (physical column
#      count included), not a bare `RecordBatch()`. A
#      schema-less empty batch makes a downstream Project raise
#      `Schema.column_index: no field named '<k>'`.
#   2. n == 1 -> the chunk is MOVED. Asserted on the BUFFER ADDRESS, not on
#      the values: a deep copy would pass every value assertion while silently
#      re-paying the copy this whole type exists to remove.
#   3. n > 1 fixed-width -> values, ROW ORDER (chunk order, not arrival
#      order), schema.
#   4. n > 1 STRING -> the OFFSETS buffer at the seams. ⚠ A value differential
#      is structurally BLIND to an offsets defect: rebasing offsets wrongly and
#      then reading them back with the same wrong rebase reproduces the input
#      values exactly. The offsets are asserted as NUMBERS.
#   5. n > 1 DICTIONARY with DIVERGENT dictionaries -> the merged DICTIONARY
#      ENTRIES and the REMAPPED CODES, not just the decoded strings. Decoding
#      is self-consistent under a wrong remap that happens to point at the
#      right entry; the codes are the thing that can be wrong on its own.
#      ⭐ `test_dict_merge.mojo` covers `merge_dict_columns`, which
#      `_concat_one_column_nway` does not call, so this is the direct test of
#      this path.
#   6. n > 1 DICTIONARY with BYTE-IDENTICAL dictionaries -> the memcpy fast
#      path. It is a DIFFERENT kernel from item 5 and neither covers the other.
#   7. Layout-divergent chunks cannot reach a wrong answer THROUGH this method.
#      Two halves, and the second is the load-bearing one:
#        (a) `from_chunks` refuses the chunk under a KNOWN table schema, so the
#            Table cannot be built at all;
#        (b) under a table schema whose layout class is UNKNOWN (`NULL` --
#            admitted on purpose, it is the `Column` MOVE defect's signature)
#            comparing each chunk only to the TABLE SCHEMA would admit a
#            `string` chunk beside a `large_string` one. `from_chunks` also
#            compares the chunks to EACH OTHER wherever the schema's class is
#            UNKNOWN, so `to_record_batch()` cannot be HANDED such a table at
#            all -- and this file asserts BOTH that refusal and
#            that the guard the method would have called
#            (`_refuse_concat_layout_disagreement`, reached via
#            `concat_record_batches_nway`) is still armed on that exact pair.
#            Asserting only the first would let a future widening of
#            `from_chunks` re-open the door onto an unchecked guard.
#   8. ROUND TRIP -- `Table.from_chunks(...).to_record_batch()` is
#      BYTE-IDENTICAL to `concat_record_batches_nway(...)` over the same input.
#      This is what pins the method as a pure routing wrapper: if it ever grows
#      a behaviour of its own, this goes red.
# =============================================================================

from std.sys import size_of
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.table import Table
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Fixtures
# =============================================================================


def _i64_schema() raises -> Schema:
    return Schema.from_fields_1(Field("v", ArrowType.INT64, False))


def _i64_batch(vals: List[Int]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, Int64(vals[i]))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive[DType.int64](arr^))
    var sch = _i64_schema()
    return b.build(sch^)


def _str_schema() raises -> Schema:
    return Schema.from_fields_1(Field("s", ArrowType.STRING, False))


def _str_batch(vals: List[String]) raises -> RecordBatch:
    var sa = StringArray.from_strings(vals)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_string(sa^))
    var sch = _str_schema()
    return b.build(sch^)


def _dict_schema() raises -> Schema:
    return Schema.from_fields_1(Field("d", ArrowType.DICTIONARY, False))


def _dict_batch(
    dict_values: List[String], codes: List[Int]
) raises -> RecordBatch:
    """A one-column DICTIONARY batch with an EXPLICIT dictionary and codes.

    Built from parts rather than from strings so the test controls the
    dictionary CONTENT and ORDER independently of the codes -- which is the
    only way to make two chunks whose dictionaries genuinely DIVERGE.
    """
    var idx = PrimitiveArray[DType.int32].allocate(len(codes))
    for i in range(len(codes)):
        idx.set(i, Int32(codes[i]))
    var dict_arr = StringArray.from_strings(dict_values)
    var sda = StringDictionaryArray.from_parts(idx^, dict_arr^)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_dictionary(sda))
    var sch = _dict_schema()
    return b.build(sch^)


def _one_field_schema(t: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", t, False))
    return sb.build()


def _large_str_batch(vals: List[String]) raises -> RecordBatch:
    """A LARGE_STRING chunk -- Int64 offsets. Its OWN schema says LARGE_STRING,
    exactly as a lockstep-promoting producer builds it."""
    var la = LargeStringArray.from_strings(vals)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_large_string(la^))
    var sch = _one_field_schema(ArrowType.LARGE_STRING)
    return b.build(sch^)


# ---- readers ----------------------------------------------------------------


def _data_ptr_addr(ref batch: RecordBatch) -> Int:
    """Address of column 0's values buffer -- the identity of the allocation."""
    return Int(batch.column_at(0)._data.view_typed_ro[DType.uint8]())


def _i64_values(ref col: Column[HeapRegion]) -> List[Int]:
    var out = List[Int](capacity=col._length)
    for i in range(col._length):
        out.append(Int(col._data.get_typed[Int64](i)))
    return out^


def _i32_offsets(ref col: Column[HeapRegion]) raises -> List[Int]:
    """The Int32 offsets buffer, all `length + 1` entries."""
    var out = List[Int](capacity=col._length + 1)
    for i in range(col._length + 1):
        out.append(Int(col._offsets.value().get_typed[Int32](i)))
    return out^


def _data_bytes(ref col: Column[HeapRegion], n: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for i in range(n):
        out.append(Int(col._data.get_typed[UInt8](i)))
    return out^


def _dict_codes(ref col: Column[HeapRegion]) -> List[Int]:
    """The per-row codes -- the Int32 index buffer, read WITHOUT resolving."""
    var out = List[Int](capacity=col._length)
    for i in range(col._length):
        out.append(Int(col._data.get_typed[Int32](i)))
    return out^


def _dict_entries(ref col: Column[HeapRegion]) raises -> List[String]:
    """The merged DICTIONARY's own entries, in dictionary order."""
    var out = List[String](capacity=col._dict_size)
    for i in range(col._dict_size):
        var s = Int(col._offsets.value().get_typed[Int32](i))
        var e = Int(col._offsets.value().get_typed[Int32](i + 1))
        var buf = List[UInt8](capacity=(e - s) + 1)
        for k in range(s, e):
            buf.append(col._dict_data.value().get_typed[UInt8](k))
        buf.append(UInt8(0))
        out.append(String(unsafe_from_utf8_ptr=buf.unsafe_ptr()))
    return out^


def _assert_int_list(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), String("length of ") + what)
    for i in range(len(want)):
        assert_equal(
            got[i], want[i], what + String(" at index ") + String(i)
        )


def _assert_str_list(
    got: List[String], want: List[String], what: String
) raises:
    assert_equal(len(got), len(want), String("length of ") + what)
    for i in range(len(want)):
        assert_true(
            got[i] == want[i],
            what
            + String(" at index ")
            + String(i)
            + String(": expected '")
            + want[i]
            + String("' got '")
            + got[i]
            + String("'"),
        )


# =============================================================================
# 1. ZERO chunks
# =============================================================================


def test_zero_chunks_returns_a_schema_carrying_empty_batch() raises:
    """`n == 0` -> 0 rows, but the FULL schema including physical columns.

    `RecordBatch.num_columns()` reads the PHYSICAL column count, so returning
    a bare `RecordBatch()` here would make a downstream Project raise
    `Schema.column_index: no field named '<k>'`. The assertion
    on `num_columns()` is the one that catches that; `num_rows() == 0` alone
    would pass over the broken shape.
    """
    print("test_zero_chunks_returns_a_schema_carrying_empty_batch...")
    var t = Table.from_chunks(List[RecordBatch](), _i64_schema())
    assert_equal(t.num_chunks(), 0)
    var rb = t^.to_record_batch()
    assert_equal(rb.num_rows(), 0, "zero-chunk table has zero rows")
    assert_equal(
        rb.num_columns(), 1, "zero-chunk batch must carry its PHYSICAL column"
    )
    assert_equal(rb.schema.num_columns(), 1, "and its schema")
    assert_true(rb.schema.field_name(0) == "v", "field name survives")
    print("  ok")


# =============================================================================
# 2. ONE chunk -- MOVED, not copied
# =============================================================================


def test_one_chunk_is_moved_not_copied() raises:
    """`n == 1` hands back the SAME allocation, not a copy of its contents.

    ⛔ ASSERTED ON THE BUFFER ADDRESS ON PURPOSE. Every value assertion in this
    file would pass over a `deep_copy()` implementation, and a deep copy at
    n == 1 re-pays the whole-result copy on the ONE shape that is supposed to
    be free -- the shape every unchunked driver produces today. The address is
    the only thing that can tell a move from a copy.
    """
    print("test_one_chunk_is_moved_not_copied...")
    var chunk = _i64_batch([11, 22, 33])
    var addr_before = _data_ptr_addr(chunk)
    var t = Table.from_batch(chunk^)
    assert_equal(t.num_chunks(), 1)
    var rb = t^.to_record_batch()
    assert_equal(
        _data_ptr_addr(rb),
        addr_before,
        "to_record_batch() must MOVE the single chunk, not copy it",
    )
    assert_equal(rb.num_rows(), 3)
    _assert_int_list(_i64_values(rb.column_at(0)), [11, 22, 33], "values")
    print("  ok")


# =============================================================================
# 3. MANY chunks, fixed width
# =============================================================================


def test_many_chunks_fixed_width_values_order_and_schema() raises:
    """`n > 1` concatenates in CHUNK ORDER and keeps the schema.

    Row order is asserted with values that are NOT sorted and NOT equal to
    their index, so a fold that reversed the chunks or sorted them would go
    red. A monotone fixture cannot tell those apart.
    """
    print("test_many_chunks_fixed_width_values_order_and_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_i64_batch([50, 40]))
    chunks.append(_i64_batch([90]))
    chunks.append(_i64_batch([10, 70, 20]))
    var t = Table.from_chunks(chunks^, _i64_schema())
    assert_equal(t.num_chunks(), 3)
    assert_equal(t.num_rows(), 6)
    var rb = t^.to_record_batch()
    assert_equal(rb.num_rows(), 6, "rows are the SUM across chunks")
    assert_equal(rb.num_columns(), 1)
    assert_true(rb.schema.field_name(0) == "v", "schema survives the concat")
    _assert_int_list(
        _i64_values(rb.column_at(0)),
        [50, 40, 90, 10, 70, 20],
        "concatenated values in chunk order",
    )
    print("  ok")


# =============================================================================
# 4. MANY chunks, VAR-LEN -- assert the OFFSETS
# =============================================================================


def test_many_chunks_string_offsets_are_rebased_at_the_seams() raises:
    """`n > 1` STRING: the OFFSETS buffer, as numbers, not just the values.

    ⚠ THIS IS THE ASSERTION A VALUE DIFFERENTIAL CANNOT MAKE. Each chunk's
    offsets start at 0 and must be shifted by the running byte total; a fold
    that forgot the shift, or applied the WRONG shift, still decodes
    self-consistently if the reader uses the same offsets. The seams are the
    entries at indices 2 and 3 (end of chunk 0 / end of chunk 1), and the
    EMPTY STRING at index 3 is deliberate: a zero-length slot is where an
    off-by-one in the rebase shows up as a duplicated rather than a repeated
    offset.
    """
    print("test_many_chunks_string_offsets_are_rebased_at_the_seams...")
    var chunks = List[RecordBatch]()
    chunks.append(_str_batch([String("aa"), String("bbb")]))  # 5 bytes
    chunks.append(_str_batch([String("c")]))  # 1 byte
    chunks.append(_str_batch([String(""), String("dddd")]))  # 4 bytes
    var t = Table.from_chunks(chunks^, _str_schema())
    var rb = t^.to_record_batch()
    assert_equal(rb.num_rows(), 5)
    ref col = rb.column_at(0)
    assert_equal(col._length, 5)
    _assert_int_list(
        _i32_offsets(col), [0, 2, 5, 6, 6, 10], "rebased int32 offsets"
    )
    var ca = Int(ord("a"))
    var cb = Int(ord("b"))
    var cc = Int(ord("c"))
    var cd = Int(ord("d"))
    _assert_int_list(
        _data_bytes(col, 10),
        [ca, ca, cb, cb, cb, cc, cd, cd, cd, cd],
        "concatenated utf-8 payload",
    )
    print("  ok")


# =============================================================================
# 5. MANY chunks, DICTIONARY with DIVERGENT dictionaries
# =============================================================================


def test_many_chunks_divergent_dictionaries_merge_and_remap() raises:
    """⭐ THE HARD PATH. Divergent per-chunk dictionaries must UNION, and the
    per-row codes must be REMAPPED into the merged dictionary's ordinals.

    This is the shape a streaming parquet result actually has -- each chunk
    "keeps its OWN RG dict so its codes resolve correctly"
    (`scan_chunk_sink.mojo`) -- and it is the arm
    `_concat_one_column_nway` serves with a PAIR-WISE fold rather than an
    N-way kernel (see `Table.to_record_batch`'s docstring: O(N^2)).

    ⛔ THE CODES ARE ASSERTED SEPARATELY FROM THE ENTRIES, AND THAT IS THE
    POINT. Decoding row i through the merged dictionary is self-consistent
    under a remap that is wrong in a way that happens to land on an entry with
    the same bytes -- e.g. a duplicated entry, where the dictionary is not
    actually unioned but the strings still resolve. Asserting the ENTRY LIST
    (which pins de-duplication and first-seen order) and the CODE LIST (which
    pins the remap) is what makes that unreachable.

    Fixture: chunk 0 dict ["alpha","bravo"], chunk 1 dict ["charlie"], chunk 2
    dict ["bravo","delta"]. "bravo" appears in chunks 0 and 2 at DIFFERENT
    local ordinals (1 and 0) -- so a fold that passed the local codes through
    unchanged would decode chunk 2's rows as the wrong strings.
    """
    print("test_many_chunks_divergent_dictionaries_merge_and_remap...")
    var chunks = List[RecordBatch]()
    chunks.append(_dict_batch([String("alpha"), String("bravo")], [0, 1, 0]))
    chunks.append(_dict_batch([String("charlie")], [0, 0]))
    chunks.append(_dict_batch([String("bravo"), String("delta")], [1, 0]))
    var t = Table.from_chunks(chunks^, _dict_schema())
    assert_equal(t.num_chunks(), 3)
    assert_equal(t.num_rows(), 7)
    var rb = t^.to_record_batch()
    assert_equal(rb.num_rows(), 7)
    ref col = rb.column_at(0)
    assert_true(
        col.arrow_type == ArrowType.DICTIONARY,
        "the merged column must still be DICTIONARY-typed",
    )
    assert_equal(col._length, 7)
    # The union, de-duplicated, in first-seen order.
    assert_equal(
        col._dict_size, 4, "merged dictionary must UNION, not concatenate"
    )
    _assert_str_list(
        _dict_entries(col),
        [
            String("alpha"),
            String("bravo"),
            String("charlie"),
            String("delta"),
        ],
        "merged dictionary entries",
    )
    # chunk 0 codes [0,1,0] -> [0,1,0]      (alpha, bravo, alpha)
    # chunk 1 codes [0,0]   -> [2,2]        (charlie, charlie)
    # chunk 2 codes [1,0]   -> [3,1]        (delta, bravo)  <- the remap
    _assert_int_list(
        _dict_codes(col),
        [0, 1, 0, 2, 2, 3, 1],
        "remapped per-row codes",
    )
    print("  ok")


def test_many_chunks_identical_dictionaries_take_the_memcpy_path() raises:
    """The OTHER dictionary arm: byte-identical dicts skip the union entirely.

    `_all_dicts_byte_identical` routes to `_concat_columns_nway_dict_identical`,
    a different kernel from the one item 5 exercises. Neither test covers the
    other, and the fast path is the one a same-dictionary result actually
    takes -- so the codes must pass through UNCHANGED and the dictionary must
    NOT grow.
    """
    print("test_many_chunks_identical_dictionaries_take_the_memcpy_path...")
    var d: List[String] = [String("red"), String("green"), String("blue")]
    var chunks = List[RecordBatch]()
    chunks.append(_dict_batch(d, [2, 0]))
    chunks.append(_dict_batch(d, [1]))
    chunks.append(_dict_batch(d, [0, 2, 1]))
    var t = Table.from_chunks(chunks^, _dict_schema())
    var rb = t^.to_record_batch()
    assert_equal(rb.num_rows(), 6)
    ref col = rb.column_at(0)
    assert_equal(col._dict_size, 3, "identical dicts must NOT be duplicated")
    _assert_str_list(
        _dict_entries(col),
        [String("red"), String("green"), String("blue")],
        "dictionary passes through unchanged",
    )
    _assert_int_list(
        _dict_codes(col), [2, 0, 1, 0, 2, 1], "codes pass through unchanged"
    )
    print("  ok")


# =============================================================================
# 7. Layout-divergent chunks cannot reach a wrong answer
# =============================================================================


def test_from_chunks_refuses_layout_divergence_under_a_known_schema() raises:
    """Half (a): with a KNOWN table schema the Table cannot be BUILT.

    A `large_string` chunk (Int64 offsets) under a `string` table schema
    (Int32 offsets) is refused at construction, so `to_record_batch()` is
    unreachable for this shape. Stated as its own test because it is the
    PREMISE of the next one: if this ever stops raising, the next test is
    asserting something different from what its name says.
    """
    print("test_from_chunks_refuses_layout_divergence_under_a_known_schema...")
    var chunks = List[RecordBatch]()
    chunks.append(_str_batch([String("a")]))
    chunks.append(_large_str_batch([String("b")]))
    var raised = False
    try:
        var t = Table.from_chunks(chunks^, _str_schema())
        _ = t^
    except e:
        raised = True
        assert_true(
            "PHYSICAL LAYOUT CONFLICT" in String(e),
            String("from_chunks must name the conflict, got: ") + String(e),
        )
    assert_true(raised, "from_chunks must refuse a large_string under string")
    print("  ok")


def test_to_record_batch_cannot_be_handed_layout_divergent_chunks() raises:
    """⭐ Half (b), AND THE LOAD-BEARING ONE: the bypass is closed at the
    EARLIER seam, and BOTH halves of that are asserted here.

    Under a `NULL` table schema (layout class UNKNOWN, admitted on purpose
    because a zeroed tag is the `Column` MOVE defect's signature) a check that
    compared each chunk only to the TABLE SCHEMA would admit a `string` chunk
    beside a `large_string` one. `from_chunks` also compares the chunks TO
    EACH OTHER, for exactly the columns whose table type is UNKNOWN.

    ⛔ IT IS ASSERTED IN TWO PIECES THAT CANNOT BOTH GO VACUOUS:
      (1) NO `Table` CAN CARRY THE DIVERGENT PAIR. `from_chunks` refuses it
          under the UNKNOWN-class schema shape, naming the conflict.
          `to_record_batch()` is therefore unreachable with such a table --
          which is a STRONGER statement than "it refuses".
      (2) THE GUARD `to_record_batch()` WOULD HAVE CALLED STILL FIRES. The
          same two chunks handed DIRECTLY to `concat_record_batches_nway` --
          the kernel `to_record_batch()` delegates to, see the round-trip test
          below -- raise `ArrowConcatLayoutDisagreement`. Without this arm, a
          future widening of `from_chunks` would re-open the door onto a guard
          nothing in this file had checked was still armed.

    ⚠ Piece (2) is NOT a restatement of piece (1): they are different kernels
    with different call sites, and the predicate being shared
    (`layouts_conflict`) is precisely why deleting either one would look safe.
    """
    print("test_to_record_batch_cannot_be_handed_layout_divergent_chunks...")

    # (1) The Table cannot be built -- even under the UNKNOWN-class schema.
    var chunks = List[RecordBatch]()
    chunks.append(_str_batch([String("a")]))
    chunks.append(_large_str_batch([String("b")]))
    var built = False
    var refusal = String("")
    try:
        var t = Table.from_chunks(chunks^, _one_field_schema(ArrowType.NULL))
        built = t.num_chunks() > 0
        _ = t^
    except e:
        refusal = String(e)
    assert_true(
        not built,
        String(
            "from_chunks must NOT admit a string chunk beside a large_string"
            " chunk, even under a NULL table schema -- if it does,"
            " to_record_batch() is reachable with a table whose chunks"
            " disagree about their own offset width"
        ),
    )
    assert_true(
        "PHYSICAL LAYOUT CONFLICT" in refusal,
        String("from_chunks must NAME the conflict, got: ") + refusal,
    )

    # (2) The kernel `to_record_batch()` delegates to is still armed.
    var direct = Slab[RecordBatch]()
    direct.append(_str_batch([String("a")]))
    direct.append(_large_str_batch([String("b")]))
    var kernel_raised = False
    try:
        var rb = concat_record_batches_nway(direct^)
        _ = rb^
    except e:
        kernel_raised = True
        assert_true(
            "ArrowConcatLayoutDisagreement" in String(e),
            String("expected the concat kernel's guard, got: ") + String(e),
        )
    assert_true(
        kernel_raised,
        "concat_record_batches_nway must refuse layout-divergent inputs",
    )
    print("  ok")


def test_round_trip_is_byte_identical_to_concat_record_batches_nway() raises:
    """`Table.from_chunks(...).to_record_batch()` == `concat_..._nway(...)`.

    Byte-for-byte over the offsets AND the payload, on a STRING column, over
    the same fixture built twice (both entry points CONSUME their input, so
    one fixture cannot feed both).

    This is what pins `to_record_batch` as a pure routing wrapper. The method
    is allowed to choose WHICH kernel runs; it is not allowed to have a
    behaviour of its own. If someone later adds a rebase, a re-sort or a
    schema stamp inside it, this goes red and the other tests do not.
    """
    print("test_round_trip_is_byte_identical_to_concat_record_batches_nway...")
    var via_table_chunks = List[RecordBatch]()
    via_table_chunks.append(_str_batch([String("xy"), String("z")]))
    via_table_chunks.append(_str_batch([String(""), String("wwww")]))
    via_table_chunks.append(_str_batch([String("q")]))
    var t = Table.from_chunks(via_table_chunks^, _str_schema())
    var via_table = t^.to_record_batch()

    var direct = Slab[RecordBatch]()
    direct.append(_str_batch([String("xy"), String("z")]))
    direct.append(_str_batch([String(""), String("wwww")]))
    direct.append(_str_batch([String("q")]))
    var via_kernel = concat_record_batches_nway(direct^)

    assert_equal(
        via_table.num_rows(), via_kernel.num_rows(), "row counts agree"
    )
    assert_equal(
        via_table.num_columns(), via_kernel.num_columns(), "column counts agree"
    )
    ref ct = via_table.column_at(0)
    ref ck = via_kernel.column_at(0)
    assert_equal(ct._length, ck._length, "column lengths agree")
    assert_equal(ct._null_count, ck._null_count, "null counts agree")
    _assert_int_list(_i32_offsets(ct), _i32_offsets(ck), "offsets byte-identity")
    var nbytes = _i32_offsets(ck)[ck._length]
    _assert_int_list(
        _data_bytes(ct, nbytes), _data_bytes(ck, nbytes), "payload byte-identity"
    )
    print("  ok")


# =============================================================================
# THE BRIDGE -- `RecordBatch.to_record_batch()`
# =============================================================================
#
# These four assert the bridge in `record_batch.mojo`. It is the IDENTITY: it
# returns `self`, moved. It exists so a call site spelled
# `x^.to_record_batch()` compiles whether `x` is a `RecordBatch` or a `Table`.
#
# ⭐ WHAT IS ACTUALLY WORTH ASSERTING ABOUT AN IDENTITY FUNCTION, since "it
# returns its argument" is not, on its own, a thing a test can be wrong about:
#
#   1. IT IS A MOVE, NOT A COPY -- asserted on the BUFFER ADDRESS, the same
#      instrument `test_one_chunk_is_moved_not_copied` uses one type over. A
#      `self` receiver instead of `var self` would deep-copy the whole result
#      at every call site; this is what would catch it.
#   2. THE PAYLOAD SURVIVES -- the mutant "return a fresh empty batch" type-
#      checks and would otherwise pass every compile-only check there is.
#   3. ⭐ THE TWO TYPES ACCEPT THE *SAME CALL EXPRESSION*. This is the whole
#      point of the bridge and the only property the flip depends on, and it is
#      a COMPILE-TIME fact: `test_bridge_and_table_share_one_call_expression`
#      applies one spelling to both a `RecordBatch` and a `Table` and compares
#      the results. If the signatures ever drift -- someone drops `raises`, or
#      changes the receiver convention -- that function stops compiling, which
#      is exactly when we want to hear about it and not one commit later.
#   4. IT SURVIVES THE DEGENERATE SHAPE -- a 0-row batch that still carries its
#      full schema, the `empty_from_schema` shape.


def test_bridge_is_a_move_not_a_copy() raises:
    """`RecordBatch.to_record_batch()` hands back the SAME allocation.

    If the bridge copied, every call site would pay a full deep clone of the query result for
    nothing, and NOTHING else in the tree would go red -- the values would all
    still be correct. The address is the only thing that can tell a move from
    a copy.
    """
    print("test_bridge_is_a_move_not_a_copy...")
    var batch = _i64_batch([7, 8, 9])
    var addr_before = _data_ptr_addr(batch)

    var out = batch^.to_record_batch()

    assert_equal(
        _data_ptr_addr(out),
        addr_before,
        (
            "the bridge must MOVE the batch, not copy it -- a `self` receiver"
            " instead of `var self` deep-clones the whole result at every"
            " call site"
        ),
    )
    print("  ok")


def test_bridge_preserves_the_payload() raises:
    """Schema, row count and every cell survive the bridge unchanged.

    The mutant this catches is `return RecordBatch()` -- which type-checks, and
    which a call site would then assert against, silently, having lost
    its answer.
    """
    print("test_bridge_preserves_the_payload...")
    var batch = _i64_batch([11, 22, 33, 44])

    var out = batch^.to_record_batch()

    assert_equal(out.num_rows(), 4, "row count survives the bridge")
    assert_equal(out.num_columns(), 1, "column count survives the bridge")
    assert_equal(
        out.schema.field_name(0), "v", "the schema survives the bridge"
    )
    _assert_int_list(
        _i64_values(out.column_at(0)),
        [11, 22, 33, 44],
        "cell values survive the bridge",
    )
    print("  ok")


def test_bridge_preserves_a_zero_row_schema_carrying_batch() raises:
    """The degenerate shape: 0 rows, full schema, and the schema STAYS.

    `RecordBatch.num_columns()` reads the PHYSICAL column count, so an empty
    result that loses its schema makes a downstream Project raise
    `Schema.column_index: no field named \'<k>\'`. Both
    `Table.to_record_batch` and `Table.into_single_batch` are careful about
    this shape; the bridge must not be the seam that drops it.
    """
    print("test_bridge_preserves_a_zero_row_schema_carrying_batch...")
    var batch = RecordBatch.empty_from_schema(_i64_schema())
    assert_equal(batch.num_rows(), 0, "fixture really is empty")

    var out = batch^.to_record_batch()

    assert_equal(out.num_rows(), 0, "still zero rows")
    assert_equal(
        out.num_columns(), 1, "the PHYSICAL column survives"
    )
    assert_equal(out.schema.field_name(0), "v", "the full schema survives")
    print("  ok")


def test_bridge_and_table_share_one_call_expression() raises:
    """⭐ THE PROPERTY THE BRIDGE EXISTS FOR, AND IT IS COMPILE-TIME.

    `x^.to_record_batch()` must mean something on BOTH types, with the same
    obligations at the call site, so that a call site keeps compiling whichever
    of the two types it receives. This function applies that ONE spelling to one of each and
    asserts the two answers agree.

    ⚠ ITS REAL ASSERTION IS THAT IT COMPILES. If the two signatures drift --
    `raises` dropped from one, or a receiver convention changed so the `^` is
    wrong on one of them -- this function fails to BUILD, on the commit that
    did it. The runtime
    comparison below is the cheaper half.

    The two inputs are deliberately the SAME rows: a one-chunk `Table` is what
    every unchunked driver produces today, so `Table.to_record_batch()` takes
    its `n == 1` move arm and the two paths must be indistinguishable.
    """
    print("test_bridge_and_table_share_one_call_expression...")
    var vals: List[Int] = [5, 6, 7]

    var direct = _i64_batch(vals)
    var wrapped = Table.from_batch(_i64_batch(vals))
    assert_equal(wrapped.num_chunks(), 1, "the Table arm really is one chunk")

    # ⭐ ONE SPELLING, TWO RECEIVER TYPES. This is the bridge working.
    var from_batch = direct^.to_record_batch()
    var from_table = wrapped^.to_record_batch()

    assert_equal(
        from_batch.num_rows(),
        from_table.num_rows(),
        "both call expressions yield the same row count",
    )
    assert_equal(
        from_batch.num_columns(),
        from_table.num_columns(),
        "both call expressions yield the same column count",
    )
    _assert_int_list(
        _i64_values(from_batch.column_at(0)),
        _i64_values(from_table.column_at(0)),
        "both call expressions yield the same values",
    )
    _assert_int_list(
        _i64_values(from_batch.column_at(0)),
        vals,
        "and they are the values that went in",
    )
    print("  ok")


def main() raises:
    test_zero_chunks_returns_a_schema_carrying_empty_batch()
    test_one_chunk_is_moved_not_copied()
    test_many_chunks_fixed_width_values_order_and_schema()
    test_many_chunks_string_offsets_are_rebased_at_the_seams()
    test_many_chunks_divergent_dictionaries_merge_and_remap()
    test_many_chunks_identical_dictionaries_take_the_memcpy_path()
    test_from_chunks_refuses_layout_divergence_under_a_known_schema()
    test_to_record_batch_cannot_be_handed_layout_divergent_chunks()
    test_round_trip_is_byte_identical_to_concat_record_batches_nway()
    test_bridge_is_a_move_not_a_copy()
    test_bridge_preserves_the_payload()
    test_bridge_preserves_a_zero_row_schema_carrying_batch()
    test_bridge_and_table_share_one_call_expression()
    print("All Table.to_record_batch tests passed!")
