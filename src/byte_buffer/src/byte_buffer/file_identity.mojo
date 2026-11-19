# =============================================================================
# file_identity.mojo — revalidating a pinned file mapping against its path
# =============================================================================
#
# WHAT PROBLEM THIS EXISTS FOR
# ----------------------------
# A path-keyed cache that holds a file's PARSED METADATA is stale-but-loud: the
# stale footer disagrees with the file's current bytes, so a rewritten file
# produces a decode error or a crash. A path-keyed cache that ALSO holds the
# file's BYTES (a pinned `mmap`) is stale-and-SILENT: footer and bytes stay
# mutually consistent with each other, so the engine serves yesterday's coherent
# snapshot forever, with no error, until the process restarts.
#
# Loud-failure -> silent-wrong-answer is a correctness REGRESSION. This module
# is the revalidation that prevents it: the cheapest thing that can tell "the
# file I mapped" apart from "the file at that path now".
#
# WHAT DUCKDB DOES, WHICH IS WHAT THIS COPIES
# -------------------------------------------
# DuckDB 1.5.5 revalidates on EVERY cache hit.
# `ParquetFileMetadataCache::IsValid` -> `ExternalFileCache::IsValid` compares
# the etag / version_tag for remote files and the LAST_MODIFIED timestamp for
# local ones, and `validate_external_file_cache` defaults to VALIDATE_ALL. On a
# failed validation `CachingFileHandle::GetFileHandle()` re-stats the file and
# clears the ENTIRE file's cached ranges — footer AND bytes, together.
#
# It also carries a clock-resolution guard, `LAST_MODIFIED_THRESHOLD = 10s`,
# and that guard is the non-obvious half of the design. An mtime comparison is
# only meaningful once the mtime is far enough in the past that a subsequent
# write is GUARANTEED to move it. Inside the filesystem's timestamp
# granularity, a file can be rewritten with an unchanged mtime — and if the
# rewrite happens to preserve the size and the inode (an in-place `O_TRUNC`
# rewrite of the same length), size and inode do not move either. Every field
# we can compare is then identical across a real content change. So the
# predicate is not "the fields match" but:
#
#     TRUST  ==  (fields match)  AND  (mtime is more than 10s in the past)
#
# Without the second clause a fast rewrite still serves stale bytes, and the
# bug has shipped with extra steps.
#
# WHY THE IDENTITY IS TAKEN BY PATH, NOT BY FD
# --------------------------------------------
# `MmapRegion.open_readonly` closes its fd after mapping (POSIX keeps the
# mapping alive independently). Even if it did not, an `fstat` on a RETAINED fd
# restats the OLD inode, which reports "unchanged" for exactly the rewrite that
# matters most — write-a-new-file + `rename(2)`, the form every atomic writer
# uses. `stat(2)` on the PATH resolves whatever the name denotes NOW: a rename
# shows up as an inode change, an in-place truncate as a size and/or mtime
# change.
#
# This also bounds the UNLINKED-INODE case for free. A pinned mapping keeps the
# unlinked inode's blocks alive; with revalidation, the first decode-path hit
# after the unlink fails its stat, the entry is dropped, and the pin is
# released — so the blocks are held until the next query rather than until the
# process exits.
#
# COST
# ----
# One `stat(2)` per file per query on the decode path. Single-digit
# microseconds against the multi-millisecond mapping cost the pin removes. The
# syscall count is bounded by the SCAN's file count, not by its read count:
# per-worker readers clone from the row-0 reader and never re-enter the cache.
#
# ENCAPSULATION
# -------------
# `FileIdentity` is a POD value type — five `Int`s and a `Bool`. No pointer
# crosses this module's boundary. The single `UnsafePointer` is the FFI
# out-parameter for the C shim, taken over a STACK `InlineArray` inside
# `stat_path` and never stored.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


comptime DEFAULT_STALENESS_MIN_AGE_NS: Int = 10_000_000_000
"""How old a file's mtime must be before an mtime comparison is trusted
(10 seconds — DuckDB's `LAST_MODIFIED_THRESHOLD`, deliberately the same
number).

THIS IS A CLOCK-RESOLUTION GUARD, NOT A CACHE TTL. It does not bound how long
an entry may live; it bounds how RECENTLY the underlying file may have been
written for its timestamp to be usable as a change detector. A file last
written an hour ago is trusted forever (until it changes). A file written 200
ms ago is not trusted at all, however many times it is read, because a further
write inside the filesystem's timestamp granularity could leave every
observable field — mtime, size, inode — unchanged.

WHAT THE DEFAULT COSTS YOU, SAID PLAINLY: a query over a file that was written
in the last 10 seconds re-reads and re-parses its footer on every open, and
takes no mapping pin. That is the price of not silently serving the previous
version of a file someone is actively writing. Read-only analytics data — which
is what the pin exists for — is minutes-to-days old and pays nothing."""


struct FileIdentity(ImplicitlyCopyable, Movable):
    """What a `stat(2)` of a path says about the file it currently denotes.

    `valid == False` means the stat FAILED (the path does not exist, is not
    reachable, or the FS is not local). An invalid identity never MATCHES
    anything, including another invalid identity — so a cache entry whose file
    has vanished is dropped rather than served, which is the direction that
    turns a silent wrong answer back into a loud one."""

    var valid: Bool
    var size: Int
    var mtime_ns: Int
    """mtime in nanoseconds since the epoch."""
    var ino: Int
    var dev: Int
    var age_ns: Int
    """`CLOCK_REALTIME` now minus `mtime_ns`, sampled inside the same C call as
    the stat. MAY BE NEGATIVE (clock skew, a future-dated mtime, an NFS server
    whose clock leads ours); a negative age is by construction not "more than
    10s in the past", so it reads as untrustworthy, which is correct."""

    def __init__(out self):
        """The INVALID identity. Matches nothing."""
        self.valid = False
        self.size = 0
        self.mtime_ns = 0
        self.ino = 0
        self.dev = 0
        self.age_ns = 0

    @staticmethod
    def stat_path(path: String) -> FileIdentity:
        """`stat(2)` `path` and return its identity. NEVER RAISES — a failed
        stat returns the invalid identity, because every caller's response to
        "I cannot tell what this file is" must be the same as its response to
        "this file changed": distrust the cached entry.
        """
        var out = Array[Int64, 5](fill=Int64(0))
        var p = path
        # SAFETY (FFI-BOUNDARY): `komira_stat_identity`
        # writes exactly 5 `long long`s through the out-pointer and reads the
        # NUL-terminated path. Both pointers address STACK locals that outlive
        # the call (`out`, `p`); neither is stored. No allocation on either
        # side. The pointer does not leave this function.
        var rc = external_call["komira_stat_identity", Int32](
            p.as_c_string_slice().unsafe_ptr(),
            UnsafePointer(to=out).bitcast[Int64](),
        )
        var ident = FileIdentity()
        if Int(rc) != 0:
            return ident
        ident.valid = True
        ident.size = Int(out[0])
        ident.mtime_ns = Int(out[1])
        ident.ino = Int(out[2])
        ident.dev = Int(out[3])
        ident.age_ns = Int(out[4])
        return ident

    def same_file_as(self, imm other: FileIdentity) -> Bool:
        """True when both identities are valid and every observable field
        agrees. Deliberately compares (dev, ino) as well as (size, mtime): a
        rename-over replaces the inode while potentially preserving size and
        mtime, and `dev` catches a bind-mount/overlay swap under the same
        path."""
        if not self.valid or not other.valid:
            return False
        return (
            self.size == other.size
            and self.mtime_ns == other.mtime_ns
            and self.ino == other.ino
            and self.dev == other.dev
        )

    def is_settled(self, min_age_ns: Int) -> Bool:
        """True when this file's mtime is far enough in the past that a
        subsequent write is guaranteed to move it — DuckDB's
        `LAST_MODIFIED_THRESHOLD` test. See `DEFAULT_STALENESS_MIN_AGE_NS` for
        why a field comparison alone is not sufficient."""
        if not self.valid:
            return False
        return self.age_ns > min_age_ns


def cached_entry_is_trustworthy(
    imm cached: FileIdentity,
    imm current: FileIdentity,
    min_age_ns: Int,
) -> Bool:
    """THE PREDICATE, in one place so it cannot drift between call sites.

    A cached entry may be served ONLY when the file it was built from is
    demonstrably the file at that path now (`same_file_as`) AND that file has
    been quiet long enough for the demonstration to mean anything
    (`is_settled`). Both clauses are load-bearing; dropping either one
    re-opens the silent-stale-read.

    `min_age_ns <= 0` disables the settle clause. That is NOT a shipped
    configuration — it exists so a test can hold the field comparison fixed and
    show that the settle clause is what catches a same-mtime, same-size,
    same-inode rewrite. A production caller passes
    `DEFAULT_STALENESS_MIN_AGE_NS`.
    """
    if not cached.same_file_as(current):
        return False
    if min_age_ns <= 0:
        return True
    return current.is_settled(min_age_ns)


def set_file_mtime_ns(path: String, mtime_ns: Int) -> Bool:
    """Set `path`'s atime AND mtime to `mtime_ns` nanoseconds since the epoch.
    Returns True on success. Never raises.

    WHY THIS IS HERE. The settle clause above is untestable without the ability
    to AGE a fixture: a test that writes a Parquet file and reads it back is
    always inside the 10 s threshold, so every assertion about the mapping pin
    would silently be an assertion about the freshness refusal instead.
    Backdating a fixture lets a test exercise the REAL predicate with the REAL
    default threshold — which a test-only threshold override cannot do, because
    it proves nothing about what ships.

    It is a general POSIX utility (`utimensat(2)`), not a test hook: nothing in
    the engine calls it, and it takes no privileged action.
    """
    var p = path
    # SAFETY (FFI-BOUNDARY): the shim reads the NUL-terminated path from a
    # stack local that outlives the call and stores no pointer.
    var rc = external_call["komira_set_mtime_ns", Int32](
        p.as_c_string_slice().unsafe_ptr(),
        Int64(mtime_ns),
    )
    return Int(rc) == 0
