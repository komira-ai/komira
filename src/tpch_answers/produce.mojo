# Producing the answers file for staged TPC-H scale factor 1: check the staged
# files, lock them, start DuckDB on them (one thread, so the sums of doubles
# come out the same on every run), record every query's answer, write the
# answers beside the lock.

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path

from bench_corpus import suite
from bench_data import (
    lock_from_report,
    tpch_manifest,
    verify_dataset,
    write_lock_file,
)
from bench_duckdb import DuckDbSession, DuckDbTransport

from .record import record_answers, register_tables, tpch_header

comptime ANSWERS_FILE = "answers.txt"
"""The answers file's name inside the output directory."""

comptime QUERIES_DIR = "queries"
"""The directory of the output directory that holds the query texts, one
`<id>.sql` file each (`q1.sql` .. `q22.sql`), the bytes of the corpus text."""

comptime _GIB: Int = 1024 * 1024 * 1024


def _stem(rel_path: String) -> String:
    var slash = rel_path.rfind("/")
    var base = String(rel_path[byte = slash + 1 : rel_path.byte_length()])
    return String(base[byte=0 : base.byte_length() - 8])


def produce_tpch_sf1_answers[T: DuckDbTransport](
    mut session: DuckDbSession[T],
    cache_dir: String,
    out_dir: String,
    memory_limit_gib: Int,
) raises -> String:
    """Write `<out_dir>/answers.txt`, `<out_dir>/locks/tpch_sf1.lock` and the
    text of every query as `<out_dir>/queries/<id>.sql` for the TPC-H scale
    factor 1 files under `cache_dir` and return one line saying what was
    written. A reader of the answers takes the query texts from the same
    corpus the answers were recorded for.

    The staged files are verified against the manifest and locked before
    DuckDB is asked anything; a missing, truncated or altered file raises, and
    nothing is written. The answers file names the lock's fingerprint, so the
    answers say which bytes they were computed over. An answers file already in
    `out_dir` is never replaced.

    Raises:
        Error: unusable data (the message is the verification report), an
            answers file already there, DuckDB refusing a statement or
            query, or an answer that cannot be recorded.
    """
    var manifest = tpch_manifest(1)
    var report = verify_dataset(manifest, cache_dir)
    if not report.is_usable():
        raise Error(String("the staged TPC-H files are not usable:\n") + report.render())
    var lock = lock_from_report(manifest, report)
    var target = out_dir + String("/") + String(ANSWERS_FILE)
    if exists(target):
        raise Error(target + String(" exists; it is never overwritten"))
    var settings = session.start(1, memory_limit_gib * _GIB)
    var names = List[String]()
    var paths = List[String]()
    for i in range(len(manifest.files)):
        names.append(_stem(manifest.files[i].path))
        paths.append(cache_dir + String("/") + manifest.files[i].path)
    register_tables(session, names, paths)
    var corpus = suite("tpch")
    var text = record_answers(session, corpus, tpch_header(corpus, settings.version, lock.fingerprint()))
    makedirs(out_dir, exist_ok=True)
    write_lock_file(out_dir, lock)
    var queries_dir = out_dir + String("/") + String(QUERIES_DIR)
    makedirs(queries_dir, exist_ok=True)
    for i in range(len(corpus.queries)):
        Path(queries_dir + String("/") + corpus.queries[i].id + String(".sql")).write_text(corpus.queries[i].text)
    Path(target).write_text(text)
    return (
        String("recorded ") + String(len(corpus.queries)) + String(" answers over ")
        + String(len(manifest.files)) + String(" files, data lock fingerprint ") + lock.fingerprint()
    )
