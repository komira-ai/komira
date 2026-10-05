"""`komira_log` — synchronous structured logging facade (P1).

Usage:
    import komira_log as log
    from komira_log import ArgI64, ArgStr, Field, init_logging

    # once at program start, with the binary's parsed `--log-level` value
    init_logging_from_spec(log_level_flag, String(LOG_SPEC_SOURCE_FLAG))
    log.info["job supervisor started", "komira_job_supervisor"]()
    log.info["job {} started", "komira_job_supervisor"](ArgStr(job_id))
    log.warn["upload failed: {}", "komira_job_supervisor"](ArgStr(err),
                                                   Field("attempt", ArgI64(3)))

The facade is STABLE: P2 (binary/per-core-ring/drain) swaps the backend
behind these exact call sites. See facade.mojo for the P1→P2 seam.

The five level functions — the stable call surface.
"""

from komira_log.facade import trace, debug, info, warn, error

# The log4j `getLogger("module")` ergonomic: a module-bound handle to
# the process-global immortal engine (LogManager) for context-less sites.
from komira_log.facade import get_logger, GlobalLogger

# The process-global immortal logger registry (install-once). The forever-root
# (a long-lived service) installs a SharedEngine ONCE; the ambient facade +
# get_logger resolve it.
from komira_log.engine.log_manager import LogManager

# P4b — the ambient SPAN surface (the span twin of the ambient `log.*`). Reaches
# the process-global unified engine via the same `engine_handle` borrow the
# ambient `log.info(...)` uses; a no-op when no engine is installed. This is the
# no-`ctx` reach for span sites that have no `EngineContext` to borrow a typed
# `Tracer[origin]` from (the morsel executor + the no-`ctx` compiler path).
from komira_log.facade import span_open, span_close

# The typed argument model (structured fields).
from komira_log.log_arg import (
    LogArg,
    ArgI64,
    ArgU64,
    ArgF64,
    ArgBool,
    ArgStr,
    Field,
)

# Levels (for programmatic config + comptime floor reference).
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
    LEVEL_OFF,
    MIN_COMPILED_LEVEL,
    parse_level,
    level_name,
)

# Config + init (the ambient process-global; the P1→P2 holder seam).
from komira_log.config import (
    LogConfig,
    init_logging,
    # THE FLAG PATH. A binary that parses `--log-level=<spec>` (and
    # `--log-format`, plus the deployer-set deployed-platform fact) calls this
    # with the values and `LOG_SPEC_SOURCE_FLAG`; it banners the resolution.
    init_logging_from_spec,
    init_logging_with,
    is_installed,
    log_config_banner_lines,
)

# The directive filter (programmatic-config path) + the flag name and source
# strings the banner reports.
from komira_log.env_filter import (
    EnvFilter,
    LOG_SPEC_FLAG,
    LOG_SPEC_SOURCE_DEFAULT,
    LOG_SPEC_SOURCE_FLAG,
)

# The process-wide line layout (text / Cloud-Logging JSON), selected once at
# startup from the binary's `--log-format` and the deployed-platform fact.
from komira_log.pattern_layout import select_log_layout, log_layout_is_json

# P2b engine — the binary per-core-ring backend behind the stable facade. The
# forever-root (EngineContext / a long-lived service) constructs a
# SharedEngine and installs it via the process-static handle; the facade then
# routes every `log.*` call through the per-core rings + drain. Until install,
# the facade falls back to the P1 synchronous stderr path (so a log before
# install never crashes).
from komira_log.engine.shared_engine import SharedEngine
# The forever-root installs via `LogManager.install` (immortal global,
# C-static-backed); the facade resolves `LogManager._resolve`.

# The POD-owned drain seam. A search-side consumer (`komira_log_index`) drains
# LOG records as OWNED `LogRecordView`s (scalars + interpolated message + decoded
# args) and transposes them into a typed RecordBatch OFF the engine.
# `komira_log` stays import-clean.
from komira_log.engine.log_record_view import LogRecordView

# ⭐ THE MIRROR SEAM. `drain_worker_to_records` and `drain_worker` are mutually
# exclusive (each POPS the ring), so a consumer that takes the OWNED views stops
# getting the engine's own sink output — its lines leave stderr. This renders an
# already-drained view back to the SAME text line the sink path would have
# written, so one pop can feed BOTH. See drain.mojo's header on it.
from komira_log.engine.drain import render_record_view

# P2c — the TYPED, concrete-origin logger surface. `ctx.logger.info[fmt](*args)`
# (and `service.logger.*`) reach the engine through a concrete field ref so the
# emit dispatch inlines (~1ns) instead of the ambient wildcard-handle resolve
# (~43ns). The bare module-level `log.*` above stays as the no-ctx fallback.
from komira_log.logger import Logger

# THE ERASED TWIN OF THAT SURFACE — for long-lived SERVICES only. `Logger.info`'s
# `fmt` and `*ArgTs` are comptime AND unique per call site, so each site is its
# own instantiation and (being `@always_inline`) its own expansion. `emit_erased`
# moves exactly
# those two to runtime (`fmt: StaticString`, `*args: LogValue`) while keeping
# `level` and `module` comptime, so ONE elaborated body serves every site.
# ⛔ The engine keeps `Logger`: the specialised path's ~1 ns emit is bought with
# precisely the comptime binding this drops. logger_erased.mojo has the trade.
#
# ⛔⛔ AND DO NOT MASS-CONVERT TO IT ON A COMPILE-PEAK ARGUMENT. The erasure is
# real — many sites collapse to a few bodies in the IR — but the compiler's
# PEAK RSS can go UP, not down, and more steeply with site count. Measure
# before adopting this anywhere.
from komira_log.log_value import LogValue
from komira_log.logger_erased import emit_erased, fnv1a_32_dyn

# P4a — the TYPED, concrete-origin TRACER surface. `ctx.tracer.start_span[name]
# (wid)` / `end_span(sid, wid)` reach the engine's UNIFIED span path through the
# same concrete field ref `Logger` uses, so the span emit inlines. A span rides
# the SAME per-core ring as a log record (discriminated by `LogEventRecord.kind`)
# → one ring, one drain, two outputs (text logs + OTLP-shaped span JSON). P4b
# adds the `ctx.tracer` accessor; the struct shape here is unchanged.
from komira_log.tracer import Tracer
