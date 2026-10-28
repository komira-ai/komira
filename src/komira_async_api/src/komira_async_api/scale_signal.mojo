# =============================================================================
# komira_async_api/scale_signal.mojo
#   The `ScaleSignal` TRAIT DECLARATION — and nothing else.
# =============================================================================
#
# WHY THIS FILE IS *ONLY* THE DECLARATION
# -----------------------------------------------------------------------------
# `ScaleSignal` is the ONE control-signal trait of the engine's scaling
# model. It is deliberately DOMAIN-FREE: every method returns a POD scalar, it
# names no type from any other package, and it exists so that N domain-native
# conformers (streaming lag, batch deadline, request-tier p99, CAS
# contention) can be driven by ONE controller.
#
# The `StreamingSourceLag` conformer, the `GovernorDecision` POD and the
# `MicroBatchGovernor` controller belong in the engine operators package —
# `StreamingSourceLag` is built from a morsel-source `BacklogReading` — but
# the TRAIT does not: declaring it there would make every out-of-engine
# conformer's package import the engine.
#
# DO NOT MOVE THE CONFORMERS HERE. The engine-side module imports the
# streaming-source `BacklogReading`, which imports the core morsel type; a
# moved module carries its own imports, so it would land outside the engine
# and still *reach* it. Splitting the trait out is what severs the edge.
#
# THIS FILE MUST STAY IMPORT-FREE. The core packages has no package dependencies
# beyond the standard library and `komira_libc`, and that is load-bearing
# (core is upstream of nearly everything). A trait that names another
# package's type would have to move back out.
#
# Consumers: the engine operators' `StreamingSourceLag` /
# `MicroBatchGovernor[Signal: ScaleSignal]`, and an adaptive index-sharding
# conformer (`CasContentionSignal`).
# =============================================================================


# =============================================================================
# ScaleSignal — the ONE control-signal trait.
# =============================================================================
#
# Every conformer (StreamingSourceLag, BatchProgressVsSlo, HttpFrontLatency,
# HttpWalConsumerLag) implements this signature so the controller is written
# ONCE. StreamingSourceLag is the implemented conformer.
# =============================================================================


trait ScaleSignal(Copyable, Movable, Deinitable):
    """The ONE control-signal trait the scaling controller is written
    against. Domain-native conformers (streaming lag / batch deadline /
    request p99) all conform so the controller never names a concrete signal.

    The demand-side signals only — `pressure()` / `pressure_trend()` say HOW FAR
    BEHIND the domain is and WHICH WAY it is trending. The supply-side park-ratio
    is DELIBERATELY NOT here: it is a pool property the controller reads
    separately and ANDs with these.

    The four methods:
        pressure() -> Float64
            1.0 == keeping up; > 1.0 == behind (want more capacity); < 1.0 ==
            spare (can shed). For streaming: `outstanding / lag_budget`.
        pressure_trend() -> Float64
            d(pressure)/dt: > 0 == falling behind, < 0 == catching up, ~0 ==
            steady. Drives the oscillation damping (grow when behind and NOT
            catching up — trend >= 0; a falling trend holds).
        skew_locus() -> Optional[UInt32]
            `Some(pid)` => the pressure is concentrated on ONE partition with one
            dominant key — relieve by SALTING, not scale-out. `None` =>
            uniform pressure that scale-out CAN relieve. Single-process
            streaming with no partition fan-out always returns `None`.
        cold_start_floor() -> Int64   (MICROSECONDS)
            The cooldown floor: a freshly-added unit is not useful until this
            elapses (a reducer must seal-block + range-GET before it is
            productive). The controller's cooldown is >= this. MICROS and
            not a `Duration` struct — the available `Duration` is the
            protobuf WKT (heavyweight, and semantically a wall-clock span, not a
            monotonic cooldown floor); the idiom for a monotonic
            interval is a plain `Int64` of micros.

    ENCAPSULATION: every method returns a POD scalar / `Optional[UInt32]`; no
    pointer, no wildcard. `Copyable` so a signal threads freely into the
    controller per step."""

    def pressure(self) -> Float64:
        """1.0 == keeping up; > 1.0 == behind; < 1.0 == spare."""
        ...

    def pressure_trend(self) -> Float64:
        """D(pressure)/dt — drives the oscillation damping (grow when behind and
        trend >= 0; a falling trend holds)."""
        ...

    def skew_locus(self) -> Optional[UInt32]:
        """`Some(pid)` => salt (concentrated skew); `None` => uniform, scale-out
        can relieve."""
        ...

    def cold_start_floor(self) -> Int64:
        """The cooldown floor in MICROSECONDS (see the class
        docstring for why micros and not a `Duration` struct)."""
        ...
