# =============================================================================
# EngineConfig -- Pipeline execution configuration
# =============================================================================
#
# Controls morsel pipeline behavior: reader/writer thread counts, batch
# sizing, memory budgets, worker/driver CPU placement, the memory advice for
# large buffers, and the variable-width offset promotion point.
#
# Concurrency is Static: explicit reader/writer counts or StorageProfile
# defaults, via the effective_readers_* formulas. Adaptive concurrency from
# probed I/O latency is not implemented.
#
# The embedding program builds an EngineConfig (for example from its
# command-line flags) and passes it explicitly. Nothing in the engine reads
# configuration from the process environment.
# =============================================================================

from std.sys import num_physical_cores

from komira_core.runtime.engine_placement import EnginePlacement
from komira_core.runtime.thp_policy import ADVICE_OFF, ADVICE_HUGEPAGE, ADVICE_POPULATE
from komira_core.arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    clamp_offset_promote_at,
)


# =============================================================================
# Compile-time defaults
# =============================================================================

# default max row groups in-flight.
comptime DEFAULT_MAX_IN_FLIGHT: Int = 3

# rows per Parquet reader batch.
comptime DEFAULT_BATCH_SIZE: Int = 65536

# max rows per output row group.
comptime DEFAULT_ROWS_PER_GROUP: Int = 1_000_000

# NVMe default reader count.
comptime NVME_DEFAULT_READERS: Int = 2

# S3 default reader count.
comptime S3_DEFAULT_READERS: Int = 8

# NVMe default concurrent writes.
comptime NVME_DEFAULT_WRITES: Int = 1

# S3 default concurrent writes.
comptime S3_DEFAULT_WRITES: Int = 8

# max reader threads for compute-bound workloads.
comptime MAX_COMPUTE_READERS: Int = 16

# fallback when num_cpus unavailable.
comptime FALLBACK_COMPUTE_READERS: Int = 8

# max bypass readers.
comptime MAX_BYPASS_READERS: Int = 8

# fallback bypass readers.
comptime FALLBACK_BYPASS_READERS: Int = 6


# =============================================================================
# StorageProfile
# =============================================================================

comptime STORAGE_LOCAL_NVME: Int = 0
comptime STORAGE_REMOTE_S3: Int = 1


# =============================================================================
# EngineConfig
# =============================================================================

struct EngineConfig(Copyable, Movable, Writable):
    """Pipeline execution configuration.

    Controls reader/writer thread counts, batch sizing, memory budgets, and
    other pipeline tuning parameters. All fields have sensible defaults for
    local NVMe workloads; override as needed for remote storage or
    memory-constrained environments.

    `EngineConfig()` is the default configuration: every placement
    policy off, no memory advice, and the Arrow Int32 offset ceiling as the
    promotion point.
    """

    # Storage profile: STORAGE_LOCAL_NVME or STORAGE_REMOTE_S3.
    var storage_profile: Int

    # Override reader thread count (0 = use profile default).
    var reader_threads: Int

    # Maximum row groups in-flight in the deep pipeline.
    var max_in_flight: Int

    # Batch size for Parquet reader (rows per batch).
    var batch_size: Int

    # Maximum rows per output row group.
    var rows_per_group: Int

    # Maximum concurrent async write operations.
    # 0 = use default from storage profile.
    var max_concurrent_writes: Int

    # Memory budget in bytes for the ConcurrencyController.
    # 0 = no memory constraint (default for benchmarks).
    # In production, set to 70% of available system memory.
    var memory_budget_bytes: Int

    # Worker/driver CPU placement policy for the engine thread pools.
    # The runtime stores it at construction; the topology functions take it.
    var placement: EnginePlacement

    # ADVICE_* bitmask (ADVICE_HUGEPAGE | ADVICE_POPULATE) applied to large
    # (>= HUGEPAGE_MIN_ALLOC_BYTES) buffers. ADVICE_OFF = no advice.
    var memory_advice: Int

    # Byte count above which a variable-width column's Int32 offsets are
    # promoted to Int64. Always in (0, ARROW_INT32_OFFSET_MAX]; a lower value
    # exercises the promotion path on small data.
    var offset_promote_at: Int

    # --- Constructor ---------------------------------------------------------

    def __init__(out self):
        """Create a default config for local NVMe workloads."""
        self.storage_profile = STORAGE_LOCAL_NVME
        self.reader_threads = 0
        self.max_in_flight = DEFAULT_MAX_IN_FLIGHT
        self.batch_size = DEFAULT_BATCH_SIZE
        self.rows_per_group = DEFAULT_ROWS_PER_GROUP
        self.max_concurrent_writes = 0
        self.memory_budget_bytes = 0
        self.placement = EnginePlacement()
        self.memory_advice = ADVICE_OFF
        self.offset_promote_at = ARROW_INT32_OFFSET_MAX

    def __init__(
        out self,
        storage_profile: Int,
        reader_threads: Int,
        max_in_flight: Int,
        batch_size: Int,
        rows_per_group: Int,
        max_concurrent_writes: Int,
        memory_budget_bytes: Int,
    ):
        """Create a config with explicit values."""
        self.storage_profile = storage_profile
        self.reader_threads = reader_threads
        self.max_in_flight = max_in_flight
        self.batch_size = batch_size
        self.rows_per_group = rows_per_group
        self.max_concurrent_writes = max_concurrent_writes
        self.memory_budget_bytes = memory_budget_bytes
        self.placement = EnginePlacement()
        self.memory_advice = ADVICE_OFF
        self.offset_promote_at = ARROW_INT32_OFFSET_MAX

    # --- Effective reader counts ---------------------------------------------

    def effective_readers(self, num_row_groups: Int) -> Int:
        """Effective reader thread count, capped by available row groups.

        Priority:
          1. Explicit reader_threads override (if > 0)
          2. StorageProfile default (2 for NVMe, 8 for S3)
        """
        var readers: Int
        if self.reader_threads > 0:
            readers = self.reader_threads
        elif self.storage_profile == STORAGE_REMOTE_S3:
            readers = S3_DEFAULT_READERS
        else:
            readers = NVME_DEFAULT_READERS
        return _clamp(readers, 1, num_row_groups)

    def effective_readers_for_bypass(
        self, num_row_groups: Int, bypass_ratio: Float64
    ) -> Int:
        """Effective readers for bypass workloads.

        When bypass_ratio >= 0.5 (half or more columns bypassed), scales up
        from NVMe default of 2 to min(num_cpus, num_row_groups, 8).
        """
        var readers: Int
        if self.reader_threads > 0:
            readers = self.reader_threads
        elif bypass_ratio >= 0.5:
            var cores = num_physical_cores()
            if cores < 1:
                cores = FALLBACK_BYPASS_READERS
            readers = _min(cores, MAX_BYPASS_READERS)
        elif self.storage_profile == STORAGE_REMOTE_S3:
            readers = S3_DEFAULT_READERS
        else:
            readers = NVME_DEFAULT_READERS
        return _clamp(readers, 1, num_row_groups)

    def effective_readers_for_aggregate(self, num_row_groups: Int) -> Int:
        """Effective readers for aggregation (compute-bound).

        Defaults to num_cpus (capped at 16) to saturate all cores during
        Phase 1 parallel accumulation.
        """
        var readers: Int
        if self.reader_threads > 0:
            readers = self.reader_threads
        else:
            var cores = num_physical_cores()
            if cores < 1:
                cores = FALLBACK_COMPUTE_READERS
            readers = _min(cores, MAX_COMPUTE_READERS)
        return _clamp(readers, 1, num_row_groups)

    def effective_readers_for_join(self, num_row_groups: Int) -> Int:
        """Effective readers for join probe (compute-bound).

        Defaults to num_cpus (capped at 16) -- join probe is read-only
        against the shared hash table, all cores can probe in parallel.
        """
        var readers: Int
        if self.reader_threads > 0:
            readers = self.reader_threads
        else:
            var cores = num_physical_cores()
            if cores < 1:
                cores = FALLBACK_COMPUTE_READERS
            readers = _min(cores, MAX_COMPUTE_READERS)
        return _clamp(readers, 1, num_row_groups)

    def effective_concurrent_writes(self) -> Int:
        """Effective concurrent write limit.

        Priority:
          1. Explicit max_concurrent_writes override (if > 0)
          2. StorageProfile default (1 for NVMe, 8 for S3)
        """
        if self.max_concurrent_writes > 0:
            return self.max_concurrent_writes
        if self.storage_profile == STORAGE_REMOTE_S3:
            return S3_DEFAULT_WRITES
        return NVME_DEFAULT_WRITES

    # --- Builder-style setters -----------------------------------------------

    def with_reader_threads(self, n: Int) -> EngineConfig:
        """Return a copy with reader_threads overridden."""
        var cfg = self.copy()
        cfg.reader_threads = n
        return cfg^

    def with_batch_size(self, n: Int) -> EngineConfig:
        """Return a copy with batch_size overridden."""
        var cfg = self.copy()
        cfg.batch_size = n
        return cfg^

    def with_rows_per_group(self, n: Int) -> EngineConfig:
        """Return a copy with rows_per_group overridden."""
        var cfg = self.copy()
        cfg.rows_per_group = n
        return cfg^

    def with_storage_profile(self, profile: Int) -> EngineConfig:
        """Return a copy with storage_profile overridden."""
        var cfg = self.copy()
        cfg.storage_profile = profile
        return cfg^

    def with_memory_budget(self, bytes: Int) -> EngineConfig:
        """Return a copy with memory_budget_bytes overridden."""
        var cfg = self.copy()
        cfg.memory_budget_bytes = bytes
        return cfg^

    def with_max_concurrent_writes(self, n: Int) -> EngineConfig:
        """Return a copy with max_concurrent_writes overridden."""
        var cfg = self.copy()
        cfg.max_concurrent_writes = n
        return cfg^

    def with_placement(self, placement: EnginePlacement) -> EngineConfig:
        """Return a copy with the worker/driver placement policy overridden."""
        var cfg = self.copy()
        cfg.placement = placement.copy()
        return cfg^

    def with_memory_advice(self, mode: Int) -> EngineConfig:
        """Return a copy with memory_advice overridden.

        `mode` is an ADVICE_* bitmask; bits outside
        `ADVICE_HUGEPAGE | ADVICE_POPULATE` are dropped.
        """
        var cfg = self.copy()
        cfg.memory_advice = mode & (ADVICE_HUGEPAGE | ADVICE_POPULATE)
        return cfg^

    def with_offset_promote_at(self, n: Int) -> EngineConfig:
        """Return a copy with offset_promote_at overridden.

        Values outside (0, ARROW_INT32_OFFSET_MAX] become
        ARROW_INT32_OFFSET_MAX: promotion never waits past the real Int32
        ceiling.
        """
        var cfg = self.copy()
        cfg.offset_promote_at = clamp_offset_promote_at(n)
        return cfg^

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "EngineConfig(storage_profile=",
            self.storage_profile,
            ", reader_threads=",
            self.reader_threads,
            ", max_in_flight=",
            self.max_in_flight,
            ", batch_size=",
            self.batch_size,
            ", rows_per_group=",
            self.rows_per_group,
            ", max_concurrent_writes=",
            self.max_concurrent_writes,
            ", memory_budget_bytes=",
            self.memory_budget_bytes,
            ", placement=",
            self.placement,
            ", memory_advice=",
            self.memory_advice,
            ", offset_promote_at=",
            self.offset_promote_at,
            ")",
        )


# =============================================================================
# Internal helpers
# =============================================================================

@always_inline
def _min(a: Int, b: Int) -> Int:
    if a < b:
        return a
    return b


@always_inline
def _clamp(value: Int, lo: Int, hi: Int) -> Int:
    """Clamp value into [lo, hi]. Mirrors Rust's .clamp()."""
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value
