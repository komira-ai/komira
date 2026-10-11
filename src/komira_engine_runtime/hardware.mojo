# =============================================================================
# HardwareProfile -- the CPU, cache and memory shape morsel sizing reads
# =============================================================================
#
# A `HardwareProfile` is a value: core counts, the L1d/L2/L3 sizes, the cache
# line, RAM, and the binding L2 instance (`l2_share.mojo`). It is filled once,
# by `hardware_detect.detect_hardware_profile()`, when the host profile is
# built (`host_profile.mojo`), and is then only read. Nothing in this file
# probes the machine: every accessor below is a pure function of the fields,
# so two hosts with equal profiles size morsels identically.
#
# Formulas:
#   * `optimal_morsel_rows(schema)`     -- L2-resident batch size (general)
#   * `optimal_agg_morsel_rows(schema)` -- L1d-resident batch size (agg)
#   * `l3_resident_rows(entry_bytes)`   -- hash-table sizing ceiling
#   * `compute_threads()`               -- physical-core worker pool
#   * `effective_e_core_l2_per_worker()` -- the per-worker share of the
#     binding L2 instance, which every grain formula is sized against
#
# The L2/2 target leaves room for operator state; L1d/2 keeps keys and values
# hot while hash probes run; the clamps absorb pathological hardware.
# =============================================================================

from komira_arrow.schema import Schema

# `defaults()` uses the process-wide physical-core snapshot, sampled before any
# worker pins itself: `num_physical_cores()` is affinity-aware on Linux, so a
# pinned thread would see a one-core machine.
from komira_host.cpu_topology import _process_physical_core_count


# =============================================================================
# Clamps / constants
# =============================================================================

# `optimal_morsel_rows` clamps
comptime MIN_MORSEL_ROWS: Int = 1024
comptime MAX_MORSEL_ROWS: Int = 131072

# `optimal_agg_morsel_rows` clamps
# DuckDB uses 2048 vectors for hash probing; upper bound avoids L1d thrash.
comptime MIN_AGG_MORSEL_ROWS: Int = 2048
comptime MAX_AGG_MORSEL_ROWS: Int = 16384

# `l3_resident_rows` fallback when L3 is absent (Apple Silicon has no L3).
#
comptime L3_FALLBACK_ROWS: Int = 1_000_000

# Apple-Silicon-shaped defaults used on Linux (not yet ported) and on other
# platforms.
comptime DEFAULT_L1D_BYTES: Int = 32 * 1024
comptime DEFAULT_L2_BYTES: Int = 256 * 1024
comptime DEFAULT_L3_BYTES: Int = 8 * 1024 * 1024
comptime DEFAULT_CACHE_LINE: Int = 64
comptime DEFAULT_TOTAL_RAM: Int = 16 * 1024 * 1024 * 1024
comptime DEFAULT_AVAILABLE_RAM: Int = 8 * 1024 * 1024 * 1024

# E-CORE-L2 HW MORSEL SIZING defaults. Apple-Silicon-shaped
# conservative fallback used when the perflevel sysctl keys are absent
# (homogeneous Intel Mac, hardened Linux container). The E-core L2 default
# matches the M3-family E-cluster shape (4 MiB shared by 4 E-cores). On the
# `defaults()` path the budget accessor still works: e_core_l2_bytes /
# e_cores_per_l2 = 4 MiB / 4 = 1 MiB per-worker.
comptime DEFAULT_E_CORE_L2_BYTES: Int = 4 * 1024 * 1024
comptime DEFAULT_E_CORES_PER_L2: Int = 4
comptime DEFAULT_P_CORE_L2_BYTES: Int = 4 * 1024 * 1024
comptime DEFAULT_P_CORES_PER_L2: Int = 4

# `effective_e_core_l2_per_worker` reserves this fraction of the per-worker
# E-core L2 share for the morsel's decoded rows; the other half is reserved
# for the hash-table heads / accumulator slots / dispatch struct (same
# rationale as the historical `/2` in `optimal_agg_morsel_rows`). Expressed
# as a numerator/denominator pair to keep the budget computation integer-only.
comptime E_CORE_L2_BUDGET_NUM: Int = 1
comptime E_CORE_L2_BUDGET_DEN: Int = 2



# =============================================================================
# HardwareProfile
# =============================================================================

struct HardwareProfile(Copyable, Movable, Writable):
    """Detected CPU / cache / memory characteristics.

    All sizes are in bytes. Populated once via
    `hardware_detect.detect_hardware_profile()` and then only read.
    Copyable so it can be passed by value
    to the materialize_* hook-build helpers without lifetime plumbing.

    """

    var physical_cores: Int
    var logical_cores: Int
    var l1d_cache_bytes: Int
    # MORSEL-SIZE-HARDWARE-AUTO-DERIVE SS1: min L1d across
    # heterogeneous cores (Apple M-series P+E, Intel Alder Lake P+E, ARM
    # big.LITTLE). For homogeneous silicon this equals `l1d_cache_bytes`.
    # The auto-derived morsel-size formula uses this field so E-core /
    # LITTLE-core morsels don't overflow L1d -> eviction churn. POD-by-
    # value Int (no heap, no string, no list — preserves gap6 safety).
    var l1d_min_bytes: Int
    var l2_cache_bytes: Int
    # v0.3 marks this 0 when L3 is absent (Apple Silicon).
    var l3_cache_bytes: Int
    var cache_line_bytes: Int
    var total_ram_bytes: Int
    var available_ram_bytes: Int
    # v0.3 emits a warning when this is > 1; we don't parse NUMA topology in
    # v0.4 yet, so this is always 1 on macOS and on the defaults path.
    var numa_nodes: Int
    # =====================================================================
    # E-CORE-L2 HW MORSEL SIZING (PERF-PRIMITIVE +
    # PERF-READ-6, maintainer decision FINAL)
    # =====================================================================
    # The homogeneous single-key sysctls (hw.l1dcachesize / hw.l2cachesize)
    # return the SMALLER E-core values on heterogeneous Apple Silicon while
    # the OS may schedule compute on EITHER P- or E-cores (macOS cannot pin
    # threads). The maintainer decision: size the morsel for the E-CORE L2-per-worker
    # budget so the morsel is residency-safe on EVERY core (a too-big morsel
    # thrashes worse than a too-small one). One global value, derived from the
    # smaller-core tier.
    #
    # All POD `Int` (no heap, no String, no List, no owning pointer, no
    # wildcard origin) — gap6-safe by construction, mirrors the
    # `l1d_min_bytes` POD-Int precedent above. Zero = "key absent / unread"
    # (homogeneous Intel Mac, hardened Linux container) -> the accessor falls
    # back conservatively (see `effective_e_core_l2_per_worker`).
    #
    # Real M3 Ultra values (sysctl):
    #   hw.perflevel1.l2cachesize = 4194304   (E-core L2 = 4 MiB)
    #   hw.perflevel1.cpusperl2   = 4         (4 E-cores share each L2)
    #   hw.perflevel0.l2cachesize = 16777216  (P-core L2 = 16 MiB)
    #   hw.perflevel0.cpusperl2   = 6         (6 P-cores share each L2)
    # LINUX REVISION. These two are now the SIZE
    # and the WORKER COUNT of ONE L2 INSTANCE -- the instance with the smallest
    # per-worker share anywhere in the process's allowed CPU set -- derived by
    # `l2_share.mojo` from `cache/index<L2>/{size,shared_cpu_list}` +
    # `topology/thread_siblings_list`. They must be read as a PAIR: dividing
    # one tier's size by another tier's divisor is not a share of anything
    # (that mistake, in `komira_engine_v2/grain.mojo`, is what this change
    # also removes). On macOS they remain the perflevel1 (E-tier) sysctls,
    # which are already exactly this pair.
    var e_core_l2_bytes: Int     # binding L2 instance SIZE   (macOS: perflevel1.l2cachesize)
    var e_cores_per_l2: Int      # compute workers sharing it (macOS: perflevel1.cpusperl2)
    # P-core values captured for completeness / logging only — the maintainer
    # decision uses the E-core tier for the morsel budget. NOT consumed by
    # the formula; present so `String(profile)` surfaces the full topology.
    var p_core_l2_bytes: Int     # perflevel0.l2cachesize
    var p_cores_per_l2: Int      # perflevel0.cpusperl2

    # --- Constructors --------------------------------------------------------

    def __init__(
        out self,
        physical_cores: Int,
        logical_cores: Int,
        l1d_cache_bytes: Int,
        l2_cache_bytes: Int,
        l3_cache_bytes: Int,
        cache_line_bytes: Int,
        total_ram_bytes: Int,
        available_ram_bytes: Int,
        numa_nodes: Int,
        l1d_min_bytes: Int = 0,
        e_core_l2_bytes: Int = 0,
        e_cores_per_l2: Int = 0,
        p_core_l2_bytes: Int = 0,
        p_cores_per_l2: Int = 0,
    ):
        """9-arg ctor backward-compatible with the v0.3 port; `l1d_min_bytes`
        added as a 10th optional argument (defaults to `l1d_cache_bytes` when
        omitted, matching homogeneous-silicon semantics).

        E-CORE-L2 HW MORSEL SIZING: four further trailing
        optional args carry the per-perflevel L2 sharing topology. They
        default to 0 ("unread") so every existing positional callsite (tests
        + the v0.3-shaped sites) compiles UNCHANGED. When omitted, the E-core
        budget accessor falls back to `l2_cache_bytes` (which is itself the
        E-core value on heterogeneous Apple Silicon) divided by a conservative
        divisor (see `effective_e_core_l2_per_worker`)."""
        self.physical_cores = physical_cores
        self.logical_cores = logical_cores
        self.l1d_cache_bytes = l1d_cache_bytes
        # When the caller omits `l1d_min_bytes` (== 0 sentinel), default to
        # `l1d_cache_bytes` so existing tests + callers see a sane non-zero
        # value with no heterogeneous-aware code path required.
        if l1d_min_bytes > 0:
            self.l1d_min_bytes = l1d_min_bytes
        else:
            self.l1d_min_bytes = l1d_cache_bytes
        self.l2_cache_bytes = l2_cache_bytes
        self.l3_cache_bytes = l3_cache_bytes
        self.cache_line_bytes = cache_line_bytes
        self.total_ram_bytes = total_ram_bytes
        self.available_ram_bytes = available_ram_bytes
        self.numa_nodes = numa_nodes
        self.e_core_l2_bytes = e_core_l2_bytes
        self.e_cores_per_l2 = e_cores_per_l2
        self.p_core_l2_bytes = p_core_l2_bytes
        self.p_cores_per_l2 = p_cores_per_l2

    # --- Defaults ------------------------------------------------------------

    @staticmethod
    def defaults() -> HardwareProfile:
        """Apple-Silicon-shaped conservative defaults.

        Used as the warn-and-fall-back result on platforms where detection
        is unavailable (e.g. sysfs missing in a hardened container).
        Mirrors the earlier engine's `defaults()` exactly, except
        that Mojo's `num_physical_cores` already returns a minimum of 1 so
        we skip the `.unwrap_or(4)` branch. `l1d_min_bytes` defaults to
        `DEFAULT_L1D_BYTES` (homogeneous-silicon shape).

        Core count comes from `_process_physical_core_count()` (the process-wide
        snapshot), NOT a live `num_physical_cores()` -- the latter is
        affinity-aware on Linux, so a thread that pinned itself would get a
        one-core profile out of this fallback ().
        """
        var cores = _process_physical_core_count()
        if cores < 1:
            cores = 4
        return HardwareProfile(
            cores,                    # physical_cores
            cores,                    # logical_cores (HT not distinguished)
            DEFAULT_L1D_BYTES,
            DEFAULT_L2_BYTES,
            DEFAULT_L3_BYTES,
            DEFAULT_CACHE_LINE,
            DEFAULT_TOTAL_RAM,
            DEFAULT_AVAILABLE_RAM,
            1,                        # numa_nodes
            DEFAULT_L1D_BYTES,        # l1d_min_bytes (homogeneous fallback)
            DEFAULT_E_CORE_L2_BYTES,  # e_core_l2_bytes
            DEFAULT_E_CORES_PER_L2,   # e_cores_per_l2
            DEFAULT_P_CORE_L2_BYTES,  # p_core_l2_bytes
            DEFAULT_P_CORES_PER_L2,   # p_cores_per_l2
        )

    # --- Morsel-sizing formulas (v0.3 parity) --------------------------------

    def optimal_morsel_rows(self, schema: Schema) -> Int:
        """Rows per morsel for general (non-agg) paths.

        Formula: `(L2 / 2) / row_width`, clamped to `[1024, 131072]`.
        The `/2` leaves room for operator state (hash tables, accumulators)
        in L2.

        `schema` must be the POST-PROJECTION schema (what actually flows
        through the segment), not the source file schema.
        """
        var row_width = schema.row_width_bytes()
        var target_bytes = self.l2_cache_bytes // 2
        var rows = target_bytes // row_width
        return _clamp(rows, MIN_MORSEL_ROWS, MAX_MORSEL_ROWS)

    def optimal_agg_morsel_rows(self, schema: Schema) -> Int:
        """Rows per morsel for aggregation operators.

        Formula: `(L1d / 2) / row_width`, clamped to `[2048, 16384]`.
        Aggregation operators carry a large HT in L2/L3; the morsel must fit
        in L1d so keys+values stay hot while HT probes run. v0.3 fidelity:
        `HardwareProfile::optimal_agg_morsel_rows` (hardware.rs:140-148).

        `schema` is the agg input schema (grouping keys + measure columns).
        """
        var row_width = schema.row_width_bytes()
        var target_bytes = self.l1d_cache_bytes // 2
        var rows = target_bytes // row_width
        return _clamp(rows, MIN_AGG_MORSEL_ROWS, MAX_AGG_MORSEL_ROWS)

    def l3_resident_rows(self, entry_bytes: Int) -> Int:
        """Hash-table row count that fits in 60% of L3.

        Returns `L3_FALLBACK_ROWS` when L3 is absent (Apple Silicon).
       
        """
        if self.l3_cache_bytes == 0:
            return L3_FALLBACK_ROWS
        var denom = entry_bytes
        if denom < 1:
            denom = 1
        return (self.l3_cache_bytes * 6 // 10) // denom

    def compute_threads(self) -> Int:
        """Number of compute worker threads = `max(physical_cores, 1)`.  Matches DuckDB / DataFusion /
        Polars (use all physical cores; OS scheduler handles pre-emption).
        """
        if self.physical_cores < 1:
            return 1
        return self.physical_cores

    def io_threads(self) -> Int:
        """I/O thread count for async Parquet reads"""
        return self.logical_cores

    def default_memory_budget(self) -> Int:
        """70% of available RAM."""
        return self.available_ram_bytes * 7 // 10

    # --- E-CORE-L2 HW MORSEL SIZING accessor --------------------

    def effective_e_core_l2_per_worker(self) -> Int:
        """Per-worker share of the BINDING L2 instance -- the single number
        every morsel/grain formula in the engine is sized against.

            = e_core_l2_bytes / max(e_cores_per_l2, 1)

        Both operands describe the SAME L2 instance (see the field comments):
        on Linux, the instance with the smallest per-worker share in the
        process's allowed CPU set (`l2_share.mojo`); on macOS, the perflevel1
        (E-tier) pair. Sizing to the smallest share makes ONE global grain
        residency-safe on EVERY core, which is the requirement -- there is one
        grain, not one per tier .

        Worked values:
          * i7-14700K: the E cluster, 4 MiB / 4 physical cores = 1 MiB.
            (The pre single-tier reading answered 2 MiB -- cpu0's
            PRIVATE P-core L2 with no divisor -- i.e. 2x too large.)
          * M3 Ultra: perflevel1, 4 MiB / 4 = 1 MiB.

        Fallback chain (each step conservative, never raises):
          * `e_core_l2_bytes == 0` (perflevel key absent — homogeneous Intel
            Mac) -> fall back to `l2_cache_bytes` (which is itself the E-core
            value on heterogeneous Apple Silicon).
          * `l2_cache_bytes == 0` (pathological) -> `DEFAULT_E_CORE_L2_BYTES`.
          * `e_cores_per_l2 <= 0` -> divisor 1 (whole-L2 budget; the per-tier
            MIN/MAX clamps then bound the row count).

        Returns BYTES (the per-worker L2 share), NOT rows. The caller applies
        the budget fraction + per-row-width division + clamps.
        """
        var l2 = self.e_core_l2_bytes
        if l2 <= 0:
            l2 = self.l2_cache_bytes
        if l2 <= 0:
            l2 = DEFAULT_E_CORE_L2_BYTES
        var divisor = self.e_cores_per_l2
        if divisor < 1:
            divisor = 1
        return l2 // divisor

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "HardwareProfile(physical_cores=", self.physical_cores,
            ", logical_cores=", self.logical_cores,
            ", l1d=", self.l1d_cache_bytes,
            ", l1d_min=", self.l1d_min_bytes,
            ", l2=", self.l2_cache_bytes,
            ", l3=", self.l3_cache_bytes,
            ", cache_line=", self.cache_line_bytes,
            ", total_ram=", self.total_ram_bytes,
            ", available_ram=", self.available_ram_bytes,
            ", numa_nodes=", self.numa_nodes,
            ", e_core_l2=", self.e_core_l2_bytes,
            ", e_cores_per_l2=", self.e_cores_per_l2,
            ", p_core_l2=", self.p_core_l2_bytes,
            ", p_cores_per_l2=", self.p_cores_per_l2,
            ")",
        )



# =============================================================================
# Internal: clamp helper
# =============================================================================

def _clamp(value: Int, lo: Int, hi: Int) -> Int:
    """Clamp `value` into `[lo, hi]`. Mirrors Rust's `.clamp()`."""
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value

