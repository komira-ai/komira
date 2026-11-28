# =============================================================================
# sql/sql_tvf_options.mojo
#   The table-function reader kinds, the `TvfOptions` a `read_*` call carries,
#   and the path classifiers of the `FROM '<path>'` replacement scan.
# =============================================================================
#
# Split out of `sql_ast.mojo` and `sql_parser.mojo`; both import these names
# back, so `from sql.sql_ast import TvfOptions, TVF_PARQUET` keeps working.
# This module imports nothing from the SQL front end, so there is no cycle.
# =============================================================================

comptime TVF_NONE: UInt8 = 0
comptime TVF_PARQUET: UInt8 = 1
comptime TVF_CSV: UInt8 = 2
comptime TVF_JSON: UInt8 = 3
# `read_avro` (2026-09-14). AVRO IS THE THIRD SCHEMA-CARRYING SHAPE and it sits
# on the PARQUET side of the split the `sql_ast` module note draws, not the CSV/JSON
# side: an OCF carries its writer schema as JSON in the CONTAINER HEADER, so the
# bind reads the file rather than inferring over a prefix, and `TvfOptions` is
# left at its defaults for this kind — there is no dialect to steer. It is
# nonetheless routed through `sql_tvf_bind` and not through the parquet arm,
# because the leaf it builds is `SOURCE_KIND_ROW` (`komira.avro` DECLARES
# `orientation = ROW`), i.e. the same footerless-TVF lowering CSV and JSONL get.
#
# ⛔ THE TYPE ENVELOPE IS NARROWER THAN THE FORMAT, AND THAT IS NOT A PARSER
# BUG. An Avro TIMESTAMP_*/DATE64/narrow-int column is unreadable through the
# SDK leaf today, and today's bench fixtures never present one. READ OFF THE
# FIXTURE'S OWN OCF HEADER, 2026-09-14 -- all 21 fields of
# `bench/data/omni/avro/lineitem_*.avro` are `["null", long|double|string]`:
# no logical type, no `int`, no decimal, and the three date columns
# (`l_shipdate`/`l_commitdate`/`l_receiptdate`) are plain `long`.
#   ⚠ THE USUAL TELLING OF THIS IS WRONG IN A WAY THAT MATTERS.
# `bench/data/gen_omni_lineitem.sh:543-547` does carry a
# date/timestamp/decimal -> Avro `string` coercion, but it is NOT what produced
# these files: a coerced date would be `string`, and these are `long`, i.e. the
# source columns were ALREADY integral. So the coercion is a standing hazard for
# a FUTURE fixture, not the reason this one is readable. Either way the envelope
# is UNTESTED by the corpus: a `read_avro` over a file that really does carry a
# logical type raises at bind or decodes wrong, and nothing here would catch it.
comptime TVF_AVRO: UInt8 = 4
# `iceberg_scan` (DuckDB's iceberg extension spelling). The kind sits OUTSIDE
# the parquet-footer split too: `is_parquet_tvf_kind` is False for it, because
# no footer names its files. A table's metadata does, and the caller's
# `SqlParquetFooters.iceberg_relation` reads it before binding.
comptime TVF_ICEBERG: UInt8 = 5
# `read_orc`. An ORC file carries its schema in its FOOTER, so the bind reads the
# footer (no stripe is opened, no row decoded) and `TvfOptions` is left at its
# defaults: there is no dialect to steer. Like Avro it is outside the parquet
# footer split (`is_parquet_tvf_kind` is False), routed through `sql_tvf_bind`,
# and lowers to the ORC source (`SOURCE_ORC`) over one local file.
comptime TVF_ORC: UInt8 = 6

# `read_parquet(..., hive_partitioning = ...)`: AUTO (no option written) reads
# Hive `key=value` directories when every file of the relation has the same
# keys; ON is the same but refuses a file whose keys differ; OFF reads none.
comptime HIVE_PARTITIONING_AUTO: UInt8 = 0
comptime HIVE_PARTITIONING_ON: UInt8 = 1
comptime HIVE_PARTITIONING_OFF: UInt8 = 2


struct TvfOptions(Copyable, Movable):
    """The SEMANTICS-BEARING options of a `read_csv` / `read_json` TVF call.

    Only options that change WHAT THE RESULT IS live here. An option that
    changes only HOW the result is computed (`parallel`, `auto_detect=true`)
    is accepted by the parser and carries no field — it cannot alter a value,
    so honoring it is not a correctness matter. Every OTHER option raises at
    parse time (see the module note of `sql_ast`).

    Fields:
        all_varchar:  DuckDB `all_varchar=true` — every column is VARCHAR, type
                      inference is skipped entirely. Honored by the binder,
                      which stamps an all-STRING schema on the scan leaf; the
                      row reader parses each cell per the leaf's DECLARED dtype,
                      so no reader change is needed for this to be real.
        has_header:   DuckDB `header=` (CSV). Default True — which is also
                      `CsvReadOptions`' default, and what every corpus fixture
                      is written with.
        delimiter:    DuckDB `delim=`/`sep=` (CSV), one byte. Default ','.
        hive_partitioning: DuckDB `hive_partitioning=` (`read_parquet`), one of
                      `HIVE_PARTITIONING_AUTO` (the default, no option
                      written), `_ON` or `_OFF`. Honored by the footer reader
                      that resolves the relation's files.
        allow_moved_paths: DuckDB `allow_moved_paths=` (`iceberg_scan`).
                      Default False. Honored by the reader that resolves the
                      table (`SqlParquetFooters.iceberg_relation`).
        snapshot_from_id: DuckDB `snapshot_from_id=` (`iceberg_scan`), the
                      snapshot to read instead of the current one. Default
                      None. Honored by the same reader.
    """

    var all_varchar: Bool
    var has_header: Bool
    var delimiter: UInt8
    var hive_partitioning: UInt8
    var allow_moved_paths: Bool
    var snapshot_from_id: Optional[Int64]

    def __init__(out self):
        self.all_varchar = False
        self.has_header = True
        self.delimiter = UInt8(ord(","))
        self.hive_partitioning = HIVE_PARTITIONING_AUTO
        self.allow_moved_paths = False
        self.snapshot_from_id = None


def _replacement_scan_kind(path: String) raises -> UInt8:
    """The TVF kind a `FROM '<path>'` replacement scan reads, by extension —
    or a refusal naming the extension. See `_Parser._parse_replacement_scan`."""
    var low = path.lower()
    if low.endswith(".parquet"):
        return TVF_PARQUET
    if low.endswith(".csv"):
        return TVF_CSV
    if low.endswith(".json") or low.endswith(".jsonl") or low.endswith(".ndjson"):
        return TVF_JSON
    raise Error(
        "SQL not supported: a replacement scan of `'" + path + "'` — this door"
        " maps a FROM-clause file path by its extension (.parquet, .csv, .json,"
        " .jsonl, .ndjson) and this one is none of them. Spell the reader"
        " explicitly (`read_parquet(...)` / `read_csv(...)` / `read_json(...)`)."
        " (DuckDB also sniffs `.tsv` and compressed suffixes; reading those as a"
        " plain comma-separated file would answer a different table.)"
    )


def _file_stem(path: String) -> String:
    """`dir/t1.parquet` -> `t1`: the name DuckDB gives a replacement-scan
    relation (MEASURED v1.5.3, `SELECT t1.k FROM 'rs/t1.parquet'`). Byte
    scan: `/` and `.` are ASCII, so a byte index is a character boundary."""
    var b = path.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("/")):
            start = i + 1
    var stop = len(b)
    for i in range(start + 1, len(b)):
        if b[i] == UInt8(ord(".")):
            stop = i
    return String(unsafe_from_utf8=b[start:stop]).lower()


def hive_partitioning_value(on: Bool) -> UInt8:
    """The `TvfOptions.hive_partitioning` a `hive_partitioning = <bool>` option
    states: `true` is `HIVE_PARTITIONING_ON`, `false` is `HIVE_PARTITIONING_OFF`
    (no option written stays `HIVE_PARTITIONING_AUTO`)."""
    if on:
        return HIVE_PARTITIONING_ON
    return HIVE_PARTITIONING_OFF
