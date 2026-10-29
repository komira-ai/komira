# The command line of `komira-bench-stage` (main/stage_main.mojo hands it the
# arguments). Every setting is a flag; nothing is read from the environment.
#
#   komira-bench-stage tpch --duckdb FILE --tpch-extension FILE --cache-dir DIR
#       --scale-factor 1|10|100 [--duckdb-version V] [--platform P]
#       [--memory-limit-gib N] [--max-silence-minutes N]
#     Generates TPC-H at the scale factor into DIR/tpch/sf<N>/ with the pinned
#     DuckDB and the tpch extension file, never replacing a file (a directory
#     that already holds all eight is only verified; one that holds some is
#     refused), then verifies the files and prints the lines to record.
#   komira-bench-stage verify --dataset NAME --scale SCALE --cache-dir DIR
#     Verifies a supplied dataset (ClickBench: --dataset clickbench --scale
#     full) and prints the lines to record. It reads no Parquet footer.
#
# Exit status: 0 done and every file usable, 1 the run failed or a file failed
# verification, 2 the arguments are wrong (nothing was run).

from komira_bench_duckdb import DEFAULT_DUCKDB_VERSION, open_pinned

from .manifest import find_manifest, tpch_manifest
from .stage import (
    DEFAULT_EXTENSION_PLATFORM,
    ExtensionCheck,
    EXT_GZIPPED,
    EXT_MISMATCH,
    TPCH_ABSENT,
    TPCH_PARTIAL,
    check_extension_file,
    describe_generation,
    generate_tpch,
    render_stage,
    tpch_state,
)
from .verify import verify_dataset

comptime EXIT_OK: Int = 0
comptime EXIT_FAILED: Int = 1
comptime EXIT_USAGE: Int = 2


struct Flags(Copyable, Movable):
    """The `--name value` / `--name=value` flags of one command."""

    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()

    def has(self, name: String) -> Bool:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return True
        return False

    def get(self, name: String, fallback: String) -> String:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i].copy()
        return fallback.copy()

    def require(self, name: String) raises -> String:
        if not self.has(name):
            raise Error(String("missing --") + name)
        return self.get(name, String(""))


def parse_flags(args: List[String], start: Int, allowed: List[String]) raises -> Flags:
    """Parse `args[start:]` as flags named in `allowed` (without the dashes).

    Raises:
        Error: a word that is not a flag, a flag not in `allowed`, a flag given
            twice, or a flag with no value.
    """
    var out = Flags()
    var i = start
    while i < len(args):
        var word = args[i].copy()
        if not word.startswith(String("--")):
            raise Error(String("not a flag: ") + word)
        var body = String(word[byte=2:word.byte_length()])
        var value = String("")
        var eq = body.find(String("="))
        if eq >= 0:
            value = String(body[byte=eq + 1:body.byte_length()])
            var name = String(body[byte=0:eq])
            body = name^
        else:
            if i + 1 >= len(args):
                raise Error(String("--") + body + String(" needs a value"))
            i += 1
            value = args[i].copy()
        var known = False
        for j in range(len(allowed)):
            if allowed[j] == body:
                known = True
        if not known:
            raise Error(String("unknown flag --") + body)
        if out.has(body):
            raise Error(String("--") + body + String(" given twice"))
        out.names.append(body^)
        out.values.append(value^)
        i += 1
    return out^


def parse_positive(text: String, what: String) raises -> Int:
    """A positive decimal number of at most 9 digits."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error(what + String(" is not a number: '") + text + String("'"))
    var n = 0
    for c in b:
        if c < UInt8(0x30) or c > UInt8(0x39):
            raise Error(what + String(" is not a number: '") + text + String("'"))
        n = n * 10 + Int(c - UInt8(0x30))
    if n < 1:
        raise Error(what + String(" must be at least 1"))
    return n


def _tpch_flags() -> List[String]:
    return [
        String("duckdb"),
        String("tpch-extension"),
        String("cache-dir"),
        String("scale-factor"),
        String("duckdb-version"),
        String("platform"),
        String("memory-limit-gib"),
        String("max-silence-minutes"),
    ]


def _verify_flags() -> List[String]:
    return [String("dataset"), String("scale"), String("cache-dir")]


def _run_tpch(flags: Flags, scale_factor: Int, memory_gib: Int, silence_minutes: Int) raises -> Int:
    var cache_dir = flags.require(String("cache-dir"))
    var version = flags.get(String("duckdb-version"), String(DEFAULT_DUCKDB_VERSION))
    var platform = flags.get(String("platform"), String(DEFAULT_EXTENSION_PLATFORM))
    var manifest = tpch_manifest(scale_factor)
    var state = tpch_state(manifest, cache_dir)
    if state == TPCH_PARTIAL:
        raise Error(
            "some of the files of " + manifest.scale + " exist under " + cache_dir
            + " and some do not; nothing is replaced: remove the partial set by hand"
        )
    var header = String("")
    var extension = List[ExtensionCheck]()
    var rows = List[Int]()
    if state == TPCH_ABSENT:
        var check = check_extension_file(flags.require(String("tpch-extension")), version, platform)
        if check.status == EXT_GZIPPED or check.status == EXT_MISMATCH:
            raise Error(check.describe())
        extension.append(check^)
        var s = open_pinned(flags.require(String("duckdb")), version, silence_minutes * 60000)
        try:
            var g = generate_tpch(
                s, manifest, scale_factor, cache_dir,
                flags.require(String("tpch-extension")), memory_gib * 1024 * 1024 * 1024, version,
            )
            header = describe_generation(manifest, g)
            rows = g.rows.copy()
        except e:
            try:
                s.kill()
            except:
                pass
            raise Error(String(e))
        _ = s.close()
    else:
        header = String("generated earlier: every file was already present; only verified now\n")
    var report = verify_dataset(manifest, cache_dir)
    print(render_stage(manifest, report, rows, header^, extension))
    if report.is_usable():
        return EXIT_OK
    return EXIT_FAILED


def _run_verify(flags: Flags) raises -> Int:
    var manifest = find_manifest(flags.require(String("dataset")), flags.require(String("scale")))
    var report = verify_dataset(manifest, flags.require(String("cache-dir")))
    print(render_stage(manifest, report, List[Int](), String(), List[ExtensionCheck]()))
    if report.is_usable():
        return EXIT_OK
    return EXIT_FAILED


def run_stage(args: List[String]) -> Int:
    """The binary's whole life, over the arguments after the program name: the
    exit status (module header). A refusal or a failure is printed on stderr."""
    if len(args) == 0:
        print("usage: komira-bench-stage tpch|verify [flags]; see the module header", file=FileDescriptor(2))
        return EXIT_USAGE
    var command = args[0].copy()
    var flags = Flags()
    var scale_factor = 0
    var memory_gib = 24
    var silence_minutes = 240
    try:
        if command == String("tpch"):
            flags = parse_flags(args, 1, _tpch_flags())
            _ = flags.require(String("duckdb"))
            _ = flags.require(String("tpch-extension"))
            _ = flags.require(String("cache-dir"))
            scale_factor = parse_positive(flags.require(String("scale-factor")), String("--scale-factor"))
            if scale_factor != 1 and scale_factor != 10 and scale_factor != 100:
                raise Error(String("--scale-factor must be 1, 10 or 100"))
            if flags.has(String("memory-limit-gib")):
                memory_gib = parse_positive(flags.get(String("memory-limit-gib"), String("")), String("--memory-limit-gib"))
            if flags.has(String("max-silence-minutes")):
                silence_minutes = parse_positive(flags.get(String("max-silence-minutes"), String("")), String("--max-silence-minutes"))
        elif command == String("verify"):
            flags = parse_flags(args, 1, _verify_flags())
            _ = flags.require(String("dataset"))
            _ = flags.require(String("scale"))
            _ = flags.require(String("cache-dir"))
        else:
            raise Error(String("unknown command '") + command + String("'"))
    except e:
        print(String(e), file=FileDescriptor(2))
        return EXIT_USAGE
    try:
        if command == String("tpch"):
            return _run_tpch(flags, scale_factor, memory_gib, silence_minutes)
        return _run_verify(flags)
    except e:
        print(String(e), file=FileDescriptor(2))
        return EXIT_FAILED
