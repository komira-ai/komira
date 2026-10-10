# =============================================================================
# thp_policy.mojo — HOST transparent-hugepage policy detection (`auto` mode)
# =============================================================================
#
# # What this module is
#
# The runtime probe behind the `auto` memory-advice mode. It reads the three
# kernel files that decide whether `MADV_HUGEPAGE` can do anything on THIS
# host, ONCE per process, and resolves them to an `ADVICE_*` mode
# (`hugepage_auto_advice_mode`).
#
#   /sys/kernel/mm/transparent_hugepage/enabled   the system THP policy
#   /sys/kernel/mm/transparent_hugepage/defrag    the allocation-stall policy
#   /proc/self/status  THP_enabled:               this PROCESS's THP state
#
# # THE SHAPE: pure PARSE, separate from impure READ
#
# Every decision this module makes lives in a total, pure function that takes
# the file CONTENTS as a `String` (`parse_thp_enabled`, `parse_thp_defrag`,
# `parse_thp_process_enabled`, `resolve_auto_mode`). The syscalls live in
# `_read_small_file` and nowhere else. That split is what lets the ENTIRE
# decision table be asserted on a mac, in a container, or inside a build
# sandbox where THP is unconditionally disabled — the hosts where the ON path
# is otherwise unreachable (see the PR_SET_THP_DISABLE note below).
#
# # THE DECISION TABLE, and why each row is what it is
#
#   row  THP_enabled  enabled=      ->  mode              why
#   ---  -----------  ------------  --  ----------------  ------------------
#    1   0            (any)             ADVICE_OFF        PR_SET_THP_DISABLE
#    2   1/absent     [never]           ADVICE_OFF        THP is off, host-wide
#    3   1/absent     [always]          ADVICE_OFF        see PESSIMISATION
#    4   1/absent     [madvise]         ADVICE_HUGEPAGE   the row THP exists for
#    5   anything else / file missing / unreadable / unparseable / non-Linux
#                                       ADVICE_OFF        FAIL-CLOSED
#
# ROW 1 — `PR_SET_THP_DISABLE` is INHERITED across fork/exec and makes
# `MADV_HUGEPAGE` a STRICT no-op. `/proc/self/status`'s `THP_enabled:` reports
# it, and the polarity is **1 = THP AVAILABLE**, 0 = disabled for the process.
# The field postdates roughly kernel 5.17, so ABSENT must be read as
# AVAILABLE, not as 0 — reading absent-as-0 silently disables the advice on
# every older host.
# Skipping this check would not be UNSAFE (with the flag set, madvise merely
# returns 0 and allocates nothing); it is here so a probe on a host that
# spawned the process with THP disabled REPORTS "disabled for this process"
# instead of silently measuring zero.
#
# ROW 3 — THE PESSIMISATION, and the one row a "does the host support it?"
# framing gets wrong. On `enabled=[always]` the kernel ALREADY backs every
# eligible anonymous VMA with huge pages without being asked. `MADV_HUGEPAGE`
# there buys no page that was not already coming — but it sets `VM_HUGEPAGE`,
# and `VM_HUGEPAGE` is precisely what grants the VMA `__GFP_DIRECT_RECLAIM`
# under `defrag` ∈ {always, madvise, defer+madvise}. So the syscall's only
# effect on an `always` host is to opt the process INTO the synchronous
# compaction stall it would otherwise have avoided. Detection must therefore
# refuse on `[always]`, not only on `[never]`.
# This row is INFERRED from kernel gfp-mask semantics (`vma_thp_gfp_mask`).
# If it is wrong, the cost is that `auto` declines on a host where the advice
# is free, which is the safe direction of the error.
#
# # WHY `defrag` IS READ BUT DOES NOT CHANGE THE MODE
#
# `defrag` is the STALL policy, not a support signal. For a `MADV_HUGEPAGE`
# caller the values `always`, `madvise` and `defer+madvise` all mean
# synchronous direct compaction on our regions; only `defer` and `never` are
# stall-free. The first large madvised allocation on a `[madvise]` host can
# pay hundreds of milliseconds of such compaction (`hugepage_span.mojo`
# header, caveat 2).
#
# `auto` does NOT fall back to `ADVICE_POPULATE` under a compaction-hazard
# `defrag`, for two reasons that pull in the same direction:
#
#   (a) It would refuse `ADVICE_HUGEPAGE` on the common `defrag=[madvise]`
#       host, which is exactly where huge pages pay off for large buffers.
#   (b) `ADVICE_POPULATE` is not a free substitute: it forces residency of
#       allocated-but-never-written capacity (the over-allocated tails of
#       growable buffers and doubling heaps). Trading a time hazard for a
#       memory one, under an enforced cgroup memory cap, is not obviously a
#       win.
#
# So `defrag` is parsed, cached and REPORTED (`thp_defrag_is_compaction_hazard`
# / `thp_policy_report`) — watch it per run, not via a p50 that discards a
# first-run stall — but it does not select the mode. If the stall dominates,
# the change is one line in `resolve_auto_mode`.
#
# # PROBE-ONCE
#
# `hugepage_auto_advice_mode()` may be resolved many times (every
# `parse_memory_advice("auto")`), and an unmemoized probe would put three
# open/read/close pairs on each. The snapshot is therefore frozen in a
# `_Global` slot (the same mechanism `cpu_topology` uses), and
# `thp_probe_count()` is the FALSIFIER: a guard that resolves the mode N times
# and asserts the count is 1 goes RED if the freeze is ever removed.
#
# `/proc/self` resolves to the thread-GROUP LEADER, which is a real hazard
# for `Cpus_allowed` (per-THREAD; see `cpu_topology`). It does NOT apply
# here: `PR_SET_THP_DISABLE` is a per-MM (whole-process) flag, so every thread
# reads the same value and the probe has no ordering requirement.
#
# # SAFETY
#
# No `UnsafePointer` crosses a module boundary. The public API is `Int` /
# `Bool` / `String`. The FFI buffer is a function-local `alloc[UInt8]` freed
# before return. The cached snapshot is strictly plain data (four `Int`s — no
# `List`, no `String`, no `OwnedPointer` field, no wildcard origin), so it is
# safe as `_Global` process-lifetime storage.
# =============================================================================

from std.ffi import external_call, _Global
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.info import CompilationTarget


# =============================================================================
# The ADVICE vocabulary
# =============================================================================
#
# DEFINED HERE, not in `hugepage_span`, purely to keep the import graph
# ACYCLIC: `hugepage_span` must import this module (it resolves `auto` through
# it), so this module must not import `hugepage_span`. `hugepage_span` aliases
# all three names straight back, so
# `from komira_buffer.hugepage_span import ADVICE_OFF` works and there is
# exactly ONE definition of each value.
# =============================================================================

comptime ADVICE_OFF: Int = 0
comptime ADVICE_HUGEPAGE: Int = 1
comptime ADVICE_POPULATE: Int = 2


# =============================================================================
# Policy tokens — the parsed form of each file
# =============================================================================

comptime THP_ENABLED_UNKNOWN: Int = 0
"""File missing, unreadable, empty, no bracketed token, or an unrecognised
token. Resolves to `ADVICE_OFF` — this is the fail-closed sentinel."""
comptime THP_ENABLED_ALWAYS: Int = 1
comptime THP_ENABLED_MADVISE: Int = 2
comptime THP_ENABLED_NEVER: Int = 3

comptime THP_DEFRAG_UNKNOWN: Int = 0
comptime THP_DEFRAG_ALWAYS: Int = 1
comptime THP_DEFRAG_DEFER: Int = 2
comptime THP_DEFRAG_DEFER_MADVISE: Int = 3
comptime THP_DEFRAG_MADVISE: Int = 4
comptime THP_DEFRAG_NEVER: Int = 5

comptime THP_PROCESS_DISABLED: Int = 0
"""`/proc/self/status` reported `THP_enabled: 0` — `PR_SET_THP_DISABLE` is set
for this process and `MADV_HUGEPAGE` is a strict no-op."""
comptime THP_PROCESS_AVAILABLE: Int = 1
"""`THP_enabled: 1`, OR the field is ABSENT (kernels before ~5.17 do not emit
it). Absent must mean AVAILABLE — see the header."""

comptime _THP_ENABLED_PATH: StaticString = (
    "/sys/kernel/mm/transparent_hugepage/enabled"
)
comptime _THP_DEFRAG_PATH: StaticString = (
    "/sys/kernel/mm/transparent_hugepage/defrag"
)
comptime _PROC_SELF_STATUS_PATH: StaticString = "/proc/self/status"

comptime _THP_FILE_MAX: Int = 8192
"""Read cap. `/sys/.../enabled` is ~30 bytes; `/proc/self/status` is ~1.4 KB on
a modern kernel, so 8 KiB leaves headroom without a large stack of a read."""

comptime _ASCII_NEWLINE: Int = 10
comptime _ASCII_SPACE: Int = 32
comptime _ASCII_TAB: Int = 9
comptime _ASCII_LBRACKET: Int = 91  # '['
comptime _ASCII_RBRACKET: Int = 93  # ']'
comptime _ASCII_COLON: Int = 58  # ':'
comptime _ASCII_ZERO: Int = 48
comptime _ASCII_NINE: Int = 57


# =============================================================================
# PURE parsers — the unit-test seam. No I/O, no FFI, total.
# =============================================================================


def parse_bracketed_token(contents: String) -> String:
    """Return the ACTIVE policy token — the one the kernel wrote in brackets.

    Both THP sysfs files list every legal value and bracket the active one:

        always [madvise] never
        always defer defer+madvise [madvise] never

    Returns `""` when there is no `[`, no closing `]`, or the brackets are
    empty — every one of which the callers map to the UNKNOWN sentinel.

    Total: never raises, whatever the bytes are.
    """
    var n = contents.byte_length()
    if n == 0:
        return String("")
    var bs = contents.as_bytes()
    var i = 0
    while i < n and Int(bs[i]) != _ASCII_LBRACKET:
        i += 1
    if i >= n:
        return String("")
    i += 1  # step past '['
    # Accumulate BYTES and decode once — see `_read_small_file` for why this is
    # not a `chr(Int(byte))` loop.
    var out = List[UInt8]()
    while i < n:
        var c = Int(bs[i])
        if c == _ASCII_RBRACKET:
            return String(StringSlice(unsafe_from_utf8=Span[UInt8](out)))
        out.append(bs[i])
        i += 1
    # Unterminated bracket — treat as unparseable, not as the tail.
    return String("")


def parse_thp_enabled(contents: String) -> Int:
    """Parse `/sys/kernel/mm/transparent_hugepage/enabled` to a `THP_ENABLED_*`
    token. Anything unrecognised — including `""` from a missing or unreadable
    file — returns `THP_ENABLED_UNKNOWN`, which resolves to `ADVICE_OFF`."""
    var tok = parse_bracketed_token(contents)
    if tok == "always":
        return THP_ENABLED_ALWAYS
    if tok == "madvise":
        return THP_ENABLED_MADVISE
    if tok == "never":
        return THP_ENABLED_NEVER
    return THP_ENABLED_UNKNOWN


def parse_thp_defrag(contents: String) -> Int:
    """Parse `/sys/kernel/mm/transparent_hugepage/defrag` to a `THP_DEFRAG_*`
    token. Five legal values, one more than `enabled` — a parser written
    against `enabled` and reused here mis-reads `defer+madvise`."""
    var tok = parse_bracketed_token(contents)
    if tok == "always":
        return THP_DEFRAG_ALWAYS
    if tok == "defer":
        return THP_DEFRAG_DEFER
    if tok == "defer+madvise":
        return THP_DEFRAG_DEFER_MADVISE
    if tok == "madvise":
        return THP_DEFRAG_MADVISE
    if tok == "never":
        return THP_DEFRAG_NEVER
    return THP_DEFRAG_UNKNOWN


def defrag_is_compaction_hazard(defrag: Int) -> Bool:
    """True when a `MADV_HUGEPAGE` region on this host may pay SYNCHRONOUS
    direct compaction on its first fault.

    `always`, `madvise` and `defer+madvise` all grant `__GFP_DIRECT_RECLAIM` to
    a `VM_HUGEPAGE` VMA; `defer` wakes kcompactd and falls straight back to
    4 KiB; `never` does nothing. UNKNOWN is reported as a hazard — the same
    fail-closed direction as everything else here.

    Reported, never acted on: see the header for why `auto` does not select on
    this.
    """
    return (
        defrag == THP_DEFRAG_ALWAYS
        or defrag == THP_DEFRAG_MADVISE
        or defrag == THP_DEFRAG_DEFER_MADVISE
        or defrag == THP_DEFRAG_UNKNOWN
    )


def parse_thp_process_enabled(status: String) -> Int:
    """Parse the `THP_enabled:` line of `/proc/self/status`.

    THREE-STATE, and the third state is the one that matters:

        `THP_enabled:\t1`  -> THP_PROCESS_AVAILABLE
        `THP_enabled:\t0`  -> THP_PROCESS_DISABLED  (PR_SET_THP_DISABLE)
        field ABSENT       -> THP_PROCESS_AVAILABLE (kernels before ~5.17)

    An unreadable `/proc/self/status` (`""`) also lands on AVAILABLE, which is
    deliberate: this field is an EXPLAINER, not the safety gate. The safety
    gate is `parse_thp_enabled`, whose missing-file arm is OFF. Treating an
    absent field as DISABLED would silently kill the lever on every pre-5.17
    kernel.
    """
    var n = status.byte_length()
    if n == 0:
        return THP_PROCESS_AVAILABLE
    var bs = status.as_bytes()
    comptime key = "THP_enabled"
    var klen = key.byte_length()
    var kb = key.as_bytes()
    var i = 0
    while i < n:
        # Does the line at `i` start with the key, followed by ':'?
        var matched = i + klen < n
        if matched:
            for k in range(klen):
                if Int(bs[i + k]) != Int(kb[k]):
                    matched = False
                    break
        if matched and Int(bs[i + klen]) == _ASCII_COLON:
            var j = i + klen + 1
            # Skip the separating whitespace (tab on every kernel seen).
            while j < n and (
                Int(bs[j]) == _ASCII_SPACE or Int(bs[j]) == _ASCII_TAB
            ):
                j += 1
            if j < n:
                var d = Int(bs[j])
                if d >= _ASCII_ZERO and d <= _ASCII_NINE:
                    if d == _ASCII_ZERO:
                        return THP_PROCESS_DISABLED
                    return THP_PROCESS_AVAILABLE
            # Present but unparseable: do not claim it is disabled.
            return THP_PROCESS_AVAILABLE
        # Advance to the next line.
        while i < n and Int(bs[i]) != _ASCII_NEWLINE:
            i += 1
        i += 1
    return THP_PROCESS_AVAILABLE


def resolve_auto_mode(enabled: Int, defrag: Int, proc_enabled: Int) -> Int:
    """The `auto` decision, as a pure function of the three parsed tokens.

    The table is in the module header; the two rows worth restating are that
    `[always]` resolves to OFF (issuing the advice there is a pessimisation,
    not a no-op) and that EVERY unrecognised input resolves to OFF.

    `defrag` is accepted and deliberately unused — the argument is in the
    signature so the reported snapshot and the decision cannot drift apart, and
    so that selecting on it later is a change inside this one function.
    """
    _ = defrag
    if proc_enabled == THP_PROCESS_DISABLED:
        return ADVICE_OFF
    if enabled == THP_ENABLED_MADVISE:
        return ADVICE_HUGEPAGE
    # ALWAYS, NEVER, UNKNOWN, and anything a future kernel invents.
    return ADVICE_OFF


# =============================================================================
# Internal: small-file reader (fopen/fread/fclose) — Linux only
# =============================================================================


def _read_small_file(var path: String) -> String:
    """fopen + fread + fclose of a small sysfs/procfs file, capped at
    `_THP_FILE_MAX` bytes. Returns "" on ANY error — missing file, permission
    denied, short read, non-Linux.

    Mirrors `cpu_topology.mojo`'s `_read_small_file` (kept local so the FFI
    surface of this module is auditable in one place — the same reason that one
    is a local copy of `proc_probe.mojo`'s `_read_small_file_to_string`).

    ⚠ Deliberately NOT `FileHandle` + `read()`: procfs reports `st_size` 0 and
    sysfs reports 4096 while returning ~30 bytes, so any stat-sized read can
    short-read or come back empty. The fopen/fread form is the one this package
    also uses on `/proc/self/cgroup` and `/proc/meminfo`.

    SAFETY:
      (a) `buf` is heap-allocated and freed on every return path.
      (b) `fopen` returns FILE* as Int64; 0 = null-on-failure; we branch.
      (c) `path` is by-value so `.as_c_string_slice()` may NUL-append; the
          C-string pointer is valid until the call returns.
    """
    comptime if CompilationTarget.is_linux():
        var c_path = path.as_c_string_slice().unsafe_ptr()
        var mode_str = String("rb")
        var c_mode = mode_str.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: libc fopen. Library: libc.so.6.
        var fp = external_call["fopen", Int64](c_path, c_mode)
        if fp == 0:
            return String("")
        var buf = alloc[UInt8](_THP_FILE_MAX)
        # FFI-BOUNDARY: fread(ptr, size, nmemb, FILE*) -> size_t.
        var n_read = external_call["fread", Int64](
            buf, Int64(1), Int64(_THP_FILE_MAX), fp
        )
        _ = external_call["fclose", Int32](fp)
        if n_read <= 0:
            buf.free()
            return String("")
        var n_int = Int(n_read)
        # ⚠ NOT `s += chr(Int(buf[i]))`. `chr` takes a CODE POINT, so handing
        # it a BYTE re-encodes every byte >= 0x80 as its own 2-byte UTF-8 form
        # and NOTHING RAISES — silent mojibake. These files are ASCII in
        # practice, but a
        # reader that is only correct for its expected input is the bug.
        var bytes = List[UInt8](capacity=n_int)
        for i in range(n_int):
            bytes.append(buf[i])
        buf.free()
        var s = String(StringSlice(unsafe_from_utf8=Span[UInt8](bytes)))
        return s^
    else:
        return String("")


# =============================================================================
# The frozen snapshot
# =============================================================================


struct _ThpSnapshot(Copyable, Movable):
    """The host THP policy, sampled once and frozen for the process.

    Strictly plain data (four `Int`s — no `List`, no `String`, no
    `OwnedPointer`, no wildcard origin), so it is safe as `_Global` static
    storage: the hazard is heap-OWNING fields inside process-lifetime storage,
    and this struct has none. In particular the sysfs CONTENTS are NOT cached — only the resolved
    tokens.
    """

    var enabled: Int
    var defrag: Int
    var proc_enabled: Int
    var mode: Int

    def __init__(out self, enabled: Int, defrag: Int, proc_enabled: Int):
        self.enabled = enabled
        self.defrag = defrag
        self.proc_enabled = proc_enabled
        self.mode = resolve_auto_mode(enabled, defrag, proc_enabled)

    @staticmethod
    def unknown() -> _ThpSnapshot:
        """The fail-closed snapshot: nothing was learned, so advise nothing."""
        return _ThpSnapshot(
            THP_ENABLED_UNKNOWN, THP_DEFRAG_UNKNOWN, THP_PROCESS_AVAILABLE
        )


def _probe_thp_policy_uncached() -> _ThpSnapshot:
    """Read the three files and resolve. Never raises; every failure arm is the
    UNKNOWN token, which `resolve_auto_mode` maps to `ADVICE_OFF`."""
    comptime if CompilationTarget.is_linux():
        # ⚠ NO pre-initialised locals here. Seeding `enabled`/`defrag`/
        # `proc_enabled` to their UNKNOWN tokens before the `try` reads like a
        # partial-failure fallback and is NOT one: every path below either
        # assigns all three or returns the UNKNOWN snapshot whole, so those
        # stores would be dead — and the compiler says so ("assignment was
        # never used"). A dead store that LOOKS like a safety net is worse than
        # no net, because the next reader trusts it.
        try:
            var enabled = parse_thp_enabled(
                _read_small_file(String(_THP_ENABLED_PATH))
            )
            var defrag = parse_thp_defrag(
                _read_small_file(String(_THP_DEFRAG_PATH))
            )
            var proc_enabled = parse_thp_process_enabled(
                _read_small_file(String(_PROC_SELF_STATUS_PATH))
            )
            return _ThpSnapshot(enabled, defrag, proc_enabled)
        except:
            return _ThpSnapshot.unknown()
    else:
        # No THP on darwin; `madvise(MADV_HUGEPAGE)` does not exist there.
        return _ThpSnapshot.unknown()


def _init_thp_probe_counter() -> OwnedPointer[Int]:
    var raw = alloc[Int](1)
    # SAFETY: FFI carve-out — fresh uninitialized storage handed straight to
    # the `_Global` OwnedPointer, which owns it for process lifetime. Exactly
    # one `init_pointee_move` into it, no aliasing.
    raw.unsafe_write(0)
    return OwnedPointer[Int](unsafe_from_raw_pointer=raw)


comptime _THP_PROBE_COUNTER = _Global[
    "komira_host_runtime_thp_probe_count",
    _init_thp_probe_counter,
]


def _bump_thp_probe_count():
    try:
        var gp = _THP_PROBE_COUNTER.get_or_create_ptr()
        gp[][] += 1
    except:
        pass


def thp_probe_count() -> Int:
    """How many times this process has run the UNCACHED sysfs/procfs probe.

    The falsifier for the probe freeze. It reaches 1 on the first `auto`
    resolution and stays there for the life of the process no matter how many
    resolutions follow. A guard that resolves the mode N times and asserts
    this is 1 fails loudly if the freeze is ever removed.

    Returns 0 if `auto` has never been resolved.
    """
    try:
        var gp = _THP_PROBE_COUNTER.get_or_create_ptr()
        return gp[][]
    except:
        return 0  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not


def _init_thp_snapshot() -> OwnedPointer[_ThpSnapshot]:
    """`_Global` init_fn — runs EXACTLY ONCE per process, under the stdlib's
    own init-once guard. THE sysfs + procfs read for the whole process happens
    here.

    Unlike a dlopen init_fn, this one must NOT `abort()` on
    failure: a probe failure is not fatal, it just means "advise nothing". The
    body is therefore total, and `_probe_thp_policy_uncached` swallows its own
    errors into the UNKNOWN snapshot.
    """
    _bump_thp_probe_count()
    var probed = _probe_thp_policy_uncached()
    var raw = alloc[_ThpSnapshot](1)
    # SAFETY: FFI carve-out — `raw` is fresh uninitialized storage handed
    # straight to the `_Global` OwnedPointer, which owns it for process
    # lifetime. Exactly one `init_pointee_move` into it, no aliasing.
    raw.unsafe_write(probed^)
    return OwnedPointer[_ThpSnapshot](unsafe_from_raw_pointer=raw)


comptime _THP_SNAPSHOT = _Global[
    "komira_host_runtime_thp_policy_snapshot",
    _init_thp_snapshot,
]


def _frozen_thp_snapshot() -> _ThpSnapshot:
    """The process-frozen probe result. Degrades to the fail-closed UNKNOWN
    snapshot if the global is unavailable — never to a live re-probe, because
    a repeated re-probe is exactly what the freeze prevents."""
    try:
        var gp = _THP_SNAPSHOT.get_or_create_ptr()
        return gp[][].copy()
    except:
        return _ThpSnapshot.unknown()  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not


# =============================================================================
# Public API
# =============================================================================


def hugepage_auto_advice_mode() -> Int:
    """The `ADVICE_*` mode the `auto` memory-advice mode resolves to on THIS
    host. Cached: the sysfs/procfs read happens at most once per process.

    `ADVICE_OFF` on anything unrecognised, missing, unreadable, or non-Linux.
    """
    return _frozen_thp_snapshot().mode


def thp_enabled_policy() -> Int:
    """The frozen `THP_ENABLED_*` token for this host."""
    return _frozen_thp_snapshot().enabled


def thp_defrag_policy() -> Int:
    """The frozen `THP_DEFRAG_*` token for this host."""
    return _frozen_thp_snapshot().defrag


def thp_process_enabled() -> Int:
    """The frozen `THP_PROCESS_*` state for THIS process (PR_SET_THP_DISABLE).
    """
    return _frozen_thp_snapshot().proc_enabled


def thp_defrag_is_compaction_hazard() -> Bool:
    """True when the first `MADV_HUGEPAGE` fault on this host may pay
    synchronous direct compaction (hundreds of milliseconds). THE thing a
    benchmark must watch, and the reason it must report PER-RUN wall rather
    than a p50 — a first-run stall is exactly what a median discards."""
    return defrag_is_compaction_hazard(_frozen_thp_snapshot().defrag)


def prime_thp_policy() -> Int:
    """Force the probe NOW and return the resolved mode.

    The probe is otherwise taken lazily on the first `auto` resolution —
    possibly on a worker thread, mid-query, inside a timed region. This exists
    for benchmarks and embedders that want the
    three file reads taken at an EXPLICIT point (the top of `main`). Calling it
    more than once is a no-op; calling it never is also fine.
    """
    return hugepage_auto_advice_mode()


# THE THREE NAME HELPERS BELOW ARE `-> StaticString` / WRITING SHAPE, NOT
# `-> String`. A ladder that RETURNS one of three-or-more string literals is
# lowered to two parallel constant arrays (pointers, lengths) selected by one
# register through independently relocated bases, and a shared-library link
# can bind such a pair CROSSED. The binding is a property of the whole LINK,
# so every returning ladder in a linked artifact is exposed to it.
def _enabled_name(tok: Int) -> StaticString:
    if tok == THP_ENABLED_ALWAYS:
        return "always"
    if tok == THP_ENABLED_MADVISE:
        return "madvise"
    if tok == THP_ENABLED_NEVER:
        return "never"
    return "unknown"


def _defrag_name(tok: Int) -> StaticString:
    if tok == THP_DEFRAG_ALWAYS:
        return "always"
    if tok == THP_DEFRAG_DEFER:
        return "defer"
    if tok == THP_DEFRAG_DEFER_MADVISE:
        return "defer+madvise"
    if tok == THP_DEFRAG_MADVISE:
        return "madvise"
    if tok == THP_DEFRAG_NEVER:
        return "never"
    return "unknown"


def _write_mode_name[W: Writer](mut writer: W, mode: Int):
    """⚠ THIS WRITES; IT DOES NOT RETURN. Unlike its two siblings above, this
    ladder's fallback builds a runtime String (`mode:<n>`), so `-> StaticString`
    is not available and the WRITING shape is what takes the arms out of a
    returning position."""
    if mode == ADVICE_OFF:
        writer.write("off")
        return
    if mode == (ADVICE_HUGEPAGE | ADVICE_POPULATE):
        writer.write("hugepage|populate")
        return
    if mode == ADVICE_HUGEPAGE:
        writer.write("hugepage")
        return
    if mode == ADVICE_POPULATE:
        writer.write("populate")
        return
    writer.write("mode:", mode)


def _mode_name(mode: Int) -> String:
    """A thin `String`-collecting wrapper over `_write_mode_name`, for the
    report line that concatenates. The LADDER lives in the writing helper —
    keep it there."""
    var out = String()
    _write_mode_name(out, mode)
    return out^


def thp_policy_report() -> String:
    """One line naming everything the probe read and what it decided.

    A benchmark with no record of WHICH mode `auto` selected per host is
    unattributable — a flat result and one where `auto` chose OFF look
    identical. Emit this once per benchmark process.
    """
    var s = _frozen_thp_snapshot()
    var out = String("thp_policy: enabled=[")
    out += _enabled_name(s.enabled)
    out += "] defrag=["
    out += _defrag_name(s.defrag)
    out += "] THP_enabled="
    if s.proc_enabled == THP_PROCESS_DISABLED:
        out += "0(PR_SET_THP_DISABLE)"
    else:
        out += "1"
    out += " compaction_hazard="
    if defrag_is_compaction_hazard(s.defrag):
        out += "yes"
    else:
        out += "no"
    out += " -> auto="
    out += _mode_name(s.mode)
    return out^
