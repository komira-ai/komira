# =============================================================================
# host_detect -- measure this host once and build its HostProfile
# =============================================================================
#
# `detect_host_profile` is the one place a host process measures itself: it
# probes the hardware once (`hardware_detect.detect_hardware_profile`) and
# fills the rest from the caller's configuration, which arrives as flags, not
# environment variables. The value it returns is `komira_host_profile.
# host_profile.HostProfile`; everything downstream (morsel sizing, worker
# counts, memory budgets) takes that value as an argument and never probes
# again.
# =============================================================================

from komira_engine_runtime.hardware_detect import detect_hardware_profile
from komira_host_profile.host_profile import (
    HostProfile,
    SPILL_TIER_LOCAL_DISK,
)


def detect_host_profile(
    var engine_build: String,
    thread_count: Int = 0,
    memory_budget_bytes: Int = 0,
    spill_tiers: UInt8 = SPILL_TIER_LOCAL_DISK,
) raises -> HostProfile:
    """Measure this host once and build its profile.

    `thread_count` and `memory_budget_bytes` come from the host's flags; 0
    means "derive from the hardware" (`compute_threads()` and
    `default_memory_budget()`). This is the only function in the engine that
    probes the machine; call it once per host process and pass the value on.
    """
    var hw = detect_hardware_profile()
    var threads = thread_count if thread_count > 0 else hw.compute_threads()
    var budget = memory_budget_bytes
    if budget <= 0:
        budget = hw.default_memory_budget()
    if budget < 1:
        budget = 1
    return HostProfile(engine_build^, hw^, threads, budget, spill_tiers)
