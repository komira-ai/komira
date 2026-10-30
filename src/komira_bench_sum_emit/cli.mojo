# =============================================================================
# cli -- the bench's command line
# =============================================================================
#
#   bench --out-dir DIR [--label TEXT] [--threads 1,8] [--runs 9]
#         [--rows 16000000] [--row-group-rows 1000000] [--memory-limit-gib 32]
#
# Every setting is a flag. A refusal raises with the reason; the program
# prints it and exits 2.

from .bench import BenchSettings

comptime DEFAULT_THREADS: String = "1,8"
comptime DEFAULT_RUNS: Int = 9
comptime DEFAULT_ROWS: Int = 16000000
comptime DEFAULT_ROW_GROUP_ROWS: Int = 1000000
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
    """`1,8` as numbers, each at least 1.

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


def parse_bench_args(args: List[String]) raises -> BenchSettings:
    """The settings of `args` (the words after the program name).

    Raises:
        Error naming the problem: an unknown flag, a flag with no value, a
        repeated flag, no --out-dir, or a number out of range.
    """
    var out_dir = String("")
    var label = String("")
    var threads = String(DEFAULT_THREADS)
    var runs = DEFAULT_RUNS
    var rows = DEFAULT_ROWS
    var row_group_rows = DEFAULT_ROW_GROUP_ROWS
    var mem_gib = DEFAULT_MEMORY_GIB
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
        if i + 1 >= len(args):
            raise Error("--" + name + " needs a value")
        var value = args[i + 1].copy()
        if name == "out-dir":
            out_dir = value^
        elif name == "label":
            label = value^
        elif name == "threads":
            threads = value^
        elif name == "runs":
            runs = _parse_int(value, "--runs")
        elif name == "rows":
            rows = _parse_int(value, "--rows")
        elif name == "row-group-rows":
            row_group_rows = _parse_int(value, "--row-group-rows")
        elif name == "memory-limit-gib":
            mem_gib = _parse_int(value, "--memory-limit-gib")
        else:
            raise Error("unknown flag --" + name)
        i += 2
    if out_dir.byte_length() == 0:
        raise Error("--out-dir is required")
    if runs < 5:
        raise Error("--runs must be at least 5, got " + String(runs))
    if rows < 1:
        raise Error("--rows must be at least 1")
    if row_group_rows < 1:
        raise Error("--row-group-rows must be at least 1")
    if mem_gib < 1:
        raise Error("--memory-limit-gib must be at least 1")
    return BenchSettings(
        out_dir^,
        label^,
        parse_thread_list(threads),
        runs,
        rows,
        row_group_rows,
        mem_gib * 1024 * 1024 * 1024,
    )
