# The benchmark program, from its arguments to its exit status. It runs one
# query of one suite on the pinned DuckDB and the komira arm, writes the
# results (output.mojo) and prints the report.
#
# Today the komira arm is `RefusalArm`: every query is listed as unserved and
# nothing is timed. The line that builds the arm is the seam: a hand-built plan
# or `run_sql` replaces it there and nothing else in this file changes.
#
# The query text is a file (`--sql-file`), read as it is with the trailing
# newlines and spaces removed, so the digest in the result is that of the text
# both engines receive. The dataset is checked against its manifest first; the
# lock of the dataset (`<cache-dir>/locks/`) is read if it is there and
# verified, or written from this check if it is not, and its fingerprint goes
# into the result.
#
# Exit status: 0 only when every query ran and its values matched (the report
# package's rule), 1 otherwise, 2 for a fault of the run or of its arguments.

from std.os.path import exists
from std.pathlib import Path

from komira_bench_data import (
    DatasetManifest,
    DatasetLock,
    find_manifest,
    lock_file_path,
    lock_from_report,
    read_lock_file,
    verify_against_lock,
    verify_dataset,
    write_lock_file,
)
from komira_bench_duckdb import BenchClock, DuckDbSession, ProcessTransport, check_duckdb_file, open_pinned
from komira_bench_report import DuckDbPin, exit_code, summarize

from .arm import EngineArm, RefusalArm
from .cache import CacheDropper, NoCacheDropper, ProcDropCaches
from .flags import RunFlags, parse_flags, usage
from .output import format_run, write_run
from .query import QuerySpec
from .runner import run_queries
from .settings import HostFacts, RunInputs, RunSettings


def _trimmed(text: String) -> String:
    var b = text.as_bytes()
    var n = len(b)
    while n > 0 and (b[n - 1] == 0x0A or b[n - 1] == 0x0D or b[n - 1] == 0x20 or b[n - 1] == 0x09):
        n -= 1
    return String(text[byte=0:n])


def lock_fingerprint(manifest: DatasetManifest, cache_dir: String) raises -> String:
    """The fingerprint of the dataset lock under `cache_dir`. A lock that is
    there must verify against the files; one that is not is written from a
    verification of the files now. Raises with the verifier's report when the
    files are not usable."""
    var path = lock_file_path(cache_dir, manifest.name, manifest.scale)
    if exists(path):
        var lock = read_lock_file(cache_dir, manifest.name, manifest.scale)
        var checked = verify_against_lock(lock, cache_dir)
        if not checked.is_verified():
            raise Error("the files differ from the lock " + path + "\n" + checked.render())
        return lock.fingerprint()
    var report = verify_dataset(manifest, cache_dir)
    if not report.is_usable():
        raise Error("the dataset is not usable\n" + report.render())
    var lock = lock_from_report(manifest, report)
    write_lock_file(cache_dir, lock)
    return lock.fingerprint()


def _drive[
    D: CacheDropper
](
    mut dropper: D,
    f: RunFlags,
    manifest: DatasetManifest,
    query: QuerySpec,
    pin: DuckDbPin,
    lock_sha256: String,
) raises -> Int:
    var session = open_pinned(f.duckdb_path, f.duckdb_version, f.max_silence_ms)
    # The komira arm. Replace this line to plug in an engine.
    var arm = RefusalArm()
    var settings = RunSettings(
        f.threads, f.memory_limit_bytes, f.warm_sweeps, f.warm_reps, f.cold_sweeps, f.cold_reps, f.pass_max
    )
    var inputs = RunInputs(
        manifest.copy(),
        f.cache_dir.copy(),
        lock_sha256.copy(),
        pin.copy(),
        HostFacts(
            f.hostclass.copy(),
            f.cpu_model.copy(),
            Int64(f.cores),
            Int64(f.mem_total_bytes),
            f.os.copy(),
            f.komira_version.copy(),
        ),
    )
    var queries = List[QuerySpec]()
    queries.append(query.copy())
    try:
        var out = run_queries(session, arm, dropper, BenchClock.system(), queries, inputs, settings)
        write_run(out, f.out_dir)
        print(format_run(out))
        _ = session.close()
        arm.close()
        return exit_code(summarize(out.warm))
    except e:
        session.kill()
        raise e^


def _run(args: List[String]) raises -> Int:
    var f = parse_flags(args)
    var manifest = find_manifest(f.dataset, f.scale)
    var text = _trimmed(Path(f.sql_file).read_text())
    var query = QuerySpec(f.suite.copy(), f.query_id.copy(), manifest.name.copy(), text^, f.order_keys.copy())
    query.validate()
    var check = check_duckdb_file(f.duckdb_path, f.duckdb_version)
    if not check.is_pinned():
        raise Error(check.describe())
    var pin = DuckDbPin(check.version.copy(), check.sha256.copy(), String("PINNED"))
    var lock_sha256 = lock_fingerprint(manifest, f.cache_dir)
    if f.drop_caches_file.byte_length() > 0:
        var dropper = ProcDropCaches(f.drop_caches_file.copy())
        return _drive(dropper, f, manifest, query, pin, lock_sha256)
    var none = NoCacheDropper()
    return _drive(none, f, manifest, query, pin, lock_sha256)


def run_entrypoint(args: List[String]) -> Int:
    """Run the program over `args` (without the program name); the exit
    status. Prints the report, or the error and the usage."""
    try:
        return _run(args)
    except e:
        print("error: " + String(e))
        print(usage())
        return 2
