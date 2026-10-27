# =============================================================================
# proc_probe.mojo -- Linux procfs/sysfs text probes: the host MEMORY BASIS
# =============================================================================
#
# # What this module is
#
# Two things, and the second exists only to serve the first and its siblings:
#
#   1. `detect_scan_cache_ram_basis_bytes()` -- the free-RAM-relative basis
#      (`min(/proc/meminfo MemAvailable, this scope's cgroup-v2 memory.max)`)
#      that RAM-adaptive caches size themselves against. It is a HOST PROBE:
#      it reads two kernel files, returns an `Int`, and knows nothing about
#      schemas, morsels, plans or any engine concept.
#   2. The Linux small-file + ASCII-parse primitives that probe needs, and
#      that the engine runtime's sysfs cache probes share with it --
#      `_read_small_file_to_string`, `_parse_decimal_int`,
#      `_find_substring_bytes` and the ASCII codepoint constants.
#
# # WHY IT IS IN `komira_host`.runtime` AND NOT IN THE ENGINE
#
# A host probe with no engine semantics must not put an engine package into
# the closure of everything that needs it: the Parquet footer cache sizes
# itself against this basis, and importing it from an engine package would
# pull the engine into every Parquet consumer. What decides placement is
# whether a symbol has any engine SEMANTICS, not how many importers it has.
# This one has none; the engine's hardware profile (L3 size, L2-share
# derivation) stays in the engine.
#
# DO NOT ADD AN IMPORT OF ANY NON-`std` MODULE TO THIS FILE. Its value is
# that it is a LEAF: a single edge back into an engine package (or into
# anything that reaches one) restores the whole cost. This file deliberately
# imports `std.ffi`, `std.memory` and `std.sys.info` and nothing else.
#
# # PLATFORM
#
# Linux-only in effect. `_read_small_file_to_string` is `comptime`-gated on
# `CompilationTarget.is_linux()` and returns "" everywhere else, so every
# probe here fails SOFT to 0 on macOS -- which callers must read as "basis
# unavailable, use the fixed default", never as "the host has no memory".
# The Parquet footer cache and the scan dedup cache both do exactly that.
#
# # FAIL-SOFT CONTRACT
#
# Every function here returns 0 / "" on any failure (file missing, permission
# denied, non-Linux, unparseable). None of them raises and none of them warns.
# A caller that cannot distinguish "unavailable" from "zero" is a bug in the
# caller.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Linux file-reading helpers
# -----------------------------------------------------------------------------
#
# We read small ASCII files (< 4 KB) using fopen+fread+fclose. Mojo's
# stdlib has no equivalent of Rust's `std::fs::read_to_string`, so we
# wrap the libc FILE* API in a fixed-size buffer read.
#
# All helpers fail-soft: a missing file or fopen error returns an empty
# String / zero Int. Callers MUST handle the empty/zero result as
# "data unavailable" and never as "data is zero bytes".
# -----------------------------------------------------------------------------


# Max bytes we read from any single sysfs / procfs file. /proc/meminfo
# on a large server is ~2-3 KB; sysfs `size` files are 5-10 bytes each.
# 4 KB is comfortably above the worst-case observed.
comptime _LINUX_SMALL_FILE_MAX: Int = 4096


def _read_small_file_to_string(var path: String) -> String:
    """fopen + fread + fclose, capped at `_LINUX_SMALL_FILE_MAX` bytes.

    Returns an empty `String` on any error (file missing, permission
    denied, read failure). Strips the trailing newline if present.

    FFI-BOUNDARY: libc fopen / fread / fclose (libc.so.6 on Linux,
    libSystem.dylib on macOS — though we only call from the Linux arm).

    SAFETY:
      (a) `buf` is heap-allocated via `alloc[UInt8]` and freed before
          return. Pointer is valid for the lifetime of the function frame.
      (b) `fopen` returns a FILE* as Int64; `0` is the null-on-failure
          sentinel. We branch on non-zero before fread/fclose.
      (c) `fread(buf, 1, count, fp)` writes at most `count` bytes; we
          read `n_read` (the actual count) into `String`. The buffer is
          guaranteed to contain `n_read` valid bytes after the call.
      (d) `path` is taken by value so `.as_c_string_slice()` may
          NUL-append; the C-string pointer remains valid until the end
          of the frame (after fopen returns).
    """
    comptime if CompilationTarget.is_linux():
        var c_path = path.as_c_string_slice().unsafe_ptr()
        var mode_str = String("rb")
        var c_mode = mode_str.as_c_string_slice().unsafe_ptr()
        var fp = external_call["fopen", Int64](c_path, c_mode)
        if fp == 0:
            return String("")
        var buf = alloc[UInt8](_LINUX_SMALL_FILE_MAX)
        # FFI-BOUNDARY: fread(ptr, size, nmemb, FILE*) -> size_t.
        # Library: libc.so.6.
        var n_read = external_call["fread", Int64](
            buf, Int64(1), Int64(_LINUX_SMALL_FILE_MAX), fp
        )
        _ = external_call["fclose", Int32](fp)
        if n_read <= 0:
            buf.free()
            return String("")
        # Build a String from the bytes. Strip a trailing newline if
        # present (sysfs almost always emits one).
        var n_int = Int(n_read)
        if n_int > 0 and buf[n_int - 1] == UInt8(_NEWLINE):
            n_int -= 1
        var s = String("")
        var i = 0
        while i < n_int:
            s += chr(Int(buf[i]))
            i += 1
        buf.free()
        return s
    else:
        # Unreachable on macOS (we only call from the Linux arm). Return
        # empty so a misrouted caller fails-soft.
        return String("")


# ASCII codepoints used by the byte-level procfs/sysfs parsers. We index into
# `String.as_bytes()` (Span[UInt8]) rather than the deprecated character-
# level `String.__getitem__`. All sysfs / procfs values are pure ASCII.
#
# THE `K`/`M`/`G` SUFFIX ROWS HAVE NO CONSUMER IN THIS FILE, ON PURPOSE.
# Their reader is the engine runtime's sysfs cache-size parser, which imports
# the whole vocabulary from here so the alphabet has ONE definition site.
comptime _ZERO: Int = 48        # '0'
comptime _NINE: Int = 57        # '9'
comptime _SPACE: Int = 32       # ' '
comptime _TAB: Int = 9          # '\t'
comptime _NEWLINE: Int = 10     # '\n'
comptime _CR: Int = 13          # '\r'
comptime _UPPER_K: Int = 75     # 'K'
comptime _LOWER_K: Int = 107    # 'k'
comptime _UPPER_M: Int = 77     # 'M'
comptime _LOWER_M: Int = 109    # 'm'
comptime _UPPER_G: Int = 71     # 'G'
comptime _LOWER_G: Int = 103    # 'g'


def _parse_decimal_int(s: String) -> Int:
    """Parse a leading run of decimal digits in `s` and return as Int.
    Returns 0 if `s` is empty or starts with a non-digit.
    """
    var n_bytes = s.byte_length()
    if n_bytes == 0:
        return 0
    var bs = s.as_bytes()
    var n = 0
    var i = 0
    while i < n_bytes:
        var c = Int(bs[i])
        if c >= _ZERO and c <= _NINE:
            n = n * 10 + (c - _ZERO)
            i += 1
        else:
            break
    return n


def _find_substring_bytes(haystack: Span[UInt8, _], needle: StaticString) -> Int:
    """Naive substring search over a byte span; returns starting index or -1.

    `needle` is a StaticString literal so we can read its bytes without an
    allocation. `haystack` is a byte slice (typically `string.as_bytes()`).
    """
    var n_len = needle.byte_length()
    var h_len = len(haystack)
    if n_len == 0:
        return 0
    if n_len > h_len:
        return -1
    var nb = needle.as_bytes()
    var stop = h_len - n_len
    var i = 0
    while i <= stop:
        var is_match = True
        var j = 0
        while j < n_len:
            if haystack[i + j] != nb[j]:
                is_match = False
                break
            j += 1
        if is_match:
            return i
        i += 1
    return -1


# -----------------------------------------------------------------------------
# The host MEMORY BASIS -- the public surface of this module
# -----------------------------------------------------------------------------


def _linux_read_meminfo_available_bytes() -> Int:
    """Read `MemAvailable` from `/proc/meminfo` and return bytes (the file
    reports kibibytes). Returns 0 on failure.

    `MemAvailable` (Linux 3.14+) is the kernel's own estimate of memory
    available for starting new applications WITHOUT swapping — i.e. free +
    reclaimable page cache/slab, net of what other processes are already
    using. It is the correct free-RAM-relative signal for sizing a
    RAM-adaptive cache: unlike `MemTotal` it shrinks as co-located
    processes (co-located pods) consume memory.

    The engine runtime's MemTotal reader is the same scan for "MemTotal:";
    the two share this module's `_read_small_file_to_string` /
    `_find_substring_bytes` rather than a second copy of them.
    """
    var path = String("/proc/meminfo")
    var contents = _read_small_file_to_string(path^)
    var n_bytes = contents.byte_length()
    if n_bytes == 0:
        return 0
    var bs = contents.as_bytes()
    var pos = _find_substring_bytes(bs, "MemAvailable:")
    if pos < 0:
        return 0
    var key_len = 13  # len("MemAvailable:")
    var i = pos + key_len
    while i < n_bytes and (Int(bs[i]) == _SPACE or Int(bs[i]) == _TAB):
        i += 1
    var kb = 0
    while i < n_bytes:
        var c = Int(bs[i])
        if c >= _ZERO and c <= _NINE:
            kb = kb * 10 + (c - _ZERO)
            i += 1
        else:
            break
    if kb <= 0:
        return 0
    return kb * 1024


def _cgroup_v2_self_rel_path() -> String:
    """Return this process's cgroup-v2 path from `/proc/self/cgroup`
    (the `0::<path>` line), or "" if unavailable (pure cgroup-v1 / no
    procfs).

    Format (unified hierarchy): a single line `0::/<path>`. A hybrid
    (v1+v2) file has one `0::` line among several controller lines; we
    scan for `0::` and take bytes up to the next newline.
    """
    var contents = _read_small_file_to_string(String("/proc/self/cgroup"))
    var n = contents.byte_length()
    if n == 0:
        return String("")
    var bs = contents.as_bytes()
    var pos = _find_substring_bytes(bs, "0::")
    if pos < 0:
        return String("")
    var i = pos + 3  # len("0::")
    var out = String("")
    while i < n:
        var c = Int(bs[i])
        if c == _NEWLINE or c == _CR:
            break
        out += chr(c)
        i += 1
    return out^


def _parent_cgroup_path(p: String) -> String:
    """Return the parent of cgroup path `p` (strip the last `/segment`):
    "/a/b/c" -> "/a/b", "/a" -> "/", "/" -> "/"."""
    var n = p.byte_length()
    if n <= 1:
        return String("/")
    var bs = p.as_bytes()
    var last_slash = -1
    var i = 0
    while i < n:
        if Int(bs[i]) == 47:  # '/'
            last_slash = i
        i += 1
    if last_slash <= 0:
        return String("/")
    var out = String("")
    var j = 0
    while j < last_slash:
        out += chr(Int(bs[j]))
        j += 1
    return out^


def _linux_read_cgroup_v2_mem_max_bytes() -> Int:
    """Return the tightest cgroup-v2 `memory.max` in bytes that applies to
    this process, or 0 if none is enforced (root `memory.max == "max"`) or
    cgroup-v2 is unavailable.

    `memory.max` is the cgroup's HARD memory ceiling — the kernel OOM-kills
    the scope when resident memory would exceed it (systemd-run
    `-p MemoryMax=16G`, or a k3s pod's memory limit, both write it). Reading
    it makes cache sizing pod/scope-aware: a co-located pod sizes to ITS
    budget, not the box total, and a capped verification run sizes to the
    cap. The leaf cgroup usually carries the enforced limit; if it reads
    "max" we walk up to a parent that carries a numeric limit (bounded).

    A pathological huge sentinel (some kernels report a near-Int64-max value
    instead of "max") is harmless: the caller `min`s this against host
    MemAvailable, so the sentinel can never inflate the basis above real
    free RAM.
    """
    var rel = _cgroup_v2_self_rel_path()
    if rel.byte_length() == 0:
        return 0
    var depth = 0
    while depth < 12:
        var path = String("/sys/fs/cgroup") + rel + String("/memory.max")
        var v = _read_small_file_to_string(path^)
        if v.byte_length() > 0:
            # Numeric limit -> return it. Literal "max" parses to 0 -> walk up.
            var n = _parse_decimal_int(v)
            if n > 0:
                return n
        if rel == "/" or rel.byte_length() == 0:
            break
        rel = _parent_cgroup_path(rel)
        depth += 1
    return 0


def detect_scan_cache_ram_basis_bytes() -> Int:
    """Free-RAM-relative basis (bytes) for sizing a RAM-adaptive cache.

    Returns `min(host MemAvailable, this scope's cgroup-v2 memory.max)` when
    both are readable, whichever single signal is readable otherwise, or 0
    when NEITHER is (e.g. macOS / no procfs) so the caller can fall back to
    a fixed default.

    The `min` is the safety net: it never sizes above what is actually free
    on the host AND never above the cgroup cap — so a co-located pod (or a
    memory-capped systemd scope) stays safe, and a
    bogus huge cgroup sentinel can't inflate the basis.
    """
    return _min_of_readable(
        _linux_read_meminfo_available_bytes(),
        _linux_read_cgroup_v2_mem_max_bytes(),
    )


def _min_of_readable(avail: Int, cg: Int) -> Int:
    """The basis rule on two readings (0 means unreadable): the smaller of
    the readable ones, or 0 when neither is. Pure, so the rule is asserted
    from literals rather than from this host's moving MemAvailable."""
    if avail > 0 and cg > 0:
        return avail if avail < cg else cg
    if avail > 0:
        return avail
    return cg  # cg>0, or 0 when neither signal is readable
