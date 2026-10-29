# What a run is told, as plain data: the numbers both engines share, how many
# sweeps and reps to measure, the facts about the host and the DuckDB binary
# that go into the result's fingerprint, and the dataset. Nothing here reads
# the environment or a file; the program fills these from its flags.

from komira_bench_data import DatasetManifest
from komira_bench_report import DuckDbPin as ReportDuckDbPin


struct RunSettings(Copyable, Movable):
    """`threads` and `memory_limit_bytes` are given to both engines. A warm
    cell is `warm_sweeps` sweeps of `warm_reps` reps each (rep 0 of a sweep is
    dropped by the statistic, so it is the discarded run before the median).
    A cold cell is `cold_sweeps` sweeps of `cold_reps` reps with the file
    cache dropped before every rep of either engine; `cold_sweeps` of 0 means
    cold is not measured. `pass_max` is the ratio at or below which a cell
    passes."""

    var threads: Int
    var memory_limit_bytes: Int
    var warm_sweeps: Int
    var warm_reps: Int
    var cold_sweeps: Int
    var cold_reps: Int
    var pass_max: Float64

    def __init__(
        out self,
        threads: Int,
        memory_limit_bytes: Int,
        warm_sweeps: Int = 3,
        warm_reps: Int = 6,
        cold_sweeps: Int = 0,
        cold_reps: Int = 3,
        pass_max: Float64 = 1.0,
    ):
        self.threads = threads
        self.memory_limit_bytes = memory_limit_bytes
        self.warm_sweeps = warm_sweeps
        self.warm_reps = warm_reps
        self.cold_sweeps = cold_sweeps
        self.cold_reps = cold_reps
        self.pass_max = pass_max

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
