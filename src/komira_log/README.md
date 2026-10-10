# komira_log

Structured logging. The call surface is five level functions keyed by a
compile-time format string and module name, `log.info["job {} started",
"my_module"](ArgStr(job_id))`, with typed arguments (`ArgI64`, `ArgU64`,
`ArgF64`, `ArgBool`, `ArgStr`) and named fields (`Field("attempt",
ArgI64(3))`). Before an engine is installed a call writes one line to stderr
synchronously; a long-lived service installs a `SharedEngine` once
(`LogManager`) and the same call sites then write binary records into
per-core rings that a drain decodes and hands to file, stderr and metric
sinks. Spans ride the same rings (`span_open`, `span_close`, `Tracer`).

Levels are filtered per module by `EnvFilter`, parsed from a `--log-level`
directive string (`info,komira_pg=debug`): a bare level sets the default and
`module=level` overrides it, longest dotted prefix first. A token it cannot
parse is recorded and reported, never fatal. `StructuredLogLine` builds one
JSON log line with Google Cloud Logging severities, redacting
credential-looking values and email addresses on the way in and capping each
value at 2 KiB.

The package reads no environment variable: the binary passes its parsed flag
values to `init_logging_from_spec`. It does not ship logs anywhere over a
network; a collector reads the process's stdout, stderr or files.

## Examples

A directive string resolves each module's level by longest dotted prefix, and
keeps the tokens it rejected:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_log import EnvFilter, LEVEL_DEBUG, LEVEL_INFO, LEVEL_WARN, level_name
from komira_log import parse_level

var f = EnvFilter("info,komira_pg=debug,komira_pg.pool=warn,debgu")
assert_equal(f.effective_level("komira_http"), LEVEL_INFO)         # the default
assert_equal(f.effective_level("komira_pg"), LEVEL_DEBUG)
assert_equal(f.effective_level("komira_pg.pool"), LEVEL_WARN)      # longer prefix wins
assert_equal(f.effective_level("komira_pgx"), LEVEL_INFO)          # not a dotted prefix
assert_equal(f.num_rules(), 2)
assert_equal(f.malformed_report(), "'debgu'")  # reported, not fatal

assert_equal(parse_level("WARNING").value(), LEVEL_WARN)
assert_true(not parse_level("verbose"))
assert_equal(level_name(LEVEL_DEBUG), "DEBUG")
```

One JSON line, built field by field; a credential and an email are redacted
before they are stored, and an empty field is left out:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_log.structured_log import StructuredLogLine

var line = StructuredLogLine("WARNING", "login refused for someone@example.com")
line.with_str("route", "/v1/login")
line.with_int("status", 401)
line.with_str("detail", "password=hunter2")
line.with_str("empty", "")
var text = line.render()
assert_true(text.startswith('{"severity":"WARNING","message":"login refused for <email>"'))
assert_true('"route":"/v1/login","status":401' in text)
assert_false("hunter2" in text)
assert_true("<redacted>" in text)
assert_false('"empty"' in text)
```

The facade, before any engine is installed, writes one line to stderr. The
line is the format string with each `{}` replaced by the next positional
argument, then every `Field` as `key=value`, after a timestamp, the level
and the module. `interpolate` and `render_line` are the two functions the
facade assembles it with, so the example checks the exact text the second
call writes (with a fixed timestamp in place of the clock):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
import komira_log as log
from komira_log import ArgI64, ArgStr, Field, LEVEL_WARN
from komira_log.pattern_layout import interpolate, render_line

log.info["readme example {} started", "readme"](ArgStr("job-7"))
log.warn["upload failed", "readme"](Field("attempt", ArgI64(3)))

var message = interpolate("readme example {} started", [ArgStr("job-7").render()])
assert_equal(message, "readme example job-7 started")
var line = render_line(
    Int64(1790812800000), LEVEL_WARN, "readme", "upload failed",
    [Field("attempt", ArgI64(3)).render()],
)
assert_equal(line, "2026-10-01T00:00:00.000Z WARN [readme] upload failed attempt=3")
```
