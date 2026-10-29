# TPC-H staging over a fake DuckDB. The fake lives in this file: it speaks the
# CLI conversation `DuckDbSession` has with a process (marker lines, JSON mode,
# error text on stderr) and does what the statements of the stage ask of the
# files: a `COPY (SELECT * FROM t) TO 'path'` writes a small file at the path
# (and fails like DuckDB does when the directory is not there), and a count of
# `read_parquet('path')` answers the TPC-H cardinalities. No DuckDB, no data.
# What the tests cannot say is whether the real tpch extension and the real
# Parquet writer behave as these statements assume: a first run on a benchmark
# host is that check, and its output is what gets recorded.
#
# What each test proves:
# - test_the_statements_are_exactly_the_documented_ones: the text of the
#   LOAD, dbgen, COPY and count statements (compression, row group size), and
#   that a path with a quote or a newline is refused, not escaped.
# - test_generation_writes_the_manifest_layout: eight files at the manifest's
#   eight paths in manifest order, one thread and insertion order set before
#   anything is generated, the extension loaded from the given path, row
#   counts observed, the verifier finding eight UNRECORDED files whose sizes
#   and sha256 are those of the bytes written.
# - test_the_report_prints_the_lines_to_record: one line per file with the
#   observed size, sha256 and row count in the form `recorded_files` takes,
#   and the extension's pin line when the extension is not pinned yet.
# - test_a_verified_file_gets_no_line: a file whose size and sha256 are
#   recorded and match prints no line.
# - test_a_partial_dataset_is_refused_and_left_alone: with one file present
#   generation raises before any statement is sent and the file is as it was.
# - test_a_failed_copy_removes_what_the_run_wrote: a COPY that fails leaves no
#   file of the dataset behind, including those written before it.
# - test_a_wrong_row_count_is_refused: a file with other rows than the
#   manifest says raises naming the file, and nothing is left behind.
# - test_an_extension_that_did_not_load_is_refused.
# - test_the_extension_file_check: pinned, unrecorded, mismatched and gzipped
#   files, and the pin line.
from std.memory import ArcPointer
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_bench_duckdb import BenchClock, DuckDbSession, DuckDbTransport, StdoutChunk
from komira_crypto import hex_lower_array_32, sha256
from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    DatasetFile,
    DatasetManifest,
    EXT_GZIPPED,
    EXT_MISMATCH,
    EXT_PINNED,
    EXT_UNRECORDED,
    ExtensionCheck,
    ExtensionPin,
    FILE_UNRECORDED,
    FILE_VERIFIED,
    STAGE_VERSION,
    TPCH_ABSENT,
    TPCH_PARTIAL,
    check_extension_bytes,
    copy_statement,
    count_statement,
    dbgen_statement,
    describe_generation,
    extension_pin_line,
    generate_tpch,
    load_statement,
    render_stage,
    tpch_state,
    tpch_table_names,
    tpch_manifest,
    verify_dataset,
)

comptime _GIB: Int = 1024 * 1024 * 1024
comptime _VERSION: String = "1.5.6"


def _rows_of(table: String) -> Int:
    if table == "region":
        return 5
    if table == "nation":
        return 25
    if table == "supplier":
        return 10000
    if table == "customer":
        return 150000
    if table == "part":
        return 200000
    if table == "partsupp":
        return 800000
    if table == "orders":
        return 1500000
    return 6001215


def _bytes_of(table: String) -> String:
    return String("PAR1 fake ") + table + String(" PAR1")


struct StageFake(DuckDbTransport):
    var sent: ArcPointer[List[String]]
    var queue: List[String]
    var at: Int
    var mode: String
    var statement: String
    var errors: String
    var fail_table: String
    var wrong_rows_table: String
    var extension_loaded: String

    def __init__(
        out self,
        sent: ArcPointer[List[String]],
        fail_table: String = String(""),
        wrong_rows_table: String = String(""),
        extension_loaded: String = String("true"),
    ):
        self.sent = sent
        self.queue = List[String]()
        self.at = 0
        self.mode = String("")
        self.statement = String("")
        self.errors = String("")
        self.fail_table = fail_table
        self.wrong_rows_table = wrong_rows_table
        self.extension_loaded = extension_loaded

    def _answer(mut self, json: String):
        if self.mode == "json":
            self.queue.append(json + String("\n"))

    def _run_statement(mut self) raises:
        var s = self.statement
        self.statement = String("")
        if s.find(String("current_setting('threads')")) >= 0:
            self._answer(
                String('[{"threads":1,"memory_limit":"4.0 GiB","version":"v1.5.6",')
                + String('"source_id":"069cc9f9b5","extra_0":"true"}]')
            )
        elif s.find(String("FROM duckdb_extensions()")) >= 0:
            self._answer(
                String('[{"loaded":"') + self.extension_loaded
                + String('","install_path":"/ext/tpch.duckdb_extension"}]')
            )
        elif s.find(String("read_parquet(")) >= 0:
            var names = tpch_table_names()
            for i in range(len(names)):
                if s.find(String("/") + names[i] + String(".parquet'")) >= 0:
                    var n = _rows_of(names[i])
                    if names[i] == self.wrong_rows_table:
                        n += 1
                    self._answer(String('[{"n":') + String(n) + String("}]"))
        elif s.startswith(String("COPY (SELECT * FROM ")):
            var from_at = String("COPY (SELECT * FROM ").byte_length()
            var close = s.find(String(")"), from_at)
            var table = String(s[byte=from_at:close])
            if table == self.fail_table:
                self.errors += String("Error: cannot write ") + table + String("\n")
                return
            var to_at = s.find(String(" TO '")) + 5
            var path = String(s[byte=to_at:s.find(String("' ("), to_at)])
            var dir_end = path.rfind(String("/"))
            if not exists(String(path[byte=0:dir_end])):
                self.errors += String("IO Error: Cannot open file \"") + path + String("\"\n")
                return
            Path(path).write_bytes(_bytes_of(table).as_bytes())

    def send(mut self, text: String) raises:
        self.sent[].append(text)
        var lines = text.split("\n")
        for k in range(len(lines)):
            var line = String(lines[k])
            if line.byte_length() == 0:
                continue
            if line.startswith(String(".mode ")):
                self.mode = String(line[byte=6:line.byte_length()])
            elif line.startswith(String(".print ")):
                self.queue.append(String(line[byte=7:line.byte_length()]) + String("\n"))
            else:
                self.statement += line + String("\n")
                if line.endswith(String(";")):
                    self._run_statement()

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self.at >= len(self.queue):
            return StdoutChunk(String(""), True)
        var t = self.queue[self.at]
        self.at += 1
        return StdoutChunk(t^, False)

    def take_stderr(mut self) raises -> String:
        var e = self.errors
        self.errors = String("")
        return e^

    def kill(mut self) raises:
        pass

    def finish(mut self) raises -> Int:
        return 0


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/stage_" + name
    makedirs(d, exist_ok=True)
    return d^


def _session(sent: ArcPointer[List[String]], var fake: StageFake) -> DuckDbSession[StageFake]:
    return DuckDbSession[StageFake](fake^, BenchClock.manual(ArcPointer[Int](0)))


def _sent_text(sent: ArcPointer[List[String]]) -> String:
    var out = String("")
    for i in range(len(sent[])):
        out += sent[][i]
    return out^


def _hex(text: String) -> String:
    return hex_lower_array_32(sha256(text.as_bytes()))


def test_the_statements_are_exactly_the_documented_ones() raises:
    assert_equal(load_statement(String("/ext/tpch.duckdb_extension")), String("LOAD '/ext/tpch.duckdb_extension'"))
    assert_equal(dbgen_statement(10), String("CALL dbgen(sf=10)"))
    assert_equal(
        copy_statement(String("lineitem"), String("/c/tpch/sf1/lineitem.parquet")),
        String(
            "COPY (SELECT * FROM lineitem) TO '/c/tpch/sf1/lineitem.parquet'"
            " (FORMAT PARQUET, COMPRESSION snappy, ROW_GROUP_SIZE 122880)"
        ),
    )
    assert_equal(
        count_statement(String("/c/a.parquet")),
        String("SELECT count(*) AS n FROM read_parquet('/c/a.parquet')"),
    )
    with assert_raises(contains="not usable inside a SQL literal"):
        _ = copy_statement(String("region"), String("/c/it's/region.parquet"))
    with assert_raises(contains="not usable inside a SQL literal"):
        _ = load_statement(String("/ext/a\nb"))
    assert_equal(len(tpch_table_names()), 8)


def test_generation_writes_the_manifest_layout() raises:
    var d = _dir(String("layout"))
    var manifest = tpch_manifest(1)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent))
    var g = generate_tpch(
        s, manifest, 1, d, String("/ext/tpch.duckdb_extension"), 4 * _GIB, String(_VERSION)
    )
    assert_equal(len(g.rows), 8)
    var names = tpch_table_names()
    for i in range(8):
        assert_equal(g.rows[i], _rows_of(names[i]))
        assert_true(exists(d + "/tpch/sf1/" + names[i] + ".parquet"))
        assert_equal(Path(d + "/tpch/sf1/" + names[i] + ".parquet").read_text(), _bytes_of(names[i]))
    assert_equal(g.extension_loaded, String("true"))
    assert_equal(g.extension_path, String("/ext/tpch.duckdb_extension"))
    assert_equal(g.settings.threads_readback, String("1"))
    var text = _sent_text(sent)
    var at_threads = text.find(String("SET threads=1"))
    var at_order = text.find(String("SET preserve_insertion_order='true'"))
    var at_load = text.find(String("LOAD '/ext/tpch.duckdb_extension'"))
    var at_gen = text.find(String("CALL dbgen(sf=1)"))
    assert_true(at_threads >= 0 and at_order >= 0)
    assert_true(at_load > at_threads and at_load > at_order)
    assert_true(at_gen > at_load)
    var last = at_gen
    for i in range(8):
        var at = text.find(String("COPY (SELECT * FROM ") + names[i] + String(")"))
        assert_true(at > last, names[i] + " is copied out of manifest order")
        last = at
    var report = verify_dataset(manifest, d)
    assert_equal(report.count(FILE_UNRECORDED), 8)
    assert_true(report.is_usable())
    for i in range(8):
        assert_equal(report.checks[i].path, manifest.files[i].path)
        assert_equal(report.checks[i].observed_bytes, _bytes_of(names[i]).byte_length())
        assert_equal(report.checks[i].observed_sha256, _hex(_bytes_of(names[i])))
    assert_equal(tpch_state(manifest, d), 2)


def test_the_report_prints_the_lines_to_record() raises:
    var d = _dir(String("report"))
    var manifest = tpch_manifest(1)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent))
    var g = generate_tpch(
        s, manifest, 1, d, String("/ext/tpch.duckdb_extension"), 4 * _GIB, String(_VERSION)
    )
    var report = verify_dataset(manifest, d)
    var ext = List[ExtensionCheck]()
    ext.append(check_extension_bytes(String("ext bytes").as_bytes(), List[ExtensionPin](), String(_VERSION), String("linux_amd64")))
    var text = render_stage(manifest, report, g.rows, describe_generation(manifest, g), ext)
    assert_true(text.startswith(String("komira-bench-stage ") + String(STAGE_VERSION) + String("\n")))
    assert_true(text.find(String("generated here: dbgen sf1, 1 thread, snappy, row groups of 122880 rows\n")) >= 0)
    assert_true(text.find(String("duckdb v1.5.6 build 069cc9f9b5\n")) >= 0)
    assert_true(text.find(String("tpch extension loaded=true install_path=/ext/tpch.duckdb_extension\n")) >= 0)
    var names = tpch_table_names()
    for i in range(8):
        var line = (
            String('    out.append(RecordedFile("tpch/sf1/') + names[i] + String('.parquet", ')
            + String(_bytes_of(names[i]).byte_length()) + String(', "') + _hex(_bytes_of(names[i]))
            + String('", ') + String(_rows_of(names[i])) + String("))\n")
        )
        assert_true(text.find(line) >= 0, "no record line for " + names[i])
    assert_true(
        text.find(
            String('    out.append(ExtensionPin("1.5.6", "linux_amd64", "')
            + _hex(String("ext bytes")) + String('", 9))\n')
        ) >= 0
    )
    assert_true(text.find(String("8 files: 0 verified, 8 unrecorded, 0 failed")) >= 0)


def test_a_verified_file_gets_no_line() raises:
    var d = _dir(String("verified"))
    makedirs(d + "/tpch/sf1", exist_ok=True)
    Path(d + "/tpch/sf1/region.parquet").write_bytes(_bytes_of(String("region")).as_bytes())
    Path(d + "/tpch/sf1/nation.parquet").write_bytes(_bytes_of(String("nation")).as_bytes())
    var files = List[DatasetFile]()
    files.append(
        DatasetFile(
            String("tpch/sf1/region.parquet"),
            _bytes_of(String("region")).byte_length(),
            _hex(_bytes_of(String("region"))),
            5,
        )
    )
    files.append(DatasetFile.unrecorded(String("tpch/sf1/nation.parquet"), 25))
    var m = DatasetManifest(String("tpch"), String("sf1"), String(), files^)
    var report = verify_dataset(m, d)
    assert_equal(report.checks[0].status, FILE_VERIFIED)
    var text = render_stage(m, report, List[Int](), String(), List[ExtensionCheck]())
    assert_false(text.find(String('RecordedFile("tpch/sf1/region.parquet"')) >= 0)
    assert_true(text.find(String('RecordedFile("tpch/sf1/nation.parquet"')) >= 0)
    assert_true(text.find(String(", 25))")) >= 0)


def test_a_partial_dataset_is_refused_and_left_alone() raises:
    var d = _dir(String("partial"))
    makedirs(d + "/tpch/sf1", exist_ok=True)
    Path(d + "/tpch/sf1/region.parquet").write_bytes(String("old bytes").as_bytes())
    var manifest = tpch_manifest(1)
    assert_equal(tpch_state(manifest, d), TPCH_PARTIAL)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent))
    with assert_raises(contains="already exist"):
        _ = generate_tpch(s, manifest, 1, d, String("/ext/e"), 4 * _GIB, String(_VERSION))
    assert_equal(len(sent[]), 0)
    assert_equal(Path(d + "/tpch/sf1/region.parquet").read_text(), String("old bytes"))
    assert_false(exists(d + "/tpch/sf1/nation.parquet"))


def test_a_failed_copy_removes_what_the_run_wrote() raises:
    var d = _dir(String("failed_copy"))
    var manifest = tpch_manifest(1)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent, String("orders")))
    with assert_raises(contains="cannot write orders"):
        _ = generate_tpch(s, manifest, 1, d, String("/ext/e"), 4 * _GIB, String(_VERSION))
    assert_equal(tpch_state(manifest, d), TPCH_ABSENT)


def test_a_wrong_row_count_is_refused() raises:
    var d = _dir(String("wrong_rows"))
    var manifest = tpch_manifest(1)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent, String(""), String("customer")))
    with assert_raises(contains="tpch/sf1/customer.parquet has 150001 rows"):
        _ = generate_tpch(s, manifest, 1, d, String("/ext/e"), 4 * _GIB, String(_VERSION))
    assert_equal(tpch_state(manifest, d), TPCH_ABSENT)


def test_an_extension_that_did_not_load_is_refused() raises:
    var d = _dir(String("not_loaded"))
    var manifest = tpch_manifest(1)
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(sent, StageFake(sent, String(""), String(""), String("false")))
    with assert_raises(contains="tpch extension is not loaded"):
        _ = generate_tpch(s, manifest, 1, d, String("/ext/e"), 4 * _GIB, String(_VERSION))
    assert_equal(tpch_state(manifest, d), TPCH_ABSENT)
    assert_false(_sent_text(sent).find(String("CALL dbgen")) >= 0)


def test_the_extension_file_check() raises:
    var bytes = String("an extension file")
    var digest = _hex(bytes)
    var none = List[ExtensionPin]()
    var plain = check_extension_bytes(bytes.as_bytes(), none, String("1.5.6"), String("linux_amd64"))
    assert_equal(plain.status, EXT_UNRECORDED)
    assert_equal(plain.sha256, digest)
    assert_equal(plain.size, 17)
    var pins = List[ExtensionPin]()
    pins.append(ExtensionPin(String("1.5.6"), String("linux_amd64"), digest, 17))
    assert_equal(
        check_extension_bytes(bytes.as_bytes(), pins, String("1.5.6"), String("linux_amd64")).status,
        EXT_PINNED,
    )
    assert_equal(
        check_extension_bytes(String("another one!!!!!!").as_bytes(), pins, String("1.5.6"), String("linux_amd64")).status,
        EXT_MISMATCH,
    )
    # a pin for another platform decides nothing here
    assert_equal(
        check_extension_bytes(String("another one!!!!!!").as_bytes(), pins, String("1.5.6"), String("osx_arm64")).status,
        EXT_UNRECORDED,
    )
    var gz = List[UInt8]()
    gz.append(UInt8(0x1F))
    gz.append(UInt8(0x8B))
    gz.append(UInt8(8))
    assert_equal(check_extension_bytes(Span(gz), pins, String("1.5.6"), String("linux_amd64")).status, EXT_GZIPPED)
    assert_equal(
        extension_pin_line(String("1.5.6"), String("linux_amd64"), digest, 17),
        String('    out.append(ExtensionPin("1.5.6", "linux_amd64", "') + digest + String('", 17))'),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
