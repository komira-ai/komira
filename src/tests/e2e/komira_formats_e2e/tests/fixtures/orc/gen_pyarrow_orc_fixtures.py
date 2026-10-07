#!/usr/bin/env python3
"""
gen_pyarrow_orc_fixtures.py: ORC files written by pyarrow (its bundled ORC
C++ writer), not by komira_orc. Provenance of the six .orc files beside it;
tests/test_formats_foreign_orc.mojo reads them and checks every value against
the rules spelled below.

Which writer: each file's Footer records writer = 1 (ORC_CPP) and
softwareVersion "2.3.0" (the ORC C++ release pyarrow bundles); readable as
plain bytes at the end of the footer of the NONE, LZ4 and SNAPPY files. The
environment that wrote them pinned pyarrow 24.0.0. The data below is fully
deterministic (no random seeds); whether another pyarrow or ORC C++ release
reproduces the bytes exactly has not been checked, so regenerate only with
the same versions, and update the test if the layout changes.

USAGE (from this directory, with pyarrow installed):
    python3 gen_pyarrow_orc_fixtures.py

OUTPUTS
-------
    pyarrow_nullable_mixed.orc  (compression NONE, pyarrow's default)
        1200 rows, 4 columns, each nullable column null on its own cadence,
        so a reader that drops NULL rows or shifts values is caught:
          id    : INT64, non-null, value == row index (anchor).
          label : STRING (DIRECT_V2 in the committed files), NULL when
                  row%3==0, else ["x","y","z","w"][row%4].
          nint  : INT64, NULL when row%5==0, else row*10.
          nflt  : FLOAT64, NULL when row%7==0, else row+0.5.

    pyarrow_nullable_codec_<codec>.orc  (codec in zlib/snappy/zstd/lz4)
        The same table written with each ORC compression codec.

    pyarrow_multistripe_nullable.orc  (compression NONE)
        3000 rows; a small stripe_size makes ORC C++ cut several stripes,
        each with its own PRESENT streams:
          id    : INT64 non-null anchor, value == row index.
          label : STRING, NULL when row%4==0, else ["x","y","z","w"][row%4].
          flag  : BOOL, NULL when row%6==0, else (row%2==0).
"""
import os

import pyarrow as pa
import pyarrow.orc as orc


FIXTURE_DIR = os.path.dirname(os.path.abspath(__file__))

_CAT = ["x", "y", "z", "w"]


def _nullable_mixed_table(n: int = 1200) -> pa.Table:
    ids = pa.array(list(range(n)), type=pa.int64())
    labels = pa.array(
        [None if i % 3 == 0 else _CAT[i % 4] for i in range(n)],
        type=pa.string(),
    )
    nints = pa.array(
        [None if i % 5 == 0 else i * 10 for i in range(n)], type=pa.int64()
    )
    nflts = pa.array(
        [None if i % 7 == 0 else float(i) + 0.5 for i in range(n)],
        type=pa.float64(),
    )
    return pa.table({"id": ids, "label": labels, "nint": nints, "nflt": nflts})


def _report(path: str) -> None:
    t = orc.read_table(path)
    cols = ", ".join(
        f"{name}:nulls={t.column(name).null_count}"
        for name in t.column_names
    )
    print(
        f"wrote {os.path.basename(path)}: rows={t.num_rows} "
        f"cols={t.num_columns} [{cols}] size={os.path.getsize(path):,}B"
    )


def _write_nullable_mixed() -> None:
    p = os.path.join(FIXTURE_DIR, "pyarrow_nullable_mixed.orc")
    orc.write_table(_nullable_mixed_table(), p)
    _report(p)


def _write_nullable_codec_matrix() -> None:
    tbl = _nullable_mixed_table()
    for codec in ("zlib", "snappy", "zstd", "lz4"):
        p = os.path.join(FIXTURE_DIR, f"pyarrow_nullable_codec_{codec}.orc")
        orc.write_table(tbl, p, compression=codec)
        _report(p)


def _write_multistripe_nullable(n: int = 3000) -> None:
    p = os.path.join(FIXTURE_DIR, "pyarrow_multistripe_nullable.orc")
    ids = pa.array(list(range(n)), type=pa.int64())
    labels = pa.array(
        [None if i % 4 == 0 else _CAT[i % 4] for i in range(n)],
        type=pa.string(),
    )
    flags = pa.array(
        [None if i % 6 == 0 else (i % 2 == 0) for i in range(n)],
        type=pa.bool_(),
    )
    tbl = pa.table({"id": ids, "label": labels, "flag": flags})
    # Force several stripes: a small stripe_size makes ORC C++ cut the
    # 3000 rows into multiple stripes, each with its own PRESENT stream.
    orc.write_table(tbl, p, stripe_size=64 * 1024)
    _report(p)
    f = orc.ORCFile(p)
    print(f"  pyarrow_multistripe_nullable.orc nstripes={f.nstripes}")


def main() -> None:
    _write_nullable_mixed()
    _write_nullable_codec_matrix()
    _write_multistripe_nullable()


if __name__ == "__main__":
    main()
