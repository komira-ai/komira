# =============================================================================
# komira_log.levels — log levels + the comptime compile-time floor.
# =============================================================================
#
# The 5 canonical severity levels (tracing / log4j / slog convention) plus an
# OFF sentinel. Levels are plain `UInt8` so they live in an `Atomic[uint8]`
# level word (the runtime gate) and a comptime `UInt8` parameter
# (the compile-time floor).
#
# TWO floors deliver the "disabled log is ~free" property (P1 + P2 identical):
#   1. COMPTIME FLOOR (`MIN_COMPILED_LEVEL`) — a `comptime if level < FLOOR:
#      return` in the facade deletes a below-floor site to ZERO instructions
#      (NanoLog / `tracing` `max_level_*`). A release build with FLOOR=INFO
#      compiles every TRACE/DEBUG site to nothing.
#   2. RUNTIME GATE — an `Atomic[uint8]` relaxed load + branch (~1-2ns) for the
#      enabled-level-but-filtered-per-module path.
#
# This module is pure POD + comptime; no FFI, no heap, no unsafe.
# =============================================================================


# -----------------------------------------------------------------------------
# The level values. Lower = more verbose. A site at `level` is emitted iff
# `effective_level <= level`-comparison is INVERTED from intuition: a record's
# level must be >= the configured threshold. We store thresholds and record
# levels in the same scale; the gate is `record_level >= effective_threshold`.
# -----------------------------------------------------------------------------

comptime LEVEL_TRACE: UInt8 = 0
comptime LEVEL_DEBUG: UInt8 = 1
comptime LEVEL_INFO: UInt8 = 2
comptime LEVEL_WARN: UInt8 = 3
comptime LEVEL_ERROR: UInt8 = 4
# OFF is a threshold only (never a record level): a module set to OFF suppresses
# everything because no record level (0..4) is >= 5.
comptime LEVEL_OFF: UInt8 = 5


# -----------------------------------------------------------------------------
# The COMPTIME compile-time floor.
#
# Sites with `level < MIN_COMPILED_LEVEL` are deleted by the compiler (the
# facade's leading `comptime if level < MIN_COMPILED_LEVEL: return`). Default
# TRACE (0) keeps every site live; a release build overrides this to INFO via
# a `-D` or a per-build constant edit. P1 ships the default-keep-all floor; the
# mechanism is identical in P2.
#
# NOTE: Mojo has no `-D`-style comptime override into a library
# constant, so the floor is edited here for a release cut. The facade consults
# THIS symbol so the swap is a one-line change with no call-site churn.
# -----------------------------------------------------------------------------

comptime MIN_COMPILED_LEVEL: UInt8 = LEVEL_TRACE


# -----------------------------------------------------------------------------
# Default global threshold when no log-level directive is supplied. INFO is the operations
# default (TRACE/DEBUG suppressed unless asked for).
# -----------------------------------------------------------------------------

comptime DEFAULT_GLOBAL_LEVEL: UInt8 = LEVEL_INFO


@always_inline
def level_name(level: UInt8) -> StaticString:
    """Uppercase 5-char-padded-ish level name for the rendered line.

    Returns a `StaticString` (no allocation) for the layout's `{LEVEL}` field.
    """
    if level == LEVEL_TRACE:
        return "TRACE"
    elif level == LEVEL_DEBUG:
        return "DEBUG"
    elif level == LEVEL_INFO:
        return "INFO"
    elif level == LEVEL_WARN:
        return "WARN"
    elif level == LEVEL_ERROR:
        return "ERROR"
    elif level == LEVEL_OFF:
        return "OFF"
    return "?"


def parse_level(name: String) -> Optional[UInt8]:
    """Parse a level name (case-insensitive) → its `UInt8`.

    Accepts the long names (`trace`/`debug`/`info`/`warn`/`error`/`off`) and
    the common short alias `warning` → WARN. Returns `None` for an
    unrecognized token so the env parser can report a malformed entry instead
    of silently defaulting.
    """
    var lc = name.lower()
    if lc == "trace":
        return Optional[UInt8](LEVEL_TRACE)
    elif lc == "debug":
        return Optional[UInt8](LEVEL_DEBUG)
    elif lc == "info":
        return Optional[UInt8](LEVEL_INFO)
    elif lc == "warn" or lc == "warning":
        return Optional[UInt8](LEVEL_WARN)
    elif lc == "error":
        return Optional[UInt8](LEVEL_ERROR)
    elif lc == "off":
        return Optional[UInt8](LEVEL_OFF)
    return Optional[UInt8]()
