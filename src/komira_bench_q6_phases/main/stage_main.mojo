# Stages TPC-H scale factor 1 into a build output directory, with the pinned
# DuckDB's tpch extension, through the benchmark's own staging
# (komira_bench_data.run_stage). That staging wants an absolute cache
# directory and a build action's output path is relative to its working
# directory, so this program makes it absolute and creates it.
#
#   stage --duckdb FILE --tpch-extension FILE.gz --cache-dir DIR
#         [--memory-limit-gib N]
#
# Exit status: 0 when DIR/tpch/sf1/lineitem.parquet exists afterwards (the
# staging's own verdict is printed either way); 2 for a bad flag; 1 otherwise.

from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.sys import argv, exit

from komira_bench_data import run_stage


def main():
    var all = argv()
    var duckdb = String("")
    var extension = String("")
    var cache = String("")
    var mem = String("8")
    var i = 1
    while i < len(all):
        var word = String(all[i])
        if i + 1 >= len(all):
            print("stage: " + word + " needs a value")
            exit(2)
        var value = String(all[i + 1])
        if word == "--duckdb":
            duckdb = value
        elif word == "--tpch-extension":
            extension = value
        elif word == "--cache-dir":
            cache = value
        elif word == "--memory-limit-gib":
            mem = value
        else:
            print("stage: unknown flag " + word)
            exit(2)
        i += 2
    if duckdb.byte_length() == 0 or extension.byte_length() == 0 or cache.byte_length() == 0:
        print("stage: --duckdb, --tpch-extension and --cache-dir are required")
        exit(2)
    try:
        if not cache.startswith("/"):
            cache = String(Path.cwd()) + "/" + cache
        makedirs(cache, exist_ok=True)
        var args = List[String]()
        args.append("tpch")
        args.append("--duckdb")
        args.append(duckdb)
        args.append("--tpch-extension")
        args.append(extension)
        args.append("--cache-dir")
        args.append(cache)
        args.append("--scale-factor")
        args.append("1")
        args.append("--memory-limit-gib")
        args.append(mem)
        var status = run_stage(args)
        print("stage: run_stage exit status " + String(status))
        if exists(cache + "/tpch/sf1/lineitem.parquet"):
            exit(0)
        exit(1)
    except e:
        print("stage: " + String(e))
        exit(1)
