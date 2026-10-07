#!/usr/bin/env python3
"""
gen_pyarrow_fixtures.py: Parquet files written by pyarrow (its bundled
parquet-cpp writer), not by komira. Provenance of the .parquet files beside
it; tests/test_parquet_file_pages_e2e.mojo walks every page of each one.

Which writer: each file's FileMetaData.created_by (Thrift field 6, readable as
plain bytes near the end of the file) names it:
    "parquet-cpp-arrow version 24.0.0"  every file but the one below
    "parquet-cpp-arrow version 25.0.0"  pyarrow_page_crc_zstd_v2.parquet
The data below is deterministic (no random seeds); whether another pyarrow
release reproduces the bytes exactly has not been checked, so regenerate only
with the pyarrow version the file's created_by names, and update the test and
SHA256SUMS if the layout changes.

USAGE (with pyarrow installed):
    python3 gen_pyarrow_fixtures.py --out-dir DIR [--fixture NAME ...]
        [--lineitem-source PATH]
With no --fixture, every fixture is written. The two lineitem files need
--lineitem-source.

OUTPUTS
-------
    pyarrow_gzip_plain.parquet          (GZIP, PLAIN, 774 bytes)
        5 rows, id INT64 1..5 and value DOUBLE 10.5..50.5; use_dictionary
        off, so each column chunk is one PLAIN data page and no dictionary.

    pyarrow_int96_ts.parquet            (UNCOMPRESSED, 401 bytes)
        3 rows of the deprecated INT96 timestamp physical type (0 ns, one
        day, one second since the epoch, UTC).

    pyarrow_multi_dict_page.parquet     (SNAPPY, 18493 bytes)
        3000 rows in 6 row groups of 500: id INT64 0..2999 and label STRING
        cycling alpha/bravo/charlie/delta/echo, dictionary-encoded, so every
        row group's column chunk opens with its own dictionary page.

    pyarrow_zero_row.parquet            (SNAPPY, 421 bytes)
        Schema only (i64 INT64, s STRING), zero rows: one row group whose
        column chunks hold no page.

    lineitem_pyarrow_500.parquet        (SNAPPY, 53260 bytes)
    lineitem_pyarrow_500_uncompressed.parquet (UNCOMPRESSED, 62144 bytes)
        The first 500 rows of a TPC-H scale-factor-1 lineitem table with
        derived columns (21 columns: INT64, DOUBLE, BYTE_ARRAY), read
        and rewritten by pyarrow. The compressed file has row groups of
        200/200/100 rows, the uncompressed one a single row group of 500, so
        their pages do not line up one to one. The source table is not
        committed; the two files are kept as written.

    pyarrow_page_crc_zstd_v2.parquet    (ZSTD, DATA_PAGE_V2, page CRCs, 3400 bytes)
        1200 rows in 2 row groups of 600: id INT64 == row (PLAIN, no
        dictionary) and label STRING, NULL when row % 7 == 0, else
        "k" + str(row % 13) (dictionary-encoded). write_page_checksum=True,
        so every page header carries the CRC-32 of its page bytes; a small
        data_page_size, checked after each write batch of 100 rows, cuts
        several data pages per chunk.
"""
import argparse
import os

import pyarrow as pa
import pyarrow.parquet as pq


def _report(path: str) -> None:
    m = pq.read_metadata(path)
    print(
        f"wrote {os.path.basename(path)}: rows={m.num_rows} "
        f"rg={m.num_row_groups} cols={m.num_columns} writer={m.created_by} "
        f"size={os.path.getsize(path):,}B"
    )


def _write_lineitem_slice(
    out_dir: str, source: str, out_basename: str, compression: str, row_group_size: int
) -> None:
    out_path = os.path.join(out_dir, out_basename)
    sliced = pq.read_table(source).slice(0, 500)
    pq.write_table(
        sliced, out_path, compression=compression, row_group_size=row_group_size
    )
    _report(out_path)


def _write_multi_dict_page(out_dir: str) -> None:
    out_path = os.path.join(out_dir, "pyarrow_multi_dict_page.parquet")
    n = 3000
    cat = ["alpha", "bravo", "charlie", "delta", "echo"]
    tbl = pa.table(
        {
            "id": pa.array(list(range(n)), type=pa.int64()),
            "label": pa.array([cat[i % len(cat)] for i in range(n)], type=pa.string()),
        }
    )
    pq.write_table(
        tbl,
        out_path,
        compression="snappy",
        row_group_size=500,
        data_page_size=1024,
        use_dictionary=True,
        write_statistics=True,
    )
    _report(out_path)


def _write_zero_row(out_dir: str) -> None:
    out_path = os.path.join(out_dir, "pyarrow_zero_row.parquet")
    tbl = pa.table(
        {
            "i64": pa.array([], type=pa.int64()),
            "s": pa.array([], type=pa.string()),
        }
    )
    pq.write_table(tbl, out_path, compression="snappy", use_dictionary=False)
    _report(out_path)


def _write_gzip_plain(out_dir: str) -> None:
    out_path = os.path.join(out_dir, "pyarrow_gzip_plain.parquet")
    tbl = pa.table(
        {
            "id": pa.array([1, 2, 3, 4, 5], type=pa.int64()),
            "value": pa.array([10.5, 20.5, 30.5, 40.5, 50.5], type=pa.float64()),
        }
    )
    pq.write_table(tbl, out_path, compression="gzip", use_dictionary=False)
    _report(out_path)


def _write_int96_ts(out_dir: str) -> None:
    out_path = os.path.join(out_dir, "pyarrow_int96_ts.parquet")
    tbl = pa.table(
        {
            "ts": pa.array([0, 86400000000000, 1000000000], type=pa.int64()).cast(
                pa.timestamp("ns", tz="UTC")
            )
        }
    )
    pq.write_table(
        tbl,
        out_path,
        use_deprecated_int96_timestamps=True,
        use_dictionary=False,
        compression="none",
    )
    _report(out_path)


def _write_page_crc_zstd_v2(out_dir: str) -> None:
    out_path = os.path.join(out_dir, "pyarrow_page_crc_zstd_v2.parquet")
    n = 1200
    tbl = pa.table(
        {
            "id": pa.array(list(range(n)), type=pa.int64()),
            "label": pa.array(
                [None if i % 7 == 0 else "k" + str(i % 13) for i in range(n)],
                type=pa.string(),
            ),
        }
    )
    pq.write_table(
        tbl,
        out_path,
        compression="zstd",
        row_group_size=600,
        data_page_size=1024,
        write_batch_size=100,
        data_page_version="2.0",
        use_dictionary=["label"],
        write_page_checksum=True,
    )
    _report(out_path)


_SIMPLE = {
    "gzip_plain": _write_gzip_plain,
    "int96_ts": _write_int96_ts,
    "multi_dict_page": _write_multi_dict_page,
    "zero_row": _write_zero_row,
    "page_crc_zstd_v2": _write_page_crc_zstd_v2,
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument(
        "--fixture", action="append", choices=sorted(list(_SIMPLE) + ["lineitem"])
    )
    ap.add_argument("--lineitem-source")
    args = ap.parse_args()
    wanted = args.fixture or sorted(list(_SIMPLE) + ["lineitem"])
    for name in wanted:
        if name == "lineitem":
            if not args.lineitem_source:
                ap.error("--fixture lineitem needs --lineitem-source")
            _write_lineitem_slice(
                args.out_dir, args.lineitem_source,
                "lineitem_pyarrow_500.parquet", "snappy", 200,
            )
            _write_lineitem_slice(
                args.out_dir, args.lineitem_source,
                "lineitem_pyarrow_500_uncompressed.parquet", "none", 500,
            )
        else:
            _SIMPLE[name](args.out_dir)


if __name__ == "__main__":
    main()
