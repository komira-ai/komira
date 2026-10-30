# Staging TPC-H: produce the eight Parquet files of a scale factor in the
# cache layout the manifest defines, with the pinned DuckDB's tpch extension
# (`CALL dbgen`) and `COPY ... TO ... (FORMAT PARQUET)`, then verify them.
#
# What is fixed, because the bytes depend on it (STAGE_VERSION names the set;
# change any of it and every recorded checksum changes with it):
#   * the DuckDB release (komira_bench_duckdb's pin, checked by `open_pinned`)
#     and the tpch extension file, checked against `tpch_extension_pins()`;
#   * one thread, and `preserve_insertion_order=true`, so the table is built and
#     written in one order;
#   * Parquet written with snappy and 122,880-row row groups (DuckDB's own
#     default row group size, so the file is the one DuckDB's users get).
#
# The functions that build SQL are pure; `generate_tpch` is generic over the
# transport, so a test drives it with a fake process that writes the files.

from std.os import makedirs, remove
from std.os.path import exists
from std.pathlib import Path

from komira_bench_duckdb import (
    DuckDbSession,
    DuckDbTransport,
    FairnessSettings,
    KIND_INT,
    KIND_TEXT,
)

from std.os import rmdir

from .manifest import DatasetManifest, recorded_line
from .stage_extension import ExtensionCheck
from .verify import FILE_UNRECORDED, VerifyReport

comptime STAGE_VERSION: String = "komira-tpch-stage-1"
comptime STAGE_THREADS: Int = 1
comptime STAGE_ROW_GROUP_ROWS: Int = 122880
comptime STAGE_COMPRESSION: String = "snappy"

comptime TPCH_ABSENT: Int = 0
comptime TPCH_PARTIAL: Int = 1
comptime TPCH_PRESENT: Int = 2



# --- SQL ---------------------------------------------------------------------------


def sql_literal(text: String) raises -> String:
    """`text` as a single-quoted SQL literal.

    Raises:
        Error: it holds a quote, a newline or a NUL byte (a path that does is
            refused, not escaped).
    """
    for c in text.as_bytes():
        if c == UInt8(39) or c == UInt8(10) or c == UInt8(13) or c == UInt8(0):
            raise Error(String("not usable inside a SQL literal: ") + text)
    return String("'") + text + String("'")


def tpch_table_names() -> List[String]:
    """The eight tables in manifest order."""
    return [
        String("region"),
        String("nation"),
        String("supplier"),
        String("customer"),
        String("part"),
        String("partsupp"),
        String("orders"),
        String("lineitem"),
    ]


def load_statement(extension_path: String) raises -> String:
    return String("LOAD ") + sql_literal(extension_path)


def dbgen_statement(scale_factor: Int) -> String:
    return String("CALL dbgen(sf=") + String(scale_factor) + String(")")


def copy_statement(table: String, out_path: String) raises -> String:
    return (
        String("COPY (SELECT * FROM ") + table + String(") TO ") + sql_literal(out_path)
        + String(" (FORMAT PARQUET, COMPRESSION ") + STAGE_COMPRESSION
        + String(", ROW_GROUP_SIZE ") + String(STAGE_ROW_GROUP_ROWS) + String(")")
    )


def count_statement(parquet_path: String) raises -> String:
    return String("SELECT count(*) AS n FROM read_parquet(") + sql_literal(parquet_path) + String(")")


def extension_status_statement() -> String:
    return (
        String("SELECT loaded::VARCHAR AS loaded, coalesce(install_path, '') AS install_path")
        + String(" FROM duckdb_extensions() WHERE extension_name = 'tpch'")
    )


def _join_path(dir: String, rel: String) -> String:
    if dir.as_bytes()[dir.byte_length() - 1] == 0x2F:
        return dir + rel
    return dir + "/" + rel


def _parent_of(path: String) -> String:
    var b = path.as_bytes()
    var i = len(b)
    while i > 0 and b[i - 1] != UInt8(0x2F):
        i -= 1
    return String(path[byte=0:i])


# --- the state of a cache directory -------------------------------------------------


def tpch_state(manifest: DatasetManifest, cache_dir: String) raises -> Int:
    """TPCH_ABSENT when none of the manifest's files exists under `cache_dir`,
    TPCH_PRESENT when all do, TPCH_PARTIAL otherwise (a file or a directory at
    the path counts as present)."""
    if cache_dir.byte_length() == 0:
        raise Error("stage: the cache directory is empty")
    var n = 0
    for i in range(len(manifest.files)):
        if exists(_join_path(cache_dir, manifest.files[i].path)):
            n += 1
    if n == 0:
        return TPCH_ABSENT
    if n == len(manifest.files):
        return TPCH_PRESENT
    return TPCH_PARTIAL


def _remove_all(manifest: DatasetManifest, cache_dir: String):
    for i in range(len(manifest.files)):
        var full = _join_path(cache_dir, manifest.files[i].path)
        try:
            if exists(full):
                remove(full)
        except:
            pass


def _remove_empty_dirs(manifest: DatasetManifest, cache_dir: String):
    """Remove the scale directory and `tpch/` above it when a failed run left
    them empty (rmdir refuses a directory that holds anything)."""
    var with_slash = _parent_of(_join_path(cache_dir, manifest.files[0].path))
    var sf_dir = String(with_slash[byte=0:with_slash.byte_length() - 1])
    var with_slash_up = _parent_of(sf_dir)
    try:
        rmdir(sf_dir)
        rmdir(String(with_slash_up[byte=0:with_slash_up.byte_length() - 1]))
    except:
        pass


# --- generation ------------------------------------------------------------------------


struct Generated(Copyable, Movable):
    """What one generation run observed on the DuckDB side."""

    var settings: FairnessSettings
    var extension_loaded: String
    var extension_path: String
    var rows: List[Int]
    """The row count of each written file, in manifest order."""

    def __init__(out self, var settings: FairnessSettings):
        self.settings = settings^
        self.extension_loaded = String("")
        self.extension_path = String("")
        self.rows = List[Int]()


def _run[T: DuckDbTransport](mut s: DuckDbSession[T], statement: String) raises:
    var t = s.run_timed(statement)
    if not t.ok():
        raise Error(String("duckdb refused `") + statement + String("`: ") + t.error)


def _count_rows[T: DuckDbTransport](mut s: DuckDbSession[T], parquet_path: String) raises -> Int:
    var got = s.fetch(count_statement(parquet_path))
    if not got.ok():
        raise Error(String("duckdb cannot count ") + parquet_path + String(": ") + got.error)
    if got.rows.row_count() != 1 or got.rows.column_count() != 1 or got.rows.rows[0][0].kind != KIND_INT:
        raise Error(String("duckdb gave no row count for ") + parquet_path)
    return Int(got.rows.rows[0][0].i)


def generate_tpch[
    T: DuckDbTransport
](
    mut s: DuckDbSession[T],
    manifest: DatasetManifest,
    scale_factor: Int,
    cache_dir: String,
    extension_path: String,
    memory_limit_bytes: Int,
    version: String,
    temp_dir: String = String(),
) raises -> Generated:
    """Generate every file of `manifest` (TPC-H at `scale_factor`) under
    `cache_dir` with the DuckDB session `s`, which must not have been started.
    No file of the manifest may exist: a partial or complete dataset is refused,
    never replaced. The session is started with one thread and insertion order
    preserved, the tpch extension is loaded from `extension_path`, and each file
    is counted back through `read_parquet` and compared with the manifest's row
    count where it has one. `extension_path` must be the private copy of the
    pinned extension (stage_extension.mojo) and DuckDB must report that same
    path as the extension's install path. A non-empty `temp_dir` is DuckDB's
    spill directory. "Never replaced" is a check before the first COPY, not an
    exclusive create: COPY overwrites, so another process of the same user that
    creates a file in between can lose it. On any failure DuckDB is stopped
    first, then the files this run wrote are removed, then the directories it
    made, if they are empty.

    Raises:
        Error: a file already exists, DuckDB refuses a statement, the tpch
            extension is not loaded or not from `extension_path`, or a row
            count differs from the manifest.
    """
    if tpch_state(manifest, cache_dir) != TPCH_ABSENT:
        raise Error("stage: files of " + manifest.name + " " + manifest.scale + " already exist under the cache directory; nothing is replaced")
    var extras = List[Tuple[String, String]]()
    extras.append((String("preserve_insertion_order"), String("true")))
    var settings = s.start(STAGE_THREADS, memory_limit_bytes, version, extras^)
    var out = Generated(settings^)
    makedirs(_parent_of(_join_path(cache_dir, manifest.files[0].path)), exist_ok=True)
    try:
        if temp_dir.byte_length() > 0:
            _run(s, String("SET temp_directory=") + sql_literal(temp_dir))
        _run(s, load_statement(extension_path))
        var st = s.fetch(extension_status_statement())
        if not st.ok() or st.rows.row_count() != 1 or st.rows.column_count() != 2:
            raise Error("duckdb cannot report the state of the tpch extension")
        if st.rows.rows[0][0].kind != KIND_TEXT or st.rows.rows[0][0].s != String("true"):
            raise Error("the tpch extension is not loaded")
        out.extension_loaded = st.rows.rows[0][0].s.copy()
        out.extension_path = st.rows.rows[0][1].s.copy()
        if out.extension_path != extension_path:
            raise Error(
                String("the tpch extension was loaded from '") + out.extension_path
                + String("', not from the checked copy '") + extension_path + String("'")
            )
        _run(s, dbgen_statement(scale_factor))
        var tables = tpch_table_names()
        for i in range(len(manifest.files)):
            ref f = manifest.files[i]
            _run(s, copy_statement(tables[i], _join_path(cache_dir, f.path)))
            var n = _count_rows(s, _join_path(cache_dir, f.path))
            if f.has_rows() and n != f.expected_rows:
                raise Error(
                    String("stage: ") + f.path + String(" has ") + String(n)
                    + String(" rows, the manifest says ") + String(f.expected_rows)
                )
            out.rows.append(n)
    except e:
        try:
            s.kill()
        except:
            pass
        _remove_all(manifest, cache_dir)
        _remove_empty_dirs(manifest, cache_dir)
        raise Error(String(e))
    return out^


# --- the report --------------------------------------------------------------------------


def describe_generation(manifest: DatasetManifest, g: Generated) -> String:
    """The lines that say how the files of this run were made."""
    var out = String("generated here: dbgen ") + manifest.scale + String(", ")
    out += String(STAGE_THREADS) + String(" thread, ") + STAGE_COMPRESSION
    out += String(", row groups of ") + String(STAGE_ROW_GROUP_ROWS) + String(" rows\n")
    out += String("duckdb ") + g.settings.version + String(" build ") + g.settings.source_id + "\n"
    out += String("tpch extension loaded=") + g.extension_loaded + String(" install_path=") + g.extension_path + "\n"
    return out^


def render_stage(
    manifest: DatasetManifest,
    report: VerifyReport,
    rows: List[Int],
    var header: String,
    extension: List[ExtensionCheck],
) -> String:
    """The text the stage tool prints: `header` (what was run), the extension
    check if there is one, the verifier's report, and the lines to record.
    `rows` holds the row count observed per file in manifest order (empty when
    none was counted). A line is printed for every file that is present with
    something still unrecorded; a file that is already VERIFIED has nothing to
    add."""
    var out = String("komira-bench-stage ") + String(STAGE_VERSION) + "\n" + header
    for i in range(len(extension)):
        out += extension[i].describe() + "\n"
    out += report.render()
    var lines = String("")
    for i in range(len(report.checks)):
        ref c = report.checks[i]
        if c.status != FILE_UNRECORDED:
            continue
        var n = manifest.files[i].expected_rows
        if len(rows) == len(manifest.files) and rows[i] >= 0:
            n = rows[i]
        lines += recorded_line(c.path, c.observed_bytes, c.observed_sha256, n) + "\n"
    if lines.byte_length() > 0:
        out += String("lines to record (komira_bench_data/manifest.mojo, recorded_files, above `return out^`):\n")
        out += lines
    return out^
