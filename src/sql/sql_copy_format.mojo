# =============================================================================
# sql/sql_copy_format.mojo
#   The format and compression a COPY ... TO takes from its destination.
# =============================================================================
#
# DuckDB's rule. With no FORMAT option, the format comes from the
# destination's extension after one compression suffix (`.gz`, `.zst`) is
# removed: `.parquet` is Parquet, `.csv` is CSV, and `.json`, `.jsonl` and
# `.ndjson` are JSON. Any other extension, or none, is refused by name
# (`COPY_FORMAT_NOT_INFERRED`) rather than written as a format the name does
# not say. The extension is compared without regard to case.
#
# With no COMPRESSION option, Parquet takes snappy, and CSV and JSON take gzip
# from a `.gz` suffix, zstd from `.zst`, and none otherwise.
#
#   copy_format_from_path("out/sales.parquet")  -> WFMT_PARQUET
#   copy_format_from_path("rows.csv.gz")        -> WFMT_CSV
#   copy_codec_from_path(WFMT_CSV, "rows.csv.gz") -> WCOMP_GZIP

from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_CSV,
    WFMT_JSONL,
    WFMT_PARQUET,
)

comptime COPY_FORMAT_NOT_INFERRED = "COPY_FORMAT_NOT_INFERRED"
"""Refusal (step `parse`): a COPY ... TO with no FORMAT whose destination's
extension names no format."""


def _lower_name(dest: String) -> String:
    """The file-name part of `dest` (after the last `/`), lower-cased."""
    var slash = dest.rfind(String("/"))
    var name = String(dest[byte = slash + 1 :]) if slash >= 0 else dest
    return name.lower()


def _compression_suffix(name: String) -> String:
    """`.gz` or `.zst` when `name` ends with one, else the empty string."""
    if name.endswith(".gz"):
        return String(".gz")
    if name.endswith(".zst"):
        return String(".zst")
    return String("")


def copy_format_from_path(dest: String) raises -> UInt8:
    """The WFMT_* format DuckDB infers from `dest`'s extension.

    Raises:
        `COPY_FORMAT_NOT_INFERRED` naming `dest` when the extension names no
        format.
    """
    var name = _lower_name(dest)
    var suffix = _compression_suffix(name)
    var stem = String(name[byte = 0 : name.byte_length() - suffix.byte_length()])
    if stem.endswith(".parquet"):
        return WFMT_PARQUET
    if stem.endswith(".csv"):
        return WFMT_CSV
    if stem.endswith(".json") or stem.endswith(".jsonl") or stem.endswith(".ndjson"):
        return WFMT_JSONL
    raise Error(
        String(COPY_FORMAT_NOT_INFERRED) + ": COPY ... TO '" + dest
        + "' has no FORMAT, and its extension is not .parquet, .csv, .json,"
        " .jsonl or .ndjson; add (FORMAT parquet), (FORMAT csv) or"
        " (FORMAT json)"
    )


def copy_codec_from_path(fmt: UInt8, dest: String) -> UInt8:
    """The WCOMP_* compression a COPY with format `fmt` and no COMPRESSION
    takes: snappy for Parquet; for CSV and JSON, gzip for a `.gz` suffix, zstd
    for `.zst`, and none otherwise."""
    if fmt == WFMT_PARQUET:
        return WCOMP_SNAPPY
    var suffix = _compression_suffix(_lower_name(dest))
    if suffix == ".gz":
        return WCOMP_GZIP
    if suffix == ".zst":
        return WCOMP_ZSTD
    return WCOMP_UNCOMPRESSED
