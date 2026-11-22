# Records DuckDB's answers to TPC-H q1..q22 over staged scale factor 1.
#
#   answers --duckdb FILE --cache-dir DIR --out-dir DIR [--memory-limit-gib N]
#
# Exit status: 0 the answers and the lock were written; 2 a flag was refused or
# the run failed (the message says which). The flags and the run are in
# tpch_answers; this program only forwards to them. A build action's paths are
# relative to its working directory, so they are made absolute here.

from std.os import makedirs
from std.os.path import realpath
from std.sys import argv, exit

from bench_duckdb import open_pinned
from tpch_answers import parse_answer_args, produce_tpch_sf1_answers


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    try:
        var settings = parse_answer_args(args)
        makedirs(settings.out_dir, exist_ok=True)
        var duckdb = String(realpath(settings.duckdb))
        var session = open_pinned(duckdb)
        var line = produce_tpch_sf1_answers(
            session,
            String(realpath(settings.cache_dir)),
            String(realpath(settings.out_dir)),
            settings.memory_limit_gib,
        )
        _ = session.close()
        print(line)
    except e:
        print("tpch answers: " + String(e))
        exit(2)
