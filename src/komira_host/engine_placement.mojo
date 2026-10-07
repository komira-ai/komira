# =============================================================================
# EnginePlacement — worker/driver CPU placement policy
# =============================================================================
#
# The placement policy for the engine thread pools, as one plain value. The
# embedding program sets it (for example from its command-line flags) on its
# `EngineConfig`; the runtime stores it at construction and passes it to the
# `engine_*` topology functions in `cpu_topology`. Nothing reads placement
# from the process environment.
#
# `EnginePlacement()` is every policy off: unpinned workers, no IO lane, no
# NUMA restriction, no reserved driver CPU.
#
# This module imports nothing from the core packages, so `runtime` stays a leaf
# that `engine_config` can depend on.
# =============================================================================


struct EnginePlacement(ImplicitlyCopyable, Copyable, Movable, Equatable, Writable):
    """Worker/driver CPU placement policy for the engine thread pools.

    Fields:
        pin_workers: Pin compute worker k to `engine_compute_cpus(p)[k]`.
        io_lane: Derive a separate IO lane (`derive_io_placement`).
        numa_local: Restrict every lane to one NUMA node.
        reserve_driver_cpu: Reserve one CPU for the driver thread. Takes
            effect only together with `pin_workers` (see `driver_reserved`).
    """

    var pin_workers: Bool
    var io_lane: Bool
    var numa_local: Bool
    var reserve_driver_cpu: Bool

    def __init__(
        out self,
        *,
        pin_workers: Bool = False,
        io_lane: Bool = False,
        numa_local: Bool = False,
        reserve_driver_cpu: Bool = False,
    ):
        """Build a placement policy; every policy defaults to off."""
        self.pin_workers = pin_workers
        self.io_lane = io_lane
        self.numa_local = numa_local
        self.reserve_driver_cpu = reserve_driver_cpu

    def driver_reserved(self) -> Bool:
        """True iff a driver CPU is reserved.

        A reservation only means something when workers are pinned: an
        unpinned pool can be scheduled onto the "reserved" CPU anyway.
        """
        return self.pin_workers and self.reserve_driver_cpu

    def __eq__(self, other: Self) -> Bool:
        return (
            self.pin_workers == other.pin_workers
            and self.io_lane == other.io_lane
            and self.numa_local == other.numa_local
            and self.reserve_driver_cpu == other.reserve_driver_cpu
        )

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "EnginePlacement(pin_workers=",
            self.pin_workers,
            ", io_lane=",
            self.io_lane,
            ", numa_local=",
            self.numa_local,
            ", reserve_driver_cpu=",
            self.reserve_driver_cpu,
            ")",
        )
