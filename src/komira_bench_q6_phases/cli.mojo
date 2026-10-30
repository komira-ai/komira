# =============================================================================
# cli -- the probe's command line
# =============================================================================
#
#   probe --lineitem FILE | --cache-dir DIR  --out-dir DIR
#         [--threads 1,8,32,88] [--runs 9] [--memory-limit-gib 32]
#         [--expect-tpch-sf1]
#
# `--cache-dir DIR` names the staged TPC-H cache; the file is
# DIR/tpch/sf1/lineitem.parquet. `--expect-tpch-sf1` makes the probe check
# every answer against TPC-H Q6 at scale factor 1. Every setting is a flag.
# A refusal raises with the reason; the program prints it and exits 2.

from .probe import (
    NO_EXPECTED_REVENUE,
    ProbeSettings,
    TPCH_SF1_Q6_REVENUE_UNSCALED,
)

comptime DEFAULT_THREADS: String = "1,8,32,88"
comptime DEFAULT_RUNS: Int = 9
comptime DEFAULT_MEMORY_GIB: Int = 32


def _parse_int(text: String, what: String) raises -> Int:
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error(what + " is not a number: '" + text + "'")
    var n = 0
    for c in b:
        if c < UInt8(0x30) or c > UInt8(0x39):
            raise Error(what + " is not a number: '" + text + "'")
        n = n * 10 + Int(c - UInt8(0x30))
    return n


def parse_thread_list(text: String) raises -> List[Int]:
    """`1,8,32,88` as numbers, each at least 1.

    Raises:
        Error if an entry is not a whole number of at least 1, or none is given.
    """
    var out = List[Int]()
    var start = 0
    var b = text.as_bytes()
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(0x2C):
            var item = String(text[byte=start:i])
            var n = _parse_int(item, "--threads entry")
            if n < 1:
                raise Error("--threads entries must be at least 1, got " + item)
            out.append(n)
            start = i + 1
    if len(out) == 0:
        raise Error("--threads names no thread count")
    return out^


def parse_probe_args(args: List[String]) raises -> ProbeSettings:
    """The settings of `args` (the words after the program name).

    Raises:
        Error naming the problem: an unknown flag, a flag with no value, a
        repeated flag, neither or both of --lineitem and --cache-dir, no
        --out-dir, or a number out of range.
    """
    var lineitem = String("")
    var cache_dir = String("")
    var out_dir = String("")
    var threads = String(DEFAULT_THREADS)
    var runs = DEFAULT_RUNS
    var mem_gib = DEFAULT_MEMORY_GIB
    var expect = False
    var seen = List[String]()
    var i = 0
    while i < len(args):
        var word = args[i].copy()
        if not word.startswith("--"):
            raise Error("not a flag: " + word)
        var name = String(word[byte=2 : word.byte_length()])
        for k in range(len(seen)):
            if seen[k] == name:
                raise Error("--" + name + " given twice")
        seen.append(name)
        if name == "expect-tpch-sf1":
            expect = True
            i += 1
            continue
        if i + 1 >= len(args):
            raise Error("--" + name + " needs a value")
        var value = args[i + 1].copy()
        if name == "lineitem":
            lineitem = value^
        elif name == "cache-dir":
            cache_dir = value^
        elif name == "out-dir":
            out_dir = value^
        elif name == "threads":
            threads = value^
        elif name == "runs":
            runs = _parse_int(value, "--runs")
        elif name == "memory-limit-gib":
            mem_gib = _parse_int(value, "--memory-limit-gib")
        else:
            raise Error("unknown flag --" + name)
        i += 2
    if (lineitem.byte_length() == 0) == (cache_dir.byte_length() == 0):
        raise Error("give exactly one of --lineitem and --cache-dir")
    if out_dir.byte_length() == 0:
        raise Error("--out-dir is required")
    if runs < 5:
        raise Error("--runs must be at least 5, got " + String(runs))
    if mem_gib < 1:
        raise Error("--memory-limit-gib must be at least 1")
    if cache_dir.byte_length() > 0:
        lineitem = cache_dir + "/tpch/sf1/lineitem.parquet"
    var expected = NO_EXPECTED_REVENUE
    if expect:
        expected = TPCH_SF1_Q6_REVENUE_UNSCALED
    return ProbeSettings(
        lineitem^,
        out_dir^,
        parse_thread_list(threads),
        runs,
        mem_gib * 1024 * 1024 * 1024,
        expected,
    )
