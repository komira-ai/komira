# The flags of the benchmark program, parsed from a list of arguments. Every
# value is a flag (`--name value`); nothing is read from the environment. A
# flag that is not known, given twice, or missing its value is an error, as is
# a missing required flag.

from komira_bench_duckdb import OrderKey

comptime DEFAULT_MAX_SILENCE_MS: Int = 600_000
comptime DEFAULT_MEMORY_PERCENT: Int = 80


struct RunFlags(Copyable, Movable):
    """The parsed flags. `memory_limit_bytes` is the flag, or when absent
    `DEFAULT_MEMORY_PERCENT` percent of `mem_total_bytes`, rounded down to a
    whole KiB; `threads` is the flag, or `cores`."""

    var duckdb_path: String
    var duckdb_version: String
    var cache_dir: String
    var out_dir: String
    var dataset: String
    var scale: String
    var suite: String
    var query_id: String
    var sql_file: String
    var order_keys: List[OrderKey]
    var threads: Int
    var memory_limit_bytes: Int
    var warm_sweeps: Int
    var warm_reps: Int
    var cold_sweeps: Int
    var cold_reps: Int
    var pass_max: Float64
    var hostclass: String
    var cpu_model: String
    var os: String
    var komira_version: String
    var cores: Int
    var mem_total_bytes: Int
    var drop_caches_file: String
    var max_silence_ms: Int

    def __init__(out self):
        self.duckdb_path = String("")
        self.duckdb_version = String("1.5.6")
        self.cache_dir = String("")
        self.out_dir = String("")
        self.dataset = String("")
        self.scale = String("")
        self.suite = String("")
        self.query_id = String("")
        self.sql_file = String("")
        self.order_keys = List[OrderKey]()
        self.threads = 0
        self.memory_limit_bytes = 0
        self.warm_sweeps = 3
        self.warm_reps = 6
        self.cold_sweeps = 0
        self.cold_reps = 3
        self.pass_max = 1.0
        self.hostclass = String("")
        self.cpu_model = String("")
        self.os = String("")
        self.komira_version = String("")
        self.cores = 0
        self.mem_total_bytes = 0
        self.drop_caches_file = String("")
        self.max_silence_ms = DEFAULT_MAX_SILENCE_MS


def usage() -> String:
    return String(
        "usage: komira_bench_runner_main\n"
        "  --duckdb PATH --cache-dir DIR --out-dir DIR\n"
        "  --dataset NAME --scale SCALE   (tpch sf1, clickbench full, ...)\n"
        "  --suite NAME --query ID --sql-file PATH   (the query text)\n"
        "  [--order-key COLUMN[:desc][:nulls_first]]...   (keys of a top-level ORDER BY)\n"
        "  --hostclass LABEL --cpu-model TEXT --os TEXT --komira-version TEXT\n"
        "  --cores N --mem-bytes N\n"
        "  [--threads N (default: cores)] [--memory-limit-bytes N (default: 80% of mem)]\n"
        "  [--duckdb-version V] [--warm-sweeps N] [--warm-reps N]\n"
        "  [--cold-sweeps N --cold-reps N --drop-caches-file PATH]\n"
        "  [--pass-max X] [--max-silence-ms N]\n"
    )


def _int(text: String, flag: String) raises -> Int:
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 18:
        raise Error(flag + " needs a whole number, got '" + text + "'")
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            raise Error(flag + " needs a whole number, got '" + text + "'")
    return atol(text)


def _float(text: String, flag: String) raises -> Float64:
    var ok = text.byte_length() > 0
    var b = text.as_bytes()
    var dots = 0
    for i in range(len(b)):
        if b[i] == 0x2E:
            dots += 1
        elif b[i] < 0x30 or b[i] > 0x39:
            ok = False
    if not ok or dots > 1:
        raise Error(flag + " needs a number, got '" + text + "'")
    return atof(text)


def parse_order_key(text: String) raises -> OrderKey:
    """`COLUMN`, `COLUMN:desc`, `COLUMN:nulls_first` or both, in that order."""
    var parts = text.split(":")
    if len(parts) == 0:
        raise Error("--order-key needs a column")
    var column = _int(String(parts[0]), String("--order-key"))
    var desc = False
    var nulls_first = False
    for i in range(1, len(parts)):
        if parts[i] == "desc":
            desc = True
        elif parts[i] == "nulls_first":
            nulls_first = True
        else:
            raise Error("--order-key: unknown modifier '" + String(parts[i]) + "'")
    return OrderKey(column, desc, nulls_first)


def parse_flags(args: List[String]) raises -> RunFlags:
    var f = RunFlags()
    var seen = List[String]()
    var i = 0
    var threads_given = False
    var memory_given = False
    while i < len(args):
        var flag = args[i].copy()
        if not flag.startswith("--"):
            raise Error("unexpected argument '" + flag + "'")
        if i + 1 >= len(args):
            raise Error(flag + " needs a value")
        var v = args[i + 1].copy()
        i += 2
        if flag != "--order-key":
            for j in range(len(seen)):
                if seen[j] == flag:
                    raise Error(flag + " given twice")
            seen.append(flag.copy())
        if flag == "--duckdb":
            f.duckdb_path = v^
        elif flag == "--duckdb-version":
            f.duckdb_version = v^
        elif flag == "--cache-dir":
            f.cache_dir = v^
        elif flag == "--out-dir":
            f.out_dir = v^
        elif flag == "--dataset":
            f.dataset = v^
        elif flag == "--scale":
            f.scale = v^
        elif flag == "--suite":
            f.suite = v^
        elif flag == "--query":
            f.query_id = v^
        elif flag == "--sql-file":
            f.sql_file = v^
        elif flag == "--order-key":
            f.order_keys.append(parse_order_key(v))
        elif flag == "--threads":
            f.threads = _int(v, flag)
            threads_given = True
        elif flag == "--memory-limit-bytes":
            f.memory_limit_bytes = _int(v, flag)
            memory_given = True
        elif flag == "--warm-sweeps":
            f.warm_sweeps = _int(v, flag)
        elif flag == "--warm-reps":
            f.warm_reps = _int(v, flag)
        elif flag == "--cold-sweeps":
            f.cold_sweeps = _int(v, flag)
        elif flag == "--cold-reps":
            f.cold_reps = _int(v, flag)
        elif flag == "--pass-max":
            f.pass_max = _float(v, flag)
        elif flag == "--hostclass":
            f.hostclass = v^
        elif flag == "--cpu-model":
            f.cpu_model = v^
        elif flag == "--os":
            f.os = v^
        elif flag == "--komira-version":
            f.komira_version = v^
        elif flag == "--cores":
            f.cores = _int(v, flag)
        elif flag == "--mem-bytes":
            f.mem_total_bytes = _int(v, flag)
        elif flag == "--drop-caches-file":
            f.drop_caches_file = v^
        elif flag == "--max-silence-ms":
            f.max_silence_ms = _int(v, flag)
        else:
            raise Error("unknown flag " + flag)
    var required = List[Tuple[String, Bool]]()
    required.append((String("--duckdb"), f.duckdb_path.byte_length() > 0))
    required.append((String("--cache-dir"), f.cache_dir.byte_length() > 0))
    required.append((String("--out-dir"), f.out_dir.byte_length() > 0))
    required.append((String("--dataset"), f.dataset.byte_length() > 0))
    required.append((String("--scale"), f.scale.byte_length() > 0))
    required.append((String("--suite"), f.suite.byte_length() > 0))
    required.append((String("--query"), f.query_id.byte_length() > 0))
    required.append((String("--sql-file"), f.sql_file.byte_length() > 0))
    required.append((String("--hostclass"), f.hostclass.byte_length() > 0))
    required.append((String("--cpu-model"), f.cpu_model.byte_length() > 0))
    required.append((String("--os"), f.os.byte_length() > 0))
    required.append((String("--komira-version"), f.komira_version.byte_length() > 0))
    required.append((String("--cores"), f.cores > 0))
    required.append((String("--mem-bytes"), f.mem_total_bytes > 0))
    for k in range(len(required)):
        if not required[k][1]:
            raise Error("missing " + required[k][0])
    if not threads_given:
        f.threads = f.cores
    if not memory_given:
        f.memory_limit_bytes = (f.mem_total_bytes // 100 * DEFAULT_MEMORY_PERCENT) // 1024 * 1024
    if f.cold_sweeps > 0 and f.drop_caches_file.byte_length() == 0:
        raise Error("--cold-sweeps needs --drop-caches-file")
    return f^
