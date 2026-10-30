# What a run is told, as plain data: the numbers both engines share, how many
# sweeps and reps to measure, the facts about the host and the DuckDB binary
# that go into the result's fingerprint, and the dataset. Nothing here reads
# the environment or a file; the program fills these from its flags.

from komira_bench_data import DatasetManifest
from komira_bench_report import DuckDbPin as ReportDuckDbPin


# From this many threads on, a run discards WIDE_WARMUP_RUNS runs of each
# query on each engine before its first sweep. A wide run's first runs
# page-fault heavily while the allocator and thread stacks warm up (tens of
# thousands of minor faults per run, then a steady few hundred), so one
# discarded rep per sweep leaves cold-allocator time in the warm numbers.
comptime WIDE_WARMUP_THREADS: Int = 32
comptime WIDE_WARMUP_RUNS: Int = 5
# `RunSettings.warmup_runs` of this value means "choose by thread count".
comptime WARMUP_AUTO: Int = -1


def warmup_runs_for(threads: Int, requested: Int = WARMUP_AUTO) -> Int:
    """The runs of each query, on each engine, discarded before the first warm
    sweep. A `requested` count of 0 or more is used as given; `WARMUP_AUTO`
    gives 0 below `WIDE_WARMUP_THREADS` threads (rep 0 of each sweep is still
    dropped) and `WIDE_WARMUP_RUNS` from there up."""
    if requested >= 0:
        return requested
    if threads >= WIDE_WARMUP_THREADS:
        return WIDE_WARMUP_RUNS
    return 0


struct RunSettings(Copyable, Movable):
    """`threads` and `memory_limit_bytes` are given to both engines. A warm
    cell is `warm_sweeps` sweeps of `warm_reps` reps each (rep 0 of a sweep is
    dropped by the statistic); a cell's time is the least over the sweeps of
    each sweep's median, not one median after one discarded run).
    A cold cell is `cold_sweeps` sweeps of `cold_reps` reps with the file
    cache dropped before every rep of either engine; `cold_sweeps` of 0 means
    cold is not measured. `warmup_runs` is the number of runs of each query on
    each engine discarded before the first warm sweep (`warmup_runs_for`
    resolves `WARMUP_AUTO`); a cold cell has none. `pass_max` is the ratio at or below which a cell
    passes."""

    var threads: Int
    var memory_limit_bytes: Int
    var warm_sweeps: Int
    var warm_reps: Int
    var cold_sweeps: Int
    var cold_reps: Int
    var pass_max: Float64
    var warmup_runs: Int

    def __init__(
        out self,
        threads: Int,
        memory_limit_bytes: Int,
        warm_sweeps: Int = 3,
        warm_reps: Int = 6,
        cold_sweeps: Int = 0,
        cold_reps: Int = 3,
        pass_max: Float64 = 1.0,
        warmup_runs: Int = WARMUP_AUTO,
    ):
        self.threads = threads
        self.memory_limit_bytes = memory_limit_bytes
        self.warm_sweeps = warm_sweeps
        self.warm_reps = warm_reps
        self.cold_sweeps = cold_sweeps
        self.cold_reps = cold_reps
        self.pass_max = pass_max
        self.warmup_runs = warmup_runs

    def warm_warmup_runs(self) -> Int:
        """The warm-up runs this run discards before each warm cell."""
        return warmup_runs_for(self.threads, self.warmup_runs)

    def validate(self) raises:
        if self.threads < 1:
            raise Error("threads must be at least 1")
        if self.memory_limit_bytes < 1024 or self.memory_limit_bytes % 1024 != 0:
            raise Error("the memory limit must be a whole number of KiB")
        if self.warm_sweeps < 1 or self.warm_reps < 2:
            raise Error("a warm cell needs at least 1 sweep of 2 reps (rep 0 is dropped)")
        if self.cold_sweeps < 0:
            raise Error("cold sweeps cannot be negative")
        if self.cold_sweeps > 0 and self.cold_reps < 2:
            raise Error("a cold cell needs at least 2 reps per sweep (rep 0 is dropped)")
        if self.warmup_runs < WARMUP_AUTO:
            raise Error("warmup runs cannot be negative")
        if not (self.pass_max > 0.0):
            raise Error("the pass threshold must be positive")


struct HostFacts(Copyable, Movable):
    """The host as the result records it. `hostclass` is an opaque class
    label (an instance type), never a host name."""

    var hostclass: String
    var cpu_model: String
    var cores: Int64
    var mem_total_bytes: Int64
    var os: String
    var komira_version: String

    def __init__(
        out self,
        var hostclass: String,
        var cpu_model: String,
        cores: Int64,
        mem_total_bytes: Int64,
        var os: String,
        var komira_version: String,
    ):
        self.hostclass = hostclass^
        self.cpu_model = cpu_model^
        self.cores = cores
        self.mem_total_bytes = mem_total_bytes
        self.os = os^
        self.komira_version = komira_version^


struct RunInputs(Copyable, Movable):
    """The dataset a run reads and the fingerprint it states: the manifest,
    the directory its files are under, the fingerprint of the dataset lock
    (`DatasetLock.fingerprint()`), the DuckDB binary's pin facts and the
    host."""

    var manifest: DatasetManifest
    var cache_dir: String
    var lock_sha256: String
    var duckdb: ReportDuckDbPin
    var host: HostFacts

    def __init__(
        out self,
        var manifest: DatasetManifest,
        var cache_dir: String,
        var lock_sha256: String,
        var duckdb: ReportDuckDbPin,
        var host: HostFacts,
    ):
        self.manifest = manifest^
        self.cache_dir = cache_dir^
        self.lock_sha256 = lock_sha256^
        self.duckdb = duckdb^
        self.host = host^
