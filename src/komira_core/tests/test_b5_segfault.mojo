# =============================================================================
# Regression test: DICTIONARY column under a STRING schema field (segfault).
# =============================================================================
#
# The hazard: if RecordBatchBuilder.build() stamps every Column's arrow_type
# from the Schema, then a DICTIONARY column returned by the Parquet reader
# (preserve_dict=True) under a Schema that says STRING (derived from
# Parquet's BYTE_ARRAY physical type) gets its type overwritten to STRING.
# Downstream gather_batch then interprets the int32 indices buffer as a
# variable-length string offsets buffer, reading 122880 entries from a
# 4-entry buffer -> SEGFAULT (seen on a TPC-H Q1 group-by over a
# dictionary-encoded parquet file).
#
# The contract: RecordBatchBuilder.build() reconciles the OTHER way — the
# Column's arrow_type is authoritative, so when the Column is DICTIONARY and
# the Schema says STRING/LARGE_STRING, the SCHEMA is corrected to DICTIONARY
# (`arrow/record_batch.mojo`, the "Reconcile Schema vs Column type for
# DICTIONARY columns" block).
#
# WHY IN-MEMORY, NOT A PARQUET FIXTURE. The defect is not in the Parquet
# reader; the reader correctly returns a DICTIONARY Column. The defect is in
# `RecordBatchBuilder.build()`'s schema-vs-column type reconciliation, and
# that is reachable with an in-memory DICTIONARY Column and a Schema that
# says STRING — exactly the state the Parquet reader produces, constructed
# directly, with no fixture at all. A self-generated parquet substitute would
# not work: the Mojo writer emits Utf8 as PLAIN BYTE_ARRAY, so its strings are
# NOT dict-encoded, the reader would hand back STRING columns, the reconcile
# branch would never be entered, and the test would go green while testing
# nothing.
#
# NON-VACUITY: with the reconcile block in `record_batch.mojo` removed, this
# file fails —
#     AssertionError: build() must correct the SCHEMA to DICTIONARY, not stamp
#     the Column to STRING (B-5: the stamp is what fed int32 indices to the
#     string-offsets reader)
# — and `RecordBatch._ensure_column_type` prints its "Repairing Column.arrow_type
# ... setting to string" warning, which is the exact corruption that segfaulted.
#
# Not covered here: the full Parquet -> filter -> group_by -> agg pipeline on
# a multi-million-row dictionary-encoded file; the benchmark corpus exercises
# that path.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatchBuilder
from komira_core.arrow.schema import Field, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion


def _dict_column(
    var values: List[String], var indices: List[Int32]
) raises -> Column[HeapRegion]:
    """A DICTIONARY Column in the exact shape the Parquet reader hands back for
    an RLE_DICTIONARY BYTE_ARRAY column: int32 indices + a small string dict."""
    var dict_arr = StringDictionaryArray.from_parts(
        PrimitiveArray[DType.int32].from_list(indices^),
        StringArray.from_strings(values^),
    )
    return Column.from_dictionary(dict_arr^)


def test_b5_build_does_not_stamp_dictionary_column_to_string() raises:
    """THE FALSIFIER. A DICTIONARY Column + a Schema that says STRING is
    precisely the state `preserve_dict=True` Parquet reads produce. `build()`
    must treat the COLUMN as authoritative and correct the SCHEMA — never the
    reverse.

    Stamping the Column's arrow_type from the Schema makes the Column claim
    STRING while its `_data` buffer holds int32 dictionary indices and its
    `_offsets` buffer holds only dict_size+1 entries. The next `gather_batch`
    then reads `num_rows + 1` offsets out of that 4-entry buffer and walks off
    the mapping -> SIGSEGV.
    """
    # l_returnflag: 3 distinct values over 8 rows — the TPC-H Q1 group-by key shape.
    var flags = List[String]()
    flags.append(String("A"))
    flags.append(String("N"))
    flags.append(String("R"))
    var flag_idx = List[Int32]()
    flag_idx.append(Int32(0))
    flag_idx.append(Int32(1))
    flag_idx.append(Int32(2))
    flag_idx.append(Int32(0))
    flag_idx.append(Int32(1))
    flag_idx.append(Int32(2))
    flag_idx.append(Int32(0))
    flag_idx.append(Int32(1))

    var builder = RecordBatchBuilder()
    builder.add_column(_dict_column(flags^, flag_idx^))

    # The Schema says STRING — this is what the Parquet footer's BYTE_ARRAY
    # physical type produces, and it DISAGREES with the Column. That
    # disagreement is the whole bug.
    var sb = SchemaBuilder()
    sb.add_field(Field("l_returnflag", ArrowType.STRING, False))

    var batch = builder.build(sb.build())

    # ── ASSERTION 1: the SCHEMA moved to the Column, not the other way. ──
    assert_equal(
        batch.schema.field_arrow_type(0),
        ArrowType.DICTIONARY,
        (
            "build() must correct the SCHEMA to DICTIONARY, not stamp the"
            " Column to STRING (B-5: the stamp is what fed int32 indices to"
            " the string-offsets reader)"
        ),
    )

    # ── ASSERTION 2: the column still reads as a dictionary, with the right
    #    values. This is what breaks if the types were reconciled the wrong
    #    way: `_ensure_column_type` would first PRINT its repair warning and
    #    overwrite the Column's arrow_type to STRING, and `as_dictionary()`
    #    would then be reading a STRING-typed column. ──
    var got = batch.column_as_dictionary(0)
    assert_equal(len(got), 8, "8 rows survive the build")
    assert_equal(got.get(0), String("A"), "row 0 resolves through the dict")
    assert_equal(got.get(1), String("N"), "row 1 resolves through the dict")
    assert_equal(got.get(2), String("R"), "row 2 resolves through the dict")
    assert_equal(got.get(7), String("N"), "row 7 resolves through the dict")

    # ── ASSERTION 3: the dictionary buffer really is dict-shaped — 3 entries
    #    for 8 rows. If the offsets buffer were being read as string offsets
    #    (the segfault path), this invariant is what makes the read
    #    out-of-bounds: 9 offsets demanded from a 4-entry buffer. ──
    assert_equal(
        len(got.dictionary),
        3,
        "the dictionary holds 3 uniques for 8 rows (dict_size+1 = 4 offsets)",
    )
    assert_true(
        len(got.dictionary) < len(got),
        "dict_size < num_rows — the condition that made the overread fatal",
    )


def test_b5_non_dictionary_columns_are_untouched() raises:
    """The reconcile must be NARROW: it fires only for a DICTIONARY Column
    under a STRING/LARGE_STRING Schema field. A plain STRING column under a
    STRING field must come through with its Schema type unchanged — otherwise
    the fix would be rewriting schemas it has no business touching."""
    var vals = List[String]()
    vals.append(String("alpha"))
    vals.append(String("beta"))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_string(StringArray.from_strings(vals^)))

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var batch = builder.build(sb.build())

    assert_equal(
        batch.schema.field_arrow_type(0),
        ArrowType.STRING,
        "a STRING column under a STRING field keeps its STRING schema type",
    )
    var got = batch.column_as_string(0)
    assert_equal(got.get(0), String("alpha"), "value 0 round-trips")
    assert_equal(got.get(1), String("beta"), "value 1 round-trips")


def main() raises:
    test_b5_build_does_not_stamp_dictionary_column_to_string()
    test_b5_non_dictionary_columns_are_untouched()
    print("test_b5_segfault: OK")
