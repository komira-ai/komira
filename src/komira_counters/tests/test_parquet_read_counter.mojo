# komira_counters/tests/test_parquet_read_counter.mojo -- the parquet read
# counters have no reset, by design (they are process-global and monotone), so
# every assertion is a DELTA across the operation.

from std.testing import TestSuite, assert_equal

from komira_counters.parquet_read_counter import (
    parquet_column_chunk_bytes,
    parquet_column_chunks_decoded,
    parquet_columns_decoded,
    parquet_note_column_chunk_decoded,
    parquet_note_columns_decoded,
    parquet_note_source_read,
    parquet_source_reads,
)


def test_source_reads_are_monotone_deltas() raises:
    var before = parquet_source_reads()
    parquet_note_source_read()
    parquet_note_source_read()
    assert_equal(parquet_source_reads() - before, 2)


def test_columns_decoded_is_a_sum() raises:
    var before = parquet_columns_decoded()
    parquet_note_columns_decoded(3)
    parquet_note_columns_decoded(4)
    assert_equal(parquet_columns_decoded() - before, 7)


def test_chunk_count_and_bytes_move_together() raises:
    var chunks = parquet_column_chunks_decoded()
    var bytes = parquet_column_chunk_bytes()
    parquet_note_column_chunk_decoded(1000)
    parquet_note_column_chunk_decoded(24)
    assert_equal(parquet_column_chunks_decoded() - chunks, 2)
    assert_equal(parquet_column_chunk_bytes() - bytes, 1024)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
