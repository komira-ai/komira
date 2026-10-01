# =============================================================================
# komira_log.config — the process-global P1 logging config + ambient holder.
# =============================================================================
#
# P1 is synchronous + stateless-per-call (format + write), so it needs only a
# process-global config: the per-module level filter, a global-level atomic
# (the relaxed runtime gate), and the stderr sink (+ its write lock). NOT the
# full per-core-ring engine (that is P2).
#
# # The ambient-reach seam (P1 → P2 STABLE)
#
# The facade's bare `log.info[fmt, module](*args)` must reach this config from
# ANY call site with no `ctx`/handle threaded through. Mojo has NO first-class
# mutable module-globals, so the config is a HEAP singleton whose address is
# parked in a one-word C linker-global (`engine/_log_holder_shim.c`, the same
# file that parks the P2 engine's address), reached via `external_call`.
#
# In P2 the engine holder points at the service-owned engine instead of the P1
# LogConfig — the facade resolves a holder the SAME way, so the call sites are
# byte-identical across P1 and P2:
#   P1: config holder → LogConfig (level filter + sync stderr sink)
#   P2: engine holder → SharedEngine (per-core rings + drain)
# Only the facade's enabled-body backend changes; the gate + call sites do not.
#
# # CONFIGURATION IS SUPPLIED BY THE CALLER, NEVER READ FROM THE ENVIRONMENT
#
# A binary parses its `--log-level=<spec>` (and `--log-format`, plus the
# deployer-set "running on a deployed platform" fact) at startup and passes
# them to `init_logging_from_spec`. A flag is parsed before the first line is
# written, so an unsupplied required value can be refused by the binary's own
# parser, and `--log-level=` is distinguishable from omitting it. A process
# that never initialises gets the built-in default (INFO, text layout) on its
# first log call, and the startup banner says so.
#
# # SAFETY (the process-static singleton)
#
# The config slot is heap-allocated ONCE at init and intentionally leaked for
# process lifetime. It outlives every possible logging call site (logging
# happens only while the process is live), so there is no destroy-recreate
# cycle and no stale-pointer hazard. The parked value is a POD integer address
# (no wildcard-origin FIELD); the `unsafe_from_address` cast is the documented
# singleton exception, confined to `_resolve_config()` below.
#
# `LogConfig` itself holds `EnvFilter` (heap) + `StderrSink` (atomic) + an
# `Atomic[uint8]` global level. It is NEVER stored in a byte-backed slab — it
# lives in its own `alloc[LogConfig](1)` heap slot.
# =============================================================================

from std.ffi import external_call
from komira_atomic_alias import AtomicU8
from std.memory import alloc, UnsafePointer
from std.memory import OwnedPointer

from komira_log.levels import DEFAULT_GLOBAL_LEVEL, LEVEL_OFF, level_name
from komira_log.env_filter import (
    EnvFilter,
    LOG_SPEC_FLAG,
    LOG_SPEC_SOURCE_DEFAULT,
    LOG_SPEC_SOURCE_FLAG,
)
from komira_log.pattern_layout import select_log_layout
from komira_log.stderr_sink import StderrSink


# -----------------------------------------------------------------------------
# The process-global config. ONE instance per process, reached ambiently.
# -----------------------------------------------------------------------------


struct LogConfig(Movable):
    """P1 process-global logging config: filter + global gate + sink."""

    # The relaxed-atomic global level gate. The facade reads this first (one
    # relaxed load + branch) before consulting the per-module filter — so the
    # common "globally below threshold" path is the cheap atomic, and the
    # per-module longest-prefix walk only runs when the global gate admits.
    # SAFETY: Atomic is non-Movable; heap-own via OwnedPointer.
    var _global_level: OwnedPointer[AtomicU8]
    var _filter: EnvFilter
    var _sink: StderrSink
    # Whether logging is enabled at all (set False to make every call a no-op
    # without uninstalling — useful for tests).
    var _enabled: Bool

    def __init__(out self, var filter: EnvFilter):
        var raw = alloc[AtomicU8](1)
        raw[] = AtomicU8(filter.global_level)
        self._global_level = OwnedPointer[AtomicU8](
            unsafe_from_raw_pointer=raw
        )
        self._filter = filter^
        self._sink = StderrSink()
        self._enabled = True

    @always_inline
    def global_level(self) -> UInt8:
        """Relaxed load of the global threshold (the cheap first gate)."""
        return self._global_level[].load()

    def set_global_level(mut self, level: UInt8):
        """Runtime reconfiguration of the global threshold (relaxed store)."""
        AtomicU8.store(
            UnsafePointer(to=self._global_level[]).unsafe_bitcast[
                Scalar[DType.uint8]
            ](), level
        )

    @always_inline
    def enabled(self) -> Bool:
        return self._enabled

    def set_enabled(mut self, on: Bool):
        self._enabled = on

    def effective_level(self, module: StaticString) -> UInt8:
        """Resolve a module's effective threshold (per-module override or
        global default)."""
        return self._filter.effective_level(module)

    @always_inline
    def filter_rule_count(self) -> Int:
        """Per-module override rules parsed from the log-level directive. Zero is the
        common case and the one `admits` is optimised for."""
        return self._filter.num_rules()

    @always_inline
    def admits(self, level: UInt8, module: StaticString) -> Bool:
        """Is a record at `level` from `module` admitted? THE gate.

        The P1 twin of `SharedEngine.admits`, with the identical contract and
        for the identical reason — see that docstring for the full account.
        In short: the global level and the per-module rules are ONE gate, not
        two sequential vetoes, so a per-module rule can LOWER a module's
        threshold as well as raise it. That is what makes
        `--log-level=info,komira_pg=debug` — the spelling of "turn DEBUG on
        for one module" — work.

        THE CONTRACT: the effective threshold is the longest-prefix
        per-module rule if one matches, and the runtime global level
        otherwise. A matching rule governs whether it raises or lowers.

        ⚠ THIS TWIN EXISTS BECAUSE THE TWO BACKENDS ARE SEPARATE STRUCTS, NOT
        BECAUSE THE RULE DIFFERS. If one is ever changed the other must move
        with it — `test_log_effective_level_resolution.mojo` pins the engine
        side and `test_log_p1.mojo` the config side.
        """
        var g = self._global_level[].load()
        if self._filter.num_rules() == 0:
            return level >= g
        var m = self._filter.effective_level(module)
        if m == self._filter.global_level:
            return level >= g
        return level >= m

    def write_line(mut self, line: String):
        """Hand a fully-rendered line to the thread-safe stderr sink."""
        self._sink.write_line(line)


# -----------------------------------------------------------------------------
# The process-static holder: park / resolve the LogConfig heap-slot address.
# The cell is `komira_log_config_holder_*` in `engine/_log_holder_shim.c`.
# -----------------------------------------------------------------------------


@always_inline
def _config_holder_get() -> Int:
    """Read the parked LogConfig address (0 == none installed)."""
    return Int(external_call["komira_log_config_holder_get", UInt64]())


def _install_config(var config: LogConfig):
    """Heap-leak `config` and park its address in the process-global cell.

    Idempotent at the API level: `init_*` callers gate on `is_installed()`
    first so the slot is built exactly once. SAFETY: the heap slot is an
    intentional process-lifetime leak (never freed).
    """
    var slot = alloc[LogConfig](1)
    slot.unsafe_write(config^)
    external_call["komira_log_config_holder_set", NoneType](
        UInt64(Int(slot))
    )


def is_installed() -> Bool:
    """True iff a LogConfig has been installed in this process."""
    return _config_holder_get() != 0


@always_inline
def _resolve_config() -> UnsafePointer[LogConfig, MutUntrackedOrigin]:
    """Recover the process-global LogConfig pointer from the parked address.

    SAFETY: documented singleton exception for a process-lifetime heap slot.
    The parked integer is the heap-slot address from a prior `_install_config`
    in this same process; the slot outlives every caller (intentional leak).
    Returns a null-address pointer when no config is installed; callers (the
    facade) MUST check `is_installed()` before deref. The untracked origin is
    confined to this one resolve site.
    """
    return UnsafePointer[LogConfig, MutUntrackedOrigin](
        unsafe_from_address=_config_holder_get()
    )


# =============================================================================
# THE STARTUP LINE — what this process resolved, and WHERE FROM.
#
# IT NAMES THE SOURCE, NOT JUST THE LEVEL, AND THE SOURCE IS THE POINT.
# `level=INFO` alone is byte-identical between "an operator asked for INFO" and
# "nobody configured anything", and a service stuck at the built-in floor with
# no way to tell why is exactly the failure this line exists to expose.
#
# PURE, and returning LINES rather than writing them, for one reason: the
# assertion a test wants to make is about the SENTENCE, and a function that
# writes to a fd can only be tested by capturing a fd. The init functions write
# what this returns.
# =============================================================================


def log_config_banner_lines(
    filter: EnvFilter, source: String, spec: String
) -> List[String]:
    """ONE line stating level / source / spec / override count, plus a SECOND
    line iff the directive carried tokens that were rejected.

    The malformed report is its own line rather than a suffix: an operator greps
    for the status or for the complaint, and a line that is sometimes twice as
    long is a line nobody can grep for reliably. Two lines also means the
    complaint survives a truncating log viewer that would have eaten a tail."""
    var out = List[String]()

    var shown_spec = (
        String(' spec="') + spec + String('"') if spec.byte_length() > 0
        else String("")
    )
    var line = (
        String("komira_log: level=")
        + String(level_name(filter.global_level))
        + String(" source=")
        + source
        + shown_spec
        + String(" module_overrides=")
        + String(filter.num_rules())
    )
    # THE DEAD-END GUARD. A level with no instruction tells an operator what is
    # happening and not what to do about it, which is most of why this line is
    # worth printing at all.
    if spec.byte_length() == 0:
        line += (
            String(" — pass ")
            + String(LOG_SPEC_FLAG)
            + String("=debug (or `info,<module>=debug`) to change it")
        )
    out.append(line^)

    var bad = filter.malformed_report()
    if bad.byte_length() > 0:
        out.append(
            String("komira_log: IGNORED ")
            + String(filter.num_malformed())
            + String(" malformed directive token(s): ")
            + bad
            + String(
                " — a token is a level name (trace|debug|info|warn|error|off)"
                " or `module=level`. The level above is what actually took"
                " effect; the rejected tokens changed NOTHING."
            )
        )
    return out^


def _emit_banner(var lines: List[String]):
    """Write the banner through the config that was just installed, so it lands
    on the same fd, behind the same lock, as every line that follows it.

    ⛔ NOT `print()`. `print` goes to STDOUT and this logger writes STDERR; on
    Cloud Run those are two different `logName`s that interleave by arrival
    time, so the banner would routinely appear detached from the lines it
    explains."""
    # `is_installed()` rather than a null test on the pointer: `UnsafePointer` is
    # non-null BY DESIGN in Mojo, so `if not cfg` does not compile. The
    # holder's own predicate is the check that means what we want anyway — "did
    # the install we just performed actually land".
    if not is_installed():
        return
    var cfg = _resolve_config()
    for i in range(len(lines)):
        cfg[].write_line(lines[i])


# -----------------------------------------------------------------------------
# Public init. Call ONCE at program start (the binary's `main`, after it parsed
# its flags). If never called, the facade auto-inits the built-in default
# config on first use (so a log call from code that forgot to init still works
# — the lazy-init path).
# -----------------------------------------------------------------------------


def _install_from_spec(var spec: String, var source: String):
    """Build the filter for `spec`, install it, and announce it."""
    var filter = (
        EnvFilter() if spec.byte_length() == 0 else EnvFilter(spec.copy())
    )
    var lines = log_config_banner_lines(filter, source.copy(), spec.copy())
    _install_config(LogConfig(filter^))
    _emit_banner(lines^)


def init_logging():
    """Initialize the process-global logger with the built-in default (global
    level INFO, no per-module overrides) and ANNOUNCE that nothing configured
    it.

    Idempotent: a second call is a no-op (the first install wins), and the
    banner is emitted exactly once, by the call that installed.
    """
    if is_installed():
        return
    _install_from_spec(String(""), String(LOG_SPEC_SOURCE_DEFAULT))


def init_logging_from_spec(
    var spec: String,
    var source: String,
    log_format: String = String(""),
    on_deployed_platform: Bool = False,
):
    """Initialize from configuration the CALLER resolved — the flag path.

    A binary parses `--log-level=<spec>` and passes the value plus a `source`
    naming where it came from; `LOG_SPEC_SOURCE_FLAG` is the spelling to pass
    for the flag itself. `log_format` is the binary's `--log-format` value
    (`json` / `text`, empty when not supplied) and `on_deployed_platform` is the
    deployer-set fact; together they select the line layout
    (`pattern_layout.select_log_layout`). A flag is parsed at STARTUP, so an
    unsupplied value can be REFUSED by the binary's own parser before the first
    line is written, and `--log-level=` is distinguishable from omitting it.

    The layout is selected on EVERY call, before the install guard, so it does
    not depend on init order: a process that wrote a line first (which lazily
    installs the default filter) or called `init_logging()` first still gets
    the layout its flags ask for. The filter install is idempotent, like every
    other init here: the first install wins.

    A binary that builds its own `EnvFilter` (and calls `init_logging_with` or
    owns its engine) must call `pattern_layout.select_log_layout` itself;
    without that call the layout stays text."""
    select_log_layout(log_format, on_deployed_platform)
    if is_installed():
        return
    _install_from_spec(spec^, source^)


def init_logging_with(var filter: EnvFilter):
    """Initialize with an explicit filter (the programmatic-config path /
    tests). Idempotent.

    DELIBERATELY SILENT — no banner. The caller built the filter itself, so it
    already knows what it configured, and this is the path most komira_log
    tests take; a banner here would put a line into every one of their outputs
    to state something the test source already says."""
    if is_installed():
        return
    _install_config(LogConfig(filter^))


def _ensure_config() -> UnsafePointer[LogConfig, MutUntrackedOrigin]:
    """Resolve the config, lazily initializing the built-in default if none is
    installed.

    This is the facade's reach: a bare `log.info(...)` from un-init'd code
    still works (builds a default INFO-level stderr logger). SAFETY: see
    `_resolve_config`.

    IT BANNERS, AND THAT IS NOT AN EXTRA: a process that never calls an
    `init_*` arrives here on its first `log.*` call, and a banner only on the
    explicit path would never reach it."""
    if not is_installed():
        _install_from_spec(String(""), String(LOG_SPEC_SOURCE_DEFAULT))
    return _resolve_config()
