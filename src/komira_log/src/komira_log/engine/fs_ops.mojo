# =============================================================================
# komira_log.engine.fs_ops — rename(2) / unlink(2) for segment rotation (P3).
# =============================================================================
#
# Rotation (rotation.mojo / output_sink.mojo) needs two filesystem ops the
# existing `RawWriteFd` (posix_io.mojo) does not expose: rename the live segment
# to a timestamped archive, and unlink the oldest archive past the retention
# cap. Both libc calls are FIXED-ARITY (NOT variadic) — `rename(const char*,
# const char*)` and `unlink(const char*)` — so they need no non-variadic shim
# (unlike `openat`); a direct `external_call` is ABI-safe.
#
# # FFI-BOUNDARY / encapsulation
#
# This module is the SOLE owner of the `rename`/`unlink` external_calls in the
# `komira_log` package (one declaration per FFI symbol). The public API takes/returns
# only `String` + `Bool`/`raises` — no `UnsafePointer` crosses. The
# `as_c_string_slice().unsafe_ptr()` cast is confined to the two call sites
# below with `# SAFETY:` notes; the path String is held alive across the
# syscall by a local var.
# =============================================================================

from std.ffi import external_call


def rename_path(src: String, dst: String) raises:
    """`rename(2)` — atomically move `src` → `dst` on the same filesystem.

    Used by rotation to move the live segment `{name}.log` to a timestamped
    archive `{name}.{date-index}.log`. POSIX `rename` is atomic within one
    filesystem, so a concurrent reader either sees the old or the new name,
    never a torn state. Raises if `rename(2)` returns non-zero.
    """
    var s = src
    var d = dst
    # SAFETY: both path Strings are held alive by the locals `s`/`d` across the
    # synchronous syscall; the kernel copies the path bytes and returns. The
    # NUL-terminated views never escape this function. `rename` is fixed-arity.
    var rc = external_call["rename", Int32](
        s.as_c_string_slice().unsafe_ptr(),
        d.as_c_string_slice().unsafe_ptr(),
    )
    if Int(rc) != 0:
        raise Error(
            "fs_ops.rename_path: rename('" + src + "' -> '" + dst
            + "') failed (rc=" + String(Int(rc)) + ")"
        )


def unlink_path(path: String) raises:
    """`unlink(2)` — delete `path`. Used by rotation retention to delete the
    oldest archive past the `keep` cap. Raises if `unlink(2)` returns non-zero
    (e.g. the file does not exist — callers that want best-effort delete should
    swallow the raise)."""
    var p = path
    # SAFETY: `p` holds the path bytes alive across the syscall; the kernel
    # copies the path and returns. `unlink` is fixed-arity.
    var rc = external_call["unlink", Int32](
        p.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error(
            "fs_ops.unlink_path: unlink('" + path + "') failed (rc="
            + String(Int(rc)) + ")"
        )
