# =============================================================================
# slow_phase.mojo — the per-PHASE dial breadcrumb
# =============================================================================
#
# ⛔⛔ THIS FILE MEASURES. IT DOES NOT BOUND. READ THAT SENTENCE TWICE.
#
# ONE outbound call has FOUR phases and the authored `request_timeout_us`
# reaches exactly one of them:
#
#   | phase                                   | its bound                     |
#   |-----------------------------------------|-------------------------------|
#   | DNS `getaddrinfo` (`resolve_host_be`)   | ⛔ NOTHING                     |
#   | TCP connect                             | `_CONNECT_TIMEOUT_US`   5s    |
#   | TLS handshake                           | `_HANDSHAKE_DEADLINE…`  30s   |
#   | h1/h2 drive                             | `min(authored, 120s)`         |
#
# A service that crash-loops on dials can have each loop "closed" by tightening a budget
# while the wedge moves one call to the
# right every time, because every one of those budgets binds the DRIVE. The
# elimination that names the suspect: connect RAISES at 5s, the handshake
# RAISES at 30s, the drive RAISES at the authored budget — **DNS is the only
# phase on the path that can absorb a 180s startup probe without raising.**
#
# That is a DEDUCTION. This file exists to turn it into a PRINTED FACT, so the
# next wedged revision says which phase ate the wall instead of being argued
# about. It adds no deadline to anything.
#
# ⛔ DO NOT "UPGRADE" THIS INTO A BOUND BY CHECKING THE ELAPSED AND RAISING.
# `getaddrinfo(3)` is a BLOCKING libc call with no timeout argument and no
# cancellation. A check AROUND the resolve reports late — the thread is still
# inside libc — so it is a measurement wearing a deadline's name. See
# the DNS section of `_ip_be_from_host`.
#
# WHY `print`, NOT THE STRUCTURED LOG ENGINE
# ------------------------------------------
# Same reason a boot-sweep trace
# is a `print`: the failure being diagnosed is a process that STOPS PRODUCING
# OUTPUT during boot, before any exporter is up, and a log path that can itself
# dial cannot be trusted to report a stuck dial. Cloud Run captures stdout.
#
# WHY A THRESHOLD, AND WHY 1000 ms
# --------------------------------
# These two call sites are in the closure of essentially every binary in the
# tree, including serve loops that dial on a 5s tick. An UNCONDITIONAL per-dial
# line is its own problem. 1000 ms is argued, not picked:
#
#   * it is 20% of `_CONNECT_TIMEOUT_US` — the smallest round number at which a
#     single phase is already a material fraction of a phase this repo has
#     already decided deserves a 5s bound;
#   * it is >10x any healthy same-region resolve (tens of ms against the Cloud
#     Run metadata resolver) and >10x a healthy TLS handshake (~1 RTT);
#   * in steady state — pooled connections, no cold dial — it emits NOTHING,
#     and on a boot sweep of five public-CA hosts the entire volume is five
#     lines.
#
# It is deliberately NOT configurable. A flag would have to be threaded to a
# leaf both `client.mojo` and `tls_connector.mojo` reach from 20+ composition
# roots, and an environment variable is not configuration.
# The value is stated here, in the one place, where changing it is a diff.
#
# WHY `note_slow_phase` RETURNS A `Bool`
# -------------------------------------
# So the emit DECISION is assertable without capturing stdout. The test asserts
# both directions — below-threshold returns False (the no-spam floor) and
# at/above returns True (the ceiling: it does fire) — which is the same
# floor-AND-ceiling shape the connector wall-clock tests use. A test that only
# asserted "it does not spam" would pass on an instrument that never fires.
# =============================================================================


comptime SLOW_PHASE_THRESHOLD_MS: Int64 = 1000
"""Emit a breadcrumb only for a phase that took at least this long. See the
header for the argument behind the value; it is a wall-clock MILLISECOND
figure, and the comparison is `>=` so a phase landing exactly on it reports."""


comptime SLOW_PHASE_DNS: String = "dns"
"""`getaddrinfo` via `resolve_host_be` — the phase nothing bounds."""


comptime SLOW_PHASE_TLS_HANDSHAKE: String = "tls-handshake"
"""The s2n handshake loop's SUCCESS arm. Its FAILURE arm already reports its
own `elapsed_ms` inside `_handshake_deadline_error`, so only the arm that
COMPLETES was dark."""


def slow_phase_line(phase: String, host: String, elapsed_ms: Int64) -> String:
    """The one wire format, so a log scrape matches both call sites.

        SLOW DIAL phase=dns host=oauth2.googleapis.com ms=31004

    `phase` is one of the `SLOW_PHASE_*` constants; `host` is the DNS name or
    SNI name the phase was working on — never an IP, because the whole point of
    the DNS line is to say WHICH NAME was slow."""
    return (
        String("SLOW DIAL phase=") + phase
        + String(" host=") + host
        + String(" ms=") + String(elapsed_ms)
    )


def note_slow_phase(phase: String, host: String, elapsed_ms: Int64) -> Bool:
    """Emit `slow_phase_line` iff `elapsed_ms >= SLOW_PHASE_THRESHOLD_MS`.

    Returns whether it emitted — see the header for why that is the return
    type. Never raises: an instrument that can fail the operation it measures
    is a defect, not an instrument."""
    if elapsed_ms < SLOW_PHASE_THRESHOLD_MS:
        return False
    print(slow_phase_line(phase, host, elapsed_ms))
    return True


def elapsed_ms_since(start_ns: Int64, now_ns_value: Int64) -> Int64:
    """Whole milliseconds between two `komira_obs.clock.now_ns()` reads.

    Takes BOTH reads as arguments rather than calling the clock itself: that
    keeps this module free of a `komira_obs` import at a leaf both dial files
    reach, and — the reason that matters — makes the arithmetic testable at
    synthetic timestamps, including the non-monotonic case. A clock that goes
    BACKWARDS (it should not; `now_ns` is CLOCK_MONOTONIC / CLOCK_UPTIME_RAW)
    must not produce a giant positive from an unsigned wrap, so the negative is
    clamped to 0 rather than reported."""
    var delta_ns = now_ns_value - start_ns
    if delta_ns <= Int64(0):
        return Int64(0)
    return delta_ns // Int64(1_000_000)
