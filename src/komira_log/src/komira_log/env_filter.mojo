# =============================================================================
# komira_log.env_filter — log-level directive parsing + per-module level
#   lookup.
# =============================================================================
#
# `tracing`-`EnvFilter` semantics over a directive string. A binary takes it
# from its `--log-level` flag and hands it to `config.init_logging_from_spec`
# (or builds `EnvFilter(spec)` itself for an engine it owns); this module never
# reads the environment.
#
#   --log-level=info
#       → global default = INFO, no per-module overrides.
#   --log-level=info,komira_pg=debug,komira_http=warn
#       → global default = INFO; module "komira_pg" = DEBUG;
#         module "komira_http" = WARN.
#   --log-level=debug,komira_job_supervisor.heartbeat=warn
#       → global default = DEBUG; the dotted module path
#         "komira_job_supervisor.heartbeat" = WARN (longest-prefix wins).
#
# A bare token with no `=` sets the GLOBAL default. A `key=value` token sets a
# per-module override. The effective level of a module is the LONGEST matching
# prefix override, or the global default if none matches. Longest-prefix lets
# `komira_job_supervisor=info` + `komira_job_supervisor.heartbeat=warn` coexist: a heartbeat
# site resolves to WARN (more specific), everything else under komira_job_supervisor to
# INFO.
#
# Parsed ONCE at init into this struct, which the level gate consults.
#
# Encapsulation: pure value type. Holds `List[String]` + `List[UInt8]`
# (heap-owning, but NOT stored in any byte-backed slab — `EnvFilter` lives
# inside `LogConfig` which is a process-static heap singleton, not a slab
# element). No `UnsafePointer`, no wildcard origin.
# =============================================================================

from komira_log.levels import (
    DEFAULT_GLOBAL_LEVEL,
    LEVEL_OFF,
    parse_level,
)


# -----------------------------------------------------------------------------
# THE FLAG NAME AND THE SOURCE STRINGS THE BANNER PRINTS.
#
# Spelled ONCE so this file's prose, the banner an operator reads, and the
# tests that pin the banner cannot disagree about what to pass.
# -----------------------------------------------------------------------------

comptime LOG_SPEC_FLAG: StaticString = "--log-level"
"""The conventional flag a binary takes the directive string from. The banner's
"how to change it" hint names it."""

comptime LOG_SPEC_SOURCE_DEFAULT: StaticString = "built-in default (no --log-level given)"
comptime LOG_SPEC_SOURCE_FLAG: StaticString = "--log-level"


# -----------------------------------------------------------------------------
# Small string helpers. `_substr` is byte-exact, and its name does not assert
# ASCII, so the next copier inherits a claim that is true.
# -----------------------------------------------------------------------------


def _substr(s: String, start: Int, end: Int) -> String:
    """Reproduce `s`'s bytes in `[start, end)` EXACTLY, as a String.

    ⛔ DO NOT REWRITE THIS AS `out += chr(Int(bs[i]))`. That spelling is a
    SILENT WRONG ANSWER on any
    non-ASCII input: `chr` maps a CODE POINT to its UTF-8 ENCODING, so a
    stored byte >= 0x80 is not reproduced but RE-ENCODED into two
    (`aé` = 61 C3 A9 -> 61 C3 83 C2 A9). ASCII is the corruption's fixed
    point, which is why an ASCII-only test cannot see it: the callers parse
    log-level directives, whose TARGET names are module paths but
    whose text is attacker/operator-supplied and not ASCII-constrained.
    """
    var bs = s.as_bytes()
    # `StringSlice(unsafe_from_utf8=)` is the byte-exact spelling; it is
    # LENGTH-EXPLICIT, unlike `String(unsafe_from_utf8_ptr=)`, which stops at
    # the first NUL.
    return String(StringSlice(unsafe_from_utf8=bs[start:end]))


def _trim(s: String) -> String:
    """Strip leading/trailing ASCII whitespace (space/tab/CR/LF)."""
    var bs = s.as_bytes()
    var n = len(bs)
    var lo = 0
    while lo < n and (
        bs[lo] == UInt8(ord(" "))
        or bs[lo] == UInt8(ord("\t"))
        or bs[lo] == UInt8(ord("\r"))
        or bs[lo] == UInt8(ord("\n"))
    ):
        lo += 1
    var hi = n
    while hi > lo and (
        bs[hi - 1] == UInt8(ord(" "))
        or bs[hi - 1] == UInt8(ord("\t"))
        or bs[hi - 1] == UInt8(ord("\r"))
        or bs[hi - 1] == UInt8(ord("\n"))
    ):
        hi -= 1
    return _substr(s, lo, hi)


# -----------------------------------------------------------------------------
# A parsed per-module override. SoA-free: a small struct in a `List`.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ModuleRule(Copyable, Movable):
    var prefix: String
    var level: UInt8


struct EnvFilter(Movable):
    """Parsed log-level directives: a global default + module overrides, plus
    every token that was REJECTED while parsing them."""

    var global_level: UInt8
    var rules: List[_ModuleRule]
    # Tokens the parse could not use, VERBATIM. See `_parse` for why keeping
    # them is not the same decision as crashing on them.
    var malformed: List[String]

    def __init__(out self):
        """Empty filter: global default level, no overrides."""
        self.global_level = DEFAULT_GLOBAL_LEVEL
        self.rules = List[_ModuleRule]()
        self.malformed = List[String]()

    def __init__(out self, var spec: String):
        """Parse a directive string (the `--log-level` value)."""
        self.global_level = DEFAULT_GLOBAL_LEVEL
        self.rules = List[_ModuleRule]()
        self.malformed = List[String]()
        self._parse(spec)

    def _parse(mut self, spec: String):
        """Parse comma-separated directives into global + per-module rules.

        Malformed tokens (unknown level name, empty key) are SKIPPED — a logging
        config must never crash the process, and that half of the original
        reasoning is right and unchanged.

        ⭐ THEY ARE NO LONGER SILENT, AND THAT HALF WAS WRONG. "A typo'd
        directive just doesn't take effect" describes the behaviour exactly and
        omits its cost: `--log-level=debgu` leaves the process at INFO with NO
        evidence anywhere that anything was asked for. The operator sees the
        level they did not want and no reason. Each rejected token is recorded
        here VERBATIM and printed by the startup banner
        (`config.log_config_banner_lines`) — reported, never fatal.

        ⚠ AN EMPTY TOKEN IS NOT MALFORMED. A trailing or doubled comma is
        formatting, not a typo; recording it would put noise in a line whose
        whole value is that it only speaks when something is wrong.
        """
        # Split on commas. `String.split` yields StringSlice refs → wrap with
        # String().
        for s in spec.split(","):
            var tok = _trim(String(s))
            if tok.byte_length() == 0:
                continue
            # Find the first '=' by byte-walk (no String.find dependency).
            var tb = tok.as_bytes()
            var eq = -1
            for i in range(len(tb)):
                if tb[i] == UInt8(ord("=")):
                    eq = i
                    break
            if eq < 0:
                # Bare token → global default level.
                var lvl = parse_level(tok)
                if lvl:
                    self.global_level = lvl.value()
                else:
                    self.malformed.append(tok^)
            else:
                var key = _trim(_substr(tok, 0, eq))
                var val = _trim(_substr(tok, eq + 1, len(tb)))
                if key.byte_length() == 0:
                    self.malformed.append(tok^)
                    continue
                var lvl = parse_level(val)
                if lvl:
                    self.rules.append(_ModuleRule(key^, lvl.value()))
                else:
                    self.malformed.append(tok^)

    @always_inline
    def effective_level(self, module: StaticString) -> UInt8:
        """Resolve a module's effective threshold via longest-prefix match.

        A rule `prefix` matches `module` iff `module == prefix` OR `module`
        starts with `prefix + "."` (dotted-path prefixing — `komira_job_supervisor`
        matches `komira_job_supervisor.heartbeat` but NOT `komira_job_supervisorx`). The
        LONGEST matching prefix wins; ties cannot occur (prefixes are distinct
        strings, and a longer match is strictly more specific).

        PERF: the COMMON case is NO per-module overrides (an empty
        `rules` list — `--log-level=info` with no `module=level` tokens). In
        that case the effective level IS the global default, so we return it
        WITHOUT allocating a `String(module)` — this gate runs on EVERY admitted
        emit, and the per-call `String(module)` heap alloc was ~40 ns of the
        hot-path cost. Only when overrides EXIST do we materialize the module
        string for the prefix walk.
        """
        if len(self.rules) == 0:
            return self.global_level
        var mod_str = String(module)
        var best_len = -1
        var best_level = self.global_level
        for i in range(len(self.rules)):
            var p = self.rules[i].prefix
            if self._prefix_matches(p, mod_str):
                if p.byte_length() > best_len:
                    best_len = p.byte_length()
                    best_level = self.rules[i].level
        return best_level

    @staticmethod
    def _prefix_matches(prefix: String, module: String) -> Bool:
        if prefix == module:
            return True
        # Dotted-boundary prefix: module starts with `prefix.` (byte-walk).
        var pb = prefix.as_bytes()
        var mb = module.as_bytes()
        var pn = len(pb)
        if len(mb) <= pn:
            return False
        for i in range(pn):
            if mb[i] != pb[i]:
                return False
        return mb[pn] == UInt8(ord("."))

    def num_rules(self) -> Int:
        """Count of per-module override rules (for tests / introspection)."""
        return len(self.rules)

    def num_malformed(self) -> Int:
        """Count of directive tokens this parse REJECTED."""
        return len(self.malformed)

    def malformed_report(self) -> String:
        """The rejected tokens as one comma-separated quoted list, or EMPTY when
        there are none.

        EMPTY-when-clean is the contract the banner rests on: a report that fired
        on a good directive would be noise an operator learns to skip, which
        costs exactly what the silence cost."""
        if len(self.malformed) == 0:
            return String("")
        var out = String("")
        for i in range(len(self.malformed)):
            if i > 0:
                out += String(", ")
            out += String("'") + self.malformed[i] + String("'")
        return out^
