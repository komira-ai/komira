# =============================================================================
# komira_async/fs/shallow_dir_entry.mojo — shared SHALLOW-listing element
# =============================================================================
#
# the `ShallowDirEntry` POD was originally defined inside
# `komira_async/fs/local_fs.mojo`. It is now hoisted to its own
# module so that EVERY FileSystem impl — `LocalFs`, `S3Fs`, `GcsFs`, and later
# `AzureFs` — can return it from a `list_dir_shallow` method without a cyclic
# dependency back into `local_fs.mojo`. `komira_async` is depended-on by all
# of the cloud-FS packages (they already import `komira_async.fs.file_system`
# and `komira_async.ops.waker_sink`), so this is the correct shared home.
#
# `local_fs.mojo` re-exports `ShallowDirEntry` from here, so every existing
# `from komira_async.fs.local_fs import ShallowDirEntry` caller is unbroken.
#
# Encapsulation: trivial safe across destroy-recreate POD — `String` + `Bool`, Copyable + Movable.
# No pointers, no wildcard origins, no heap-owning inner container.
# =============================================================================


@fieldwise_init
struct ShallowDirEntry(Movable, Copyable, Deinitable):
    """One immediate child of a directory, from a `*.list_dir_shallow` call.

    the SHALLOW one-level listing primitive's element.
    `is_dir` distinguishes a subdirectory (a `key=value` Hive partition dir,
    or an S3/GCS `CommonPrefixes` fold) from a regular file (a leaf data
    object); `name` is the BARE entry name — the final path component, with
    any trailing `/` stripped — NOT a full path. The caller joins it onto the
    probed prefix to reach the child.
    """

    var name: String
    var is_dir: Bool


def _shallow_basename(key: String) -> String:
    """The BARE final path component of a (possibly slash-terminated) S3/GCS
    key or CommonPrefixes fold.

    strip any trailing `/` (CommonPrefixes folds arrive as `a/b/`), then
    return the segment after the last remaining `/`. Cloud list keys are bare,
    so this yields the child name relative to the probed
    prefix. Examples:
      * `events/dt=2024/`  -> `dt=2024`   (a CommonPrefixes dir fold)
      * `events/dt=2024/part-0.parquet` -> `part-0.parquet` (a Contents file)
      * `top.parquet`      -> `top.parquet`
      * `/`                -> ``          (degenerate; caller skips empties)
    """
    var bs = key.as_bytes()
    var n = len(bs)
    # Strip a single trailing slash (the directory-fold marker). We strip only
    # one — a well-formed key/prefix never has a double trailing slash.
    if n > 0 and bs[n - 1] == UInt8(ord("/")):
        n -= 1
    # Find the last remaining '/' in [0, n); the basename is everything after.
    var last = -1
    for i in range(n):
        if bs[i] == UInt8(ord("/")):
            last = i
    # BYTE-EXACT. ⛔ NOT `out += chr(Int(bs[i]))` — that was this body until
    # 2026-09-07 and it RE-ENCODED every byte >= 0x80 into two, so a non-ASCII
    # S3/GCS/Azure key or CommonPrefixes fold (`events/city=Zürich/`) yielded a
    # basename that does not exist in the bucket. `StringSlice(
    # unsafe_from_utf8=)` is the in-tree byte-exact, LENGTH-EXPLICIT spelling
    # (`komira_core/collections/string_column_view.mojo:145`).
    return String(StringSlice(unsafe_from_utf8=bs[last + 1 : n]))
