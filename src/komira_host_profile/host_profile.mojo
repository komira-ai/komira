# =============================================================================
# host_profile -- what a host is, measured once, then only read
# =============================================================================
#
# Lowering is a function `lower(segment, host_profile, resolved_inputs) ->
# PhysicalPlan`. This module is its `host_profile` argument: the engine build,
# the hardware shape, the worker thread count, the memory budget and the spill
# tiers the host offers.
#
# This package holds the value only. `komira_engine_runtime.host_detect.
# detect_host_profile` is the one place a host process measures itself: it
# probes the hardware once and fills the rest from the caller's configuration,
# which arrives as flags, not environment variables. Everything downstream
# (morsel sizing, worker counts, memory budgets) takes the resulting value as
# an argument, so it is a pure function of the profile and never probes again.
#
# `reference_host_profile` is a profile with no measured field at all. Two
# hosts produce byte-equal physical plans only under equal profiles, so a check
# that compares rendered plans across machines lowers under this one.
# =============================================================================

from komira_host_profile.hardware import HardwareProfile


# =============================================================================
# Spill tiers (a bit set)
# =============================================================================
#
# A host offers some tiers; a breaker in the physical plan declares which of
# them it may spill to. The breaker's effective set is the intersection
# (`HostProfile.spill_tiers_for`), and an empty set means it may not spill.
# Spill is never a checkpoint.

comptime SPILL_TIER_NONE: UInt8 = 0
comptime SPILL_TIER_LOCAL_DISK: UInt8 = 1
comptime SPILL_TIER_OBJECT_STORE: UInt8 = 2
comptime SPILL_TIER_ALL: UInt8 = SPILL_TIER_LOCAL_DISK | SPILL_TIER_OBJECT_STORE


# The reference profile's hardware: an 8-core part with a 4 MiB L2 shared by
# 4 cores, 32 KiB L1d, 16 GiB of RAM. Constants, so the profile is the same on
# every machine.
comptime _REF_CORES: Int = 8
comptime _REF_L1D_BYTES: Int = 32 * 1024
comptime _REF_L2_BYTES: Int = 4 * 1024 * 1024
comptime _REF_L3_BYTES: Int = 0
comptime _REF_CACHE_LINE: Int = 64
comptime _REF_TOTAL_RAM: Int = 16 * 1024 * 1024 * 1024
comptime _REF_AVAILABLE_RAM: Int = 8 * 1024 * 1024 * 1024
comptime _REF_CORES_PER_L2: Int = 4


struct HostProfile(Copyable, Movable, Writable):
    """The executor host's lowering input: build, hardware, threads, memory and
    spill tiers. Built once per host process, then passed by value."""

    var engine_build: String
    """The engine build identifier the host runs (part of the plan's identity:
    two builds may lower one segment differently)."""
    var hardware: HardwareProfile
    """The CPU, cache and memory shape, measured once."""
    var thread_count: Int
    """Compute worker threads. At least 1."""
    var memory_budget_bytes: Int
    """The bytes the host's operators may reserve in total. At least 1."""
    var spill_tiers: UInt8
    """The `SPILL_TIER_*` bits this host offers."""

    def __init__(
        out self,
        var engine_build: String,
        var hardware: HardwareProfile,
        thread_count: Int,
        memory_budget_bytes: Int,
        spill_tiers: UInt8,
    ) raises:
        """A profile from explicit values. Raises on a thread count or memory
        budget below 1, or a spill tier bit this build does not know."""
        if thread_count < 1:
            raise Error(
                "HOST_PROFILE_INVALID: thread_count must be >= 1, got "
                + String(thread_count)
            )
        if memory_budget_bytes < 1:
            raise Error(
                "HOST_PROFILE_INVALID: memory_budget_bytes must be >= 1, got "
                + String(memory_budget_bytes)
            )
        if (spill_tiers & ~SPILL_TIER_ALL) != 0:
            raise Error(
                "HOST_PROFILE_INVALID: unknown spill tier bits "
                + String(Int(spill_tiers))
            )
        self.engine_build = engine_build^
        self.hardware = hardware^
        self.thread_count = thread_count
        self.memory_budget_bytes = memory_budget_bytes
        self.spill_tiers = spill_tiers

    def spill_tiers_for(self, declared: UInt8) -> UInt8:
        """The tiers a breaker that declared `declared` may spill to here: the
        intersection with what the host offers."""
        return declared & self.spill_tiers

    def may_spill(self, declared: UInt8) -> Bool:
        """True when a breaker that declared `declared` may spill on this host."""
        return self.spill_tiers_for(declared) != SPILL_TIER_NONE

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "HostProfile(engine_build=", self.engine_build,
            ", threads=", self.thread_count,
            ", memory_budget=", self.memory_budget_bytes,
            ", spill_tiers=", Int(self.spill_tiers),
            ", ", self.hardware,
            ")",
        )


def reference_host_profile(var engine_build: String) raises -> HostProfile:
    """A host profile made only of constants, identical on every machine.

    For comparing lowered plans across machines: under this profile a segment
    lowers to the same physical plan wherever it is lowered.
    """
    var hw = HardwareProfile(
        _REF_CORES,
        _REF_CORES,
        _REF_L1D_BYTES,
        _REF_L2_BYTES,
        _REF_L3_BYTES,
        _REF_CACHE_LINE,
        _REF_TOTAL_RAM,
        _REF_AVAILABLE_RAM,
        1,
        _REF_L1D_BYTES,
        _REF_L2_BYTES,
        _REF_CORES_PER_L2,
        _REF_L2_BYTES,
        _REF_CORES_PER_L2,
    )
    var budget = hw.default_memory_budget()
    return HostProfile(
        engine_build^, hw^, _REF_CORES, budget, SPILL_TIER_LOCAL_DISK
    )
