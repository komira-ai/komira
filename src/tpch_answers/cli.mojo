# The flags of the answers program. Every setting is a flag; nothing is read
# from the environment.

from bench_data import parse_flags, parse_positive


struct AnswerSettings(Copyable, Movable):
    """The pinned DuckDB binary, the directory the data was staged in, the
    directory to write into and DuckDB's memory limit in GiB."""

    var duckdb: String
    var cache_dir: String
    var out_dir: String
    var memory_limit_gib: Int

    def __init__(out self, var duckdb: String, var cache_dir: String, var out_dir: String, memory_limit_gib: Int):
        self.duckdb = duckdb^
        self.cache_dir = cache_dir^
        self.out_dir = out_dir^
        self.memory_limit_gib = memory_limit_gib


comptime DEFAULT_MEMORY_GIB: Int = 8


def parse_answer_args(args: List[String]) raises -> AnswerSettings:
    """`--duckdb FILE --cache-dir DIR --out-dir DIR [--memory-limit-gib N]`,
    each also as `--name=value`.

    Raises:
        Error: a word that is not a flag, an unknown or repeated flag, a flag
            with no value, a missing required flag, or a memory limit that is
            not a positive whole number of GiB.
    """
    var allowed = [String("duckdb"), String("cache-dir"), String("out-dir"), String("memory-limit-gib")]
    var flags = parse_flags(args, 0, allowed)
    var gib: Int = DEFAULT_MEMORY_GIB
    if flags.has(String("memory-limit-gib")):
        gib = parse_positive(flags.require(String("memory-limit-gib")), String("--memory-limit-gib"))
    return AnswerSettings(
        flags.require(String("duckdb")),
        flags.require(String("cache-dir")),
        flags.require(String("out-dir")),
        gib,
    )
