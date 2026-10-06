# =============================================================================
# komira_objectstore/local_fs_conditional_store.mojo
#   LocalFsConditionalStore — a DURABLE, zero-dependency local-disk
# `CloneableConditionalWriteStore`.
# =============================================================================
#
# WHY THIS EXISTS. A local, single-machine application (for example a desktop
# app's knowledge graph) needs a PERSISTENT `CloneableConditionalWriteStore` so
# a relaunch sees the previously-written state. The other durable conformer,
# `S3ConditionalStore[C]`, requires a running S3-compatible server + SigV4
# signing, which a desktop user should not have to run. This store is local +
# zero-dependency: it persists the entire CAS-manifest object lifecycle to plain
# files under one root directory, and it sidesteps SigV4 entirely (no clock, no
# creds, no HTTP).
#
# IT IS A DROP-IN. It conforms to the IDENTICAL seam that `CasManifestStore`
# and its consumers parametrize over — `CloneableConditionalWriteStore` =
# `ObjectStore` (head / list_with_delimiter / coalesce_policy) +
# `ConditionalWriteStore` (conditional_put / compare_and_swap / put / get_range /
# get / delete) + `clone()`. Swapping a binary's store type alias to this type
# is the ONLY change required.
#
# -----------------------------------------------------------------------------
# THE ATOMICITY MODEL (the part that matters — same contract S3/MinIO honors)
# -----------------------------------------------------------------------------
# The CAS-manifest protocol relies on EXACTLY these conditional-write semantics
# (see `cas_manifest.mojo` + `in_memory_conditional_store.mojo`):
#
#   * `If-None-Match: *` (create-if-absent): succeeds iff the key is ABSENT;
#     otherwise raises a precondition error (the 412 the loser of a slot race
#     sees). We map this to `open(path, O_WRONLY|O_CREAT|O_EXCL)` — the kernel
#     guarantees EXACTLY ONE creator wins atomically; a second O_EXCL create on
#     an existing path fails with EEXIST. This is the LINEARIZATION POINT for a
#     manifest chunk append: the create-winner of slot K owns slot K. After the
#     exclusive create succeeds we write the bytes into that fd; if a later
#     read sees a zero-length-but-present chunk it is a torn write (crash
#     between create and write) — handled by the read path raising not_found
#     so recovery re-derives the tail (the chunk slot is never re-used because
#     the create already succeeded, so a torn chunk is a permanent gap the
#     protocol's gapless-by-construction invariant forbids; in practice the
#     write follows the create with no intervening await, so the window is the
#     single synchronous write(2)).
#
#   * `If-Match: <etag>`: succeeds iff the object's current etag matches; else
#     a precondition error. Used for the `_HEAD` advance. We read the current
#     object's etag (a content hash, see below), compare, and on match write
#     the new bytes via WRITE-TEMP-THEN-ATOMIC-RENAME (`rename(2)` is atomic
#     within one filesystem — a concurrent reader sees either the old or the
#     new bytes, never a torn mix). On mismatch (or absent) we raise 412.
#
#   * Unconditional `put` (create-or-overwrite): write-temp-then-atomic-rename.
#     Content-addressed table objects use this; an identical-bytes rewrite is a
#     harmless idempotent no-op (same content hash → same etag).
#
#   * `delete`: idempotent `remove(3)` (an absent key succeeds, S3 semantics).
#
# THE ETAG. S3's single-part ETag IS the object's content MD5. We mirror that:
# the etag is a quoted FNV-1a-64 hex of the bytes. This is CRASH-SAFE (no
# counter file to lose / corrupt across a restart) and gives the exact CAS
# semantics the protocol needs — a different `_HEAD` body (new chunk_seq /
# next_offset) hashes differently, so an `If-Match` on a stale etag is detected.
# Two writes of byte-identical content produce identical etags, which is correct
# (S3 behaves the same).
#
# CONCURRENCY SCOPE. The capture node is a SINGLE-USER, SINGLE-PROCESS,
# SINGLE-THREADED loopback service (one Electron desktop app). The process-wide
# CAS-gate in `cas_manifest.mojo` serializes all composite ops regardless of
# backend, so within one process there is no concurrent-thread race on the
# `_HEAD` advance. The O_EXCL create + atomic-rename design ALSO makes the store
# safe against a second PROCESS racing the same root (e.g. two capture nodes on
# one KG dir) for the CREATE path; the If-Match advance has a read-compare-write
# window that, like S3's best-effort `_HEAD` cache, is not strictly linearizable
# across processes — but the manifest's bucket-is-truth LIST recovery
# (`_recover_head_by_list`) makes a stale `_HEAD` self-healing, exactly as it is
# for S3. Multi-process is NOT the personal-KG use case; single-process
# durability-across-restart is, and that is fully honored.
#
# -----------------------------------------------------------------------------
# KEY → FILE MAPPING (flat, one file per object key)
# -----------------------------------------------------------------------------
# An object key (e.g. `personal/manifest/manifest/00000000000000000000.chunk`)
# is FLAT-ENCODED into a single filename under `_root` by percent-encoding every
# byte that is not in the filesystem-safe set `[A-Za-z0-9._-]` (notably `/` →
# `%2F`). This gives a 1:1, reversible key↔filename map with NO nested
# directories to create (one mkdir of the root suffices) and makes
# `list_with_delimiter` a single shallow readdir + decode + prefix-match — the
# exact shape the in-memory conformer's linear scan uses. The encoding is
# deterministic, so the same key always resolves to the same file across runs
# (durability).
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any PUBLIC signature. The byte-write reuses
# `RawWriteFd` (komira_core.io.posix_io) whose public surface is
#     String/Span/Int. The readdir FFI is confined to module-private helpers
#     with `# SAFETY:` blocks (mirroring `komira_fs.local_fs` — its helpers are
#     private to komira_async, so the FFI shape is re-derived here against the
#     SAME C shim symbols komira_fs_posix defines). The object-file READ and the
#     presence probe live in `local_fs_file_read.mojo` over this package's own
#     `_objectstore_shim.c`, so only ENOENT reads as not-found (404).
#   * ZERO wildcard origins in any field or public signature. The two
#     readdir/free out-param locals carry the documented kernel/malloc-returned
#     carve-out (same as `_local_fs_list_recursive`), as LOCALS, never fields.
#   * ZERO `unsafe_from_address=Int`. ZERO `take_pointee`.
# * heap-reuse N/A: `_root` is a single owned `String`; no Movable-with-heap-field
#     in a byte-slab; no wildcard-origin field.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from komira_core.io.posix_io import RawWriteFd

from komira_objectstore.local_fs_file_read import (
    _object_file_present,
    _read_whole_file,
    _root_is_listable,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# =============================================================================
# Content-hash etag (FNV-1a-64, rendered quoted-hex like an S3 ETag)
# =============================================================================
comptime _FNV1A_64_OFFSET_BASIS: UInt64 = 14695981039346656037
comptime _FNV1A_64_PRIME: UInt64 = 1099511628211


@always_inline
def _hex_nibble(nib: Int) -> String:
    # SAFE: `chr` on a HEX DIGIT code point (0x30-0x39 / 0x61-0x66), never on a
    # stored byte. `nib` is masked to 0-15 by every caller, so the result is
    # ASCII by construction and `chr` is the correct code-point-to-character
    # conversion here. NOT a member of the `chr(Int(byte))` decode class.
    if nib < 10:
        return chr(0x30 + nib)
    return chr(0x61 + nib - 10)


def _content_etag(bytes: List[UInt8]) -> String:
    """Quoted FNV-1a-64 hex over the bytes — the S3-ETag analog (single-part
    ETag IS a content hash). Stable across runs; a different body hashes
    differently so an `If-Match` on a stale etag is detected. Quoted to mirror
    the in-memory conformer's `"<n>"` etag shape (opaque at the trait
    boundary)."""
    var h = _FNV1A_64_OFFSET_BASIS
    for i in range(len(bytes)):
        h = h ^ UInt64(Int(bytes[i]))
        h = h * _FNV1A_64_PRIME
    var out = String('"')
    var shift = 60
    while shift >= 0:
        out += _hex_nibble(Int((h >> UInt64(shift)) & UInt64(0xF)))
        shift -= 4
    out += '"'
    return out^


# =============================================================================
# Flat-key filename codec — percent-encode every non-[A-Za-z0-9._-] byte.
# =============================================================================
@always_inline
def _is_safe_fname_byte(b: UInt8) -> Bool:
    # [A-Za-z0-9._-]
    var c = Int(b)
    if c >= ord("A") and c <= ord("Z"):
        return True
    if c >= ord("a") and c <= ord("z"):
        return True
    if c >= ord("0") and c <= ord("9"):
        return True
    return c == ord(".") or c == ord("_") or c == ord("-")


@always_inline
def _hex_upper(nib: Int) -> String:
    # SAFE: same as `_hex_nibble` — `chr` on a HEX DIGIT code point over a
    # 0-15 argument, not on a stored byte. NOT the `chr(Int(byte))` class.
    if nib < 10:
        return chr(0x30 + nib)
    return chr(0x41 + nib - 10)  # 'A'..'F'


def _encode_key_to_fname(key: String) -> String:
    """Percent-encode `key` into a single filesystem-safe filename. `/` → `%2F`;
    every non-safe byte → `%XX`. Deterministic + reversible — the same key
    always maps to the same filename across process runs (durability)."""
    var bs = key.as_bytes()
    var out = String("")
    for i in range(len(bs)):
        var b = bs[i]
        if _is_safe_fname_byte(b):
            # SAFE: guarded by `_is_safe_fname_byte`, which admits only
            # [A-Za-z0-9._-] — every admitted byte is < 0x80, where
            # `chr(Int(b))` is the IDENTITY. Every OTHER byte takes the `%XX`
            # arm below, so no byte >= 0x80 ever reaches this line. ⛔ DO NOT
            # "fix" this to a byte-exact build: it is already byte-exact, and a
            # rewrite here is a correctness regression risk for no gain. (The
            # DECODE side, `_decode_fname_to_key`, is where the real defect was.)
            out += chr(Int(b))
        else:
            out += "%"
            out += _hex_upper(Int(b) >> 4)
            out += _hex_upper(Int(b) & 0xF)
    return out^


@always_inline
def _hex_val(b: UInt8) -> Int:
    var c = Int(b)
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    return -1


def _decode_fname_to_key(fname: String) -> String:
    """Inverse of `_encode_key_to_fname`: decode a `%XX`-encoded filename back
    to its object key. A malformed `%` escape is passed through literally (it
    cannot occur for filenames this store wrote, so this is defensive only)."""
    var bs = fname.as_bytes()
    var n = len(bs)
    # BYTE-EXACT rebuild. ⛔ NOT `out += chr(...)` on EITHER arm.
    #
    # ⚠ THE `%XX` ARM WAS INVISIBLE TO A `chr(Int(` GREP. It was spelled
    # `out += chr((hi << 4) | lo)`, which is the SAME defect — `(hi << 4) | lo`
    # is a BYTE 0x00-0xFF, and `chr` maps a CODE POINT to its UTF-8 ENCODING, so
    # every decoded byte >= 0x80 was RE-ENCODED into two. That made this
    # function a NON-INVERSE of `_encode_key_to_fname`: a key holding `é`
    # (C3 A9) encoded to `%C3%A9` and decoded back to `Ã©` (C3 83 C2 A9).
    #
    # THE FAILURE MODE. `list_with_delimiter` calls this on every filename it
    # lists, matches the result against a CORRECT-UTF-8 caller prefix
    # (`_starts_with`), and returns it as `ObjectMeta.path`. So a non-ASCII
    # object key was (a) silently dropped from a listing under a non-ASCII
    # prefix, and (b) handed back to the caller mojibaked, where re-encoding it
    # produced a DIFFERENT filename and the object 404'd.
    #
    var out_bytes = List[UInt8]()
    var i = 0
    while i < n:
        if bs[i] == UInt8(ord("%")) and i + 2 < n:
            var hi = _hex_val(bs[i + 1])
            var lo = _hex_val(bs[i + 2])
            if hi >= 0 and lo >= 0:
                out_bytes.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        out_bytes.append(bs[i])
        i += 1
    return String(StringSlice(unsafe_from_utf8=Span(out_bytes)))


# =============================================================================
# Module-private POSIX FFI helpers (mirror `komira_fs.local_fs`)
# local_fs's helpers are private to komira_fs, so the FFI shape is
# re-derived here against the SAME C shim symbols komira_fs_posix defines.
# =============================================================================


def _mkdir_one(path: String) raises:
    """Create the SINGLE directory `path` (its parent must already exist). Mode
    0755. An already-existing directory is NOT an error (EEXIST tolerated); a real
    failure raises."""
    if path.byte_length() == 0:
        return
    var p = path
    # SAFETY: `p` holds the path bytes alive across the synchronous syscall; the
    # kernel copies the NUL-terminated path and returns. The pointer does not
    # escape. `komira_mkdir` is the renamed fixed-arity shim around mkdir(2)
    # (sidesteps the stdlib's reserved `mkdir` FFI declaration, which conflicts
    # in this binary's large transitive closure — see _posix_shim.c).
    var rc = external_call["komira_mkdir", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(0o755)
    )
    if Int(rc) != 0:
        # EEXIST (17) is fine — the dir already exists (re-open of an existing
        # KG). errno is not surfaced across the FFI, so we re-probe existence:
        # if a regular fopen of a child cannot tell us, probe directory-ness.
        if _is_existing_dir(path):
            return
        raise Error(
            "LocalFsConditionalStore: failed to create root dir '" + path
            + "' (mkdir rc=" + String(Int(rc)) + "; not an existing directory)"
        )


def _mkdir_p_root(path: String) raises:
    """Ensure the root directory `path` exists, CREATING MISSING PARENTS
    (`mkdir -p` semantics). Keys are flat-encoded (no nested dirs), so only the
    ROOT is ever created — but the root itself may be a MULTI-SEGMENT path.

    ★ WHY RECURSIVE. `mkdir(2)` is not recursive: a root such as
    `.tool/<env>/outputs` fails with ENOENT on the very first use when `.tool`
    does not exist yet. A single-level mkdir only works for callers whose parent
    directory happens to pre-exist. Walking the segments and tolerating EEXIST
    at each level is the standard fix (a single-segment path takes exactly one
    `mkdir`)."""
    if path.byte_length() == 0:
        return
    var b = path.as_bytes()
    # BYTE-EXACT accumulation. ⛔ NOT `acc += chr(c)` — `chr` maps a CODE POINT
    # to its UTF-8 ENCODING, so a root path holding a byte >= 0x80 was
    # RE-ENCODED and this created a DIFFERENTLY-NAMED directory from the one the
    # store then binds to `self._root`. Every subsequent open under `_root`
    # then hit a path that does not exist — the same "a re-encoded path does not
    # exist on disk" failure that `local_fs` readdir produced, in the WRITE
    # direction.
    var acc_bytes = List[UInt8]()
    var slash = UInt8(ord("/"))
    var i = 0
    while i < len(b):
        if b[i] == slash:
            # A leading "/" (absolute root) or an empty segment ("//") has
            # nothing to create — accumulate and continue.
            if len(acc_bytes) > 0 and not (
                len(acc_bytes) == 1 and acc_bytes[0] == slash
            ):
                _mkdir_one(String(StringSlice(unsafe_from_utf8=Span(acc_bytes))))
            acc_bytes.append(slash)
        else:
            acc_bytes.append(b[i])
        i += 1
    if len(acc_bytes) > 0 and not (
        len(acc_bytes) == 1 and acc_bytes[0] == slash
    ):
        _mkdir_one(String(StringSlice(unsafe_from_utf8=Span(acc_bytes))))


def _is_existing_dir(path: String) -> Bool:
    """True iff `path` names an existing DIRECTORY.

    Portable `access(3)` trick: `access("<path>/.", F_OK)` succeeds ONLY when
    `<path>` is a directory — appending `/.` to a regular file (or to a
    non-existent path) is not a valid path, so `access` returns non-zero; on a
    directory `<path>/.` resolves to the directory itself and returns 0.

    ★ WHY NOT `opendir`/`closedir` (this WAS an opendir probe): a bare
    `external_call["closedir", ...]` legalizes fine in a small closure, but in a
    LARGE binary whose transitive closure ALSO pulls std/ffi's own `closedir`
    declaration (different arg type) the two conflicting declarations fail Mojo's
    external-call legalization — "existing function with conflicting signature",
    then "failed to legalize operation 'pop.external_call'" — which a large
    binary linking this store can hit. Same class as the `komira_mkdir` rename
    above; here the
    `access` trick avoids needing a shim symbol at all. The identical rationale is
    documented at `komira_core_ffi.posix._path_is_directory`, which this
    mirrors."""
    var probe = path + String("/.")
    # SAFETY: synchronous `access(2)`; `probe` pins the path bytes across the
    # call; no pointer escapes. F_OK == 0.
    var rc = external_call["access", Int32](
        probe.as_c_string_slice().unsafe_ptr(), Int32(0)
    )
    return rc == 0


def _write_atomic(dir: String, final_path: String, bytes: List[UInt8]) raises:
    """Durably write `bytes` to `final_path` via WRITE-TEMP-THEN-ATOMIC-RENAME.

    Writes to a unique sibling temp file in the SAME directory (so `rename(2)`
    is intra-filesystem and therefore atomic), fsyncs it, then renames it over
    `final_path`. A concurrent / post-crash reader sees either the OLD bytes or
    the NEW bytes — never a torn mix. Used by `put` + the If-Match advance."""
    var tmp = final_path + ".tmp." + _unique_suffix()
    var w = RawWriteFd.open_truncate(tmp)
    if len(bytes) > 0:
        w.write_bytes(Span(bytes))
    w.fsync()
    w.close()
    # rename(2) — atomic within one filesystem (the temp sibling is in `dir`).
    var src = tmp
    var dst = final_path
    _ = dir  # `dir` documents the same-FS invariant; unused at runtime.
    # SAFETY: both path Strings are pinned by the `src`/`dst` locals across the
    # synchronous syscall; the kernel copies the NUL-terminated paths. No
    # pointer escapes. `rename` is fixed-arity.
    var rc = external_call["rename", Int32](
        src.as_c_string_slice().unsafe_ptr(),
        dst.as_c_string_slice().unsafe_ptr(),
    )
    if Int(rc) != 0:
        # Best-effort cleanup of the temp file so a failed rename does not leak.
        _remove_best_effort(tmp)
        raise Error(
            "LocalFsConditionalStore: atomic rename failed ('" + tmp + "' -> '"
            + final_path + "', rc=" + String(Int(rc)) + ")"
        )


def _remove_best_effort(path: String):
    """libc `remove(3)`, swallowing the rc (idempotent delete)."""
    var p = path
    # SAFETY: `p` pins the path bytes across the synchronous syscall; no pointer
    # escapes. `remove` is fixed-arity.
    _ = external_call["remove", Int32](p.as_c_string_slice().unsafe_ptr())


def _unique_suffix() -> String:
    """A per-call unique temp-file suffix (high-res-clock-derived, mixed by the
    same dependency-free xorshift `cas_manifest.mojo` uses). Single-threaded
    use; only needs intra-process uniqueness so two writes
    in the same directory never collide on a temp filename."""
    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        out += _hex_nibble(Int((x >> UInt64(shift)) & UInt64(0xF)))
        shift -= 4
    return out^


def _list_dir_fnames(dir: String) raises -> List[String]:
    """Shallow (one-level) listing of `dir`'s immediate child filenames via the
    `komira_list_dir_shallow` C shim (the SAME shim `komira_fs` uses;
    threaded into every binary by `link_posix_shim=True`). Returns each child's
    NAME (regular files only — we filter the dir tag). A non-existent dir
    (ENOENT) yields an EMPTY list; every other failure (the shim returns the
    opendir / readdir / lstat errno) RAISES naming `dir` and the errno — a
    root that exists but cannot be read is not an empty store.

    The shim hands back one heap buffer of `<tag><name>\\0` records; we copy each
    name into an owned String and `komira_free` the buffer. NO struct-offset
    arithmetic in Mojo — only the FFI out-param slots, confined here."""
    var buf_slot = Array[UInt8, 8](fill=UInt8(0))
    var len_slot = Array[UInt8, 8](fill=UInt8(0))
    var d = dir
    var c_dir = d.as_c_string_slice().unsafe_ptr()
    # SAFETY: `buf_slot`/`len_slot` are stack-local out-param slots the shim
    # writes through; they outlive the synchronous call. `c_dir` is pinned by
    # `d` across the call. The malloc'd record buffer's ownership transfers to
    # this frame and is freed via `komira_free` before return. Single-syscall
    # FFI carve-out (identical to `_local_fs_list_dir_shallow`).
    var buf_pp = UnsafePointer(to=buf_slot).bitcast[UInt8]()
    var len_pp = UnsafePointer(to=len_slot).bitcast[UInt8]()
    var rc = external_call["komira_list_dir_shallow", Int32](
        c_dir, buf_pp, len_pp
    )
    if Int(rc) != 0:
        # FFI-BOUNDARY: `komira_fs_enoent` / `komira_fs_errno_name` live in
        # komira_fs's `_fs_shim.c` (linked through komira_fs_posix); errno
        # numbers are never spelled in Mojo. Nothing was allocated on failure.
        if rc == external_call["komira_fs_enoent", Int32]():
            return List[String]()
        var nb = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: `nb` is a stack-local 32-byte buffer that outlives the
        # synchronous call; the shim writes at most 32 bytes and keeps nothing.
        var nlen = external_call["komira_fs_errno_name", Int64](
            rc, UnsafePointer(to=nb).bitcast[UInt8](), Int64(32)
        )
        var name = List[UInt8]()
        for k in range(Int(nlen)):
            name.append(nb[k])
        raise Error(
            "LocalFsConditionalStore: shallow dir listing failed for '" + dir
            + "': errno " + String(Int(rc)) + " ("
            + String(StringSlice(unsafe_from_utf8=Span(name))) + ")"
        )
    # The malloc'd char* the shim wrote into the slot — the documented
    # kernel/malloc-returned carve-out, used as a LOCAL, never a field.
    var out_buf = buf_pp.bitcast[UnsafePointer[UInt8, MutAnyOrigin]]()[0]
    var out_len = len_pp.bitcast[Int64]()[0]
    var names = List[String]()
    var n = Int(out_len)
    var i = 0
    while i < n:
        var tag = out_buf[i]
        i += 1
        var start = i
        while i < n and out_buf[i] != UInt8(0):
            i += 1
        # BYTE-EXACT decode of the record's `<name>` run. ⛔ NOT
        # `chr(Int(out_buf[j]))` — this body mirrors
        # `komira_fs/local_fs._local_fs_list_dir_shallow`: `chr` maps a
        # CODE POINT to its UTF-8 ENCODING, so every byte >= 0x80 would be
        # RE-ENCODED into two and the resulting object NAME would not exist on
        # disk.
        var name_bytes = List[UInt8]()
        for j in range(start, i):
            name_bytes.append(out_buf[j])
        # 'F' = regular file (the object files this store writes); skip 'D'.
        if tag == UInt8(ord("F")):
            names.append(String(StringSlice(unsafe_from_utf8=Span(name_bytes))))
        i += 1  # skip the NUL separator
    _ = external_call["komira_free", Int32](out_buf)
    return names^


# =============================================================================
# LocalFsConditionalStore — the CloneableConditionalWriteStore conformer.
# =============================================================================


struct LocalFsConditionalStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Durable, zero-dependency local-disk `CloneableConditionalWriteStore`.

    Persists the full CAS-manifest object lifecycle to plain files under one
    configured root directory — NO MinIO, NO S3, NO SigV4. The drop-in
    replacement for `S3ConditionalStore[C]` in the personal-KG storage seam.

    The atomicity contract (see module header): create-if-absent via
    `O_CREAT|O_EXCL` (the 412-or-win linearization point), If-Match CAS via
    read-compare + write-temp-then-atomic-rename, content-hash etags (S3
    single-part ETag analog — crash-safe, no counter state).

    Fields:
      * `_root: String` — the root directory all object files live under.
        Flat key→filename encoding means NO nested dirs; one mkdir of `_root`
        on construction suffices.

    `clone()` returns a fresh handle bound to the SAME `_root` — the filesystem
    IS the shared backing store, so both the manifest handle and the
    object-write handle (the `KgSnapshotStore` store-sharing seam) read/write
    the same files. Content-hash etags need no shared counter state, so the
    clone shares nothing but the root path.

    Encapsulation: `_root` is a single owned String; ZERO UnsafePointer in any
    public signature; ZERO wildcard-origin field; heap-reuse N/A.
    """

    var _root: String

    def __init__(out self, var root: String) raises:
        """Construct bound to `root` (the storage directory), creating it if
        absent. An existing directory is reused (durability — a relaunch
        re-opens the previously-written state)."""
        _mkdir_p_root(root)
        self._root = root^

    def __init__(out self, var root: String, _internal: Bool):
        """INFALLIBLE fieldwise ctor for `clone()` — the root already exists
        (the original ctor created it), so this skips the fallible mkdir."""
        self._root = root^
        _ = _internal

    def clone(self) -> Self:
        """Fresh handle bound to the SAME `_root`. INFALLIBLE: the root dir
        already exists (created by the original ctor), so no mkdir. Both handles
        reach the same files — the filesystem is the shared backing store (the
        store-sharing seam `KgSnapshotStore` parametrizes over)."""
        return Self(self._root.copy(), True)

    @always_inline
    def root(self) -> String:
        """The root directory this store persists object files under."""
        return String(self._root)

    @always_inline
    def _path_for_key(self, key: String) -> String:
        """Map an object key to its flat-encoded file path under `_root`."""
        return self._root + "/" + _encode_key_to_fname(key)

    # =========================================================================
    # ObjectStore base surface (head / list_with_delimiter / coalesce_policy).
    # =========================================================================

    def head(self, path: Path) raises -> ObjectMeta:
        """HEAD — size + content-hash etag, no body. Raises not_found (404) iff
        the object file is absent (ENOENT); any other failure raises an I/O
        error naming the errno (see `local_fs_file_read`)."""
        var bytes = _read_whole_file(self._path_for_key(path.raw()))
        var etag = _content_etag(bytes)
        return ObjectMeta(
            path.raw(), Int64(len(bytes)), etag^, Int64(-1), String("")
        )

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """List object keys under `prefix` (the recovery/discovery surface).

        Shallow-reads the root dir, decodes each flat filename back to its
        object key, and returns those whose key starts with `prefix.raw()` —
        the same linear-scan-then-prefix-match the in-memory conformer uses.
        `common_prefixes` is left empty (the CAS recovery path only consumes
        `objects`, sorting chunk keys lexically itself)."""
        var p = prefix.raw()
        var objects = List[ObjectMeta]()
        # An absent root (ENOENT) → empty listing (e.g. first read on a fresh
        # KG before any write). A root that exists but is not a directory, or
        # cannot be checked, RAISES: it is a broken store, not an empty one.
        if not _root_is_listable(self._root):
            return ListResult(objects^, List[String]())
        var fnames = _list_dir_fnames(self._root)
        for i in range(len(fnames)):
            # Skip our own temp files (".tmp.<nonce>"); they are not objects.
            if _is_temp_fname(fnames[i]):
                continue
            var key = _decode_fname_to_key(fnames[i])
            if _starts_with(key, p):
                # HEAD-equivalent: read size + etag. Manifest objects are small.
                var bytes = _read_whole_file(self._root + "/" + fnames[i])
                objects.append(
                    ObjectMeta(
                        key^, Int64(len(bytes)), _content_etag(bytes),
                        Int64(-1), String(""),
                    )
                )
        return ListResult(objects^, List[String]())

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    # =========================================================================
    # ConditionalWriteStore verb set — the CAS-manifest lifecycle.
    # =========================================================================

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        """PUT `bytes` at `path` conditioned on `precond`.

          * create-if-absent (`If-None-Match: *` / exact): atomic
            `O_CREAT|O_EXCL`; EEXIST → precondition (412).
          * `If-Match: <etag>`: read current etag; mismatch / absent → 412;
            match → write-temp-then-atomic-rename.
          * NONE: unconditional write-temp-then-atomic-rename.
        """
        var key = path.raw()
        var fpath = self._path_for_key(key)
        var new_etag = _content_etag(bytes)

        if precond.is_create():
            # Atomic create-if-absent. O_EXCL → EEXIST iff the key exists. The
            # create IS the linearization point (the slot's create-winner).
            # Presence probe: ENOENT → absent; any other stat failure RAISES
            # (a key that cannot be checked is not "absent").
            var existed = _object_file_present(fpath)
            if existed:
                raise Error(
                    "LocalFsConditionalStore.conditional_put: precondition"
                    " (412) — key already exists (If-None-Match): " + key
                )
            # Open O_EXCL: if a racing creator beat us between the probe and
            # here, the EXCL open fails. We MUST distinguish a TRUE create-loss
            # (EEXIST — someone else created the key, the expected 412 a slot-
            # race / claim loser sees) from ANY OTHER failure (ENOSPC / EIO /
            # EMFILE / EACCES, or a write/fsync/close failure AFTER a successful
            # create). FAIL-CLOSED: only a TRUE create-loss raises the
            # precondition(412); every other failure raises a NON-precondition
            # (transport/IO-shaped) Error. Conflating the two was a fail-open
            # data-loss bug: a real IO failure surfaced as a fake-412 would make
            # a `claim_partition` loser silently skip a partition NO worker
            # actually claimed.
            var res = _create_exclusive_and_write(fpath, bytes)
            if res == _CREATE_OK:
                return ObjectMeta(
                    key, Int64(len(bytes)), new_etag^, Int64(-1), String("")
                )
            if res == _CREATE_LOST_EEXIST:
                # TRUE create-loss: the EXCL open failed AND the file is present
                # ⇒ a racing creator won between our probe and our open. This is
                # the atomic 412 (byte-identical to the prior behavior).
                raise Error(
                    "LocalFsConditionalStore.conditional_put: precondition"
                    " (412) — exclusive create lost the race for: " + key
                )
            # _CREATE_IO_ERROR — a real create/write/fsync/close failure that is
            # NOT a create-loss. Raise a transport/IO-shaped Error whose message
            # contains NEITHER "412" NOR "precondition" so it is NOT misread as a
            # slot-race loss anywhere downstream (fail closed).
            raise Error(
                "LocalFsConditionalStore.conditional_put: I/O error on"
                " exclusive create (not a create-loss; disk full / permission /"
                " transient) for: " + key
            )

        if precond.is_if_match():
            var existed = _object_file_present(fpath)
            if not existed:
                raise Error(
                    "LocalFsConditionalStore.conditional_put: precondition"
                    " (412) — If-Match on absent key: " + key
                )
            var cur = _read_whole_file(fpath)
            if _content_etag(cur) != precond.etag:
                raise Error(
                    "LocalFsConditionalStore.conditional_put: precondition"
                    " (412) — If-Match etag mismatch: " + key
                )
            _write_atomic(self._root, fpath, bytes)
            return ObjectMeta(
                key, Int64(len(bytes)), new_etag^, Int64(-1), String("")
            )

        # NONE — unconditional write-or-overwrite, atomically.
        _write_atomic(self._root, fpath, bytes)
        return ObjectMeta(
            key, Int64(len(bytes)), new_etag^, Int64(-1), String("")
        )

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        """Ranged byte-fetch `[start, start+length)`. Reads the whole object
        (local files are cheap) and slices. Zero-length is a no-op (empty)."""
        if length <= Int64(0):
            return List[UInt8]()
        var whole = _read_whole_file(self._path_for_key(path.raw()))
        var s = Int(start)
        var ln = Int(length)
        if s < 0 or s + ln > len(whole):
            raise Error(
                "LocalFsConditionalStore.get_range: out-of-range read (start="
                + String(s) + ", length=" + String(ln) + ", size="
                + String(len(whole)) + ") key=" + path.raw()
            )
        var out = List[UInt8]()
        for i in range(s, s + ln):
            out.append(whole[i])
        return out^

    def get(self, path: Path) raises -> List[UInt8]:
        """Full-object fetch. Raises not_found (404) iff the file is absent
        (ENOENT); any other failure raises an I/O error naming the errno."""
        return _read_whole_file(self._path_for_key(path.raw()))

    def delete(self, path: Path) raises -> None:
        """DELETE — idempotent (an absent key succeeds, S3 semantics)."""
        _remove_best_effort(self._path_for_key(path.raw()))


# =============================================================================
# Free helpers used by the struct (kept out of the struct body for clarity).
# =============================================================================


# Tri-state classification for `_create_exclusive_and_write` — distinguishes a
# TRUE create-loss (EEXIST) from a real I/O failure so the create-CAS path can
# FAIL CLOSED (a real failure must NOT masquerade as a 412). See the
# `conditional_put` create arm.
comptime _CREATE_OK: Int = 0  # exclusive create + write + fsync + close OK
comptime _CREATE_LOST_EEXIST: Int = 1  # EXCL open failed AND the file is present
comptime _CREATE_IO_ERROR: Int = 2  # any other create/write/fsync/close failure


def _create_exclusive_and_write(path: String, bytes: List[UInt8]) -> Int:
    """Atomically create `path` (O_CREAT|O_EXCL) and write `bytes` into it.

    Returns a TRI-STATE classification (NOT a bare Bool — the caller must
    distinguish a true create-loss from a real I/O error to fail closed):

      * `_CREATE_OK`          — the exclusive create + write + fsync + close all
                                succeeded; `path` now holds `bytes`.
      * `_CREATE_LOST_EEXIST` — the exclusive create FAILED and `path` EXISTS
                                ⇒ a racing creator won (EEXIST). This is the
                                atomic 412 (the slot-race / claim loser outcome).
      * `_CREATE_IO_ERROR`    — the exclusive create FAILED and `path` is ABSENT
                                (ENOSPC / EIO / EMFILE / EACCES at create), OR a
                                write/fsync/close FAILED after a successful
                                create. NOT a create-loss — a real I/O failure
                                the caller MUST surface as a non-precondition.

    WHY THE RE-PROBE (and not errno). `open_create_exclusive` surfaces a generic
    Error on ANY openat failure (errno is not threaded across the FFI shim). With
    O_EXCL the ONLY reason the file can be PRESENT after a FAILED create is that a
    racing creator already made it — i.e. EEXIST. So re-probing existence after a
    create-open failure POSITIVELY identifies EEXIST without an FFI change
    (errno-surfacing would require a new C shim across the posix_io boundary; the
    re-probe is self-contained here and exactly equivalent for the O_EXCL case).
    A write/fsync/close failure AFTER a successful create is unambiguously an I/O
    error: WE created the file (so it exists), but the bytes did not land — never
    a create-loss, so it is classified `_CREATE_IO_ERROR` directly.
    """
    # Step 1 — the exclusive create-open is the linearization point. Separate it
    # from the write so we can tell a failed CREATE (re-probe to classify
    # EEXIST vs I/O) from a failed WRITE-after-create (always an I/O error).
    var w: RawWriteFd
    try:
        w = RawWriteFd.open_create_exclusive(path)  # EEXIST → raises
    except:
        # The exclusive create failed. Re-probe: present ⇒ a racing creator won
        # (EEXIST, the true 412); absent ⇒ a real create failure (ENOSPC / EIO /
        # EMFILE / EACCES / …) that must surface as an I/O error, NOT a fake-412.
        # A probe that itself fails proves nothing about EEXIST: fail closed.
        try:
            if _object_file_present(path):
                return _CREATE_LOST_EEXIST
        except:
            pass
        return _CREATE_IO_ERROR

    # Step 2 — the create succeeded; WE own the slot. A write/fsync/close failure
    # here is a real I/O error (NOT a create-loss): the file exists because we
    # made it, but the bytes did not durably land. (A torn-create chunk — present
    # but zero/partial — is re-derived by the protocol's LIST recovery; surfacing
    # it as an I/O error is correct and fail-closed.)
    try:
        if len(bytes) > 0:
            w.write_bytes(Span(bytes))
        w.fsync()
        w.close()
        return _CREATE_OK
    except:
        return _CREATE_IO_ERROR


@always_inline
def _is_temp_fname(fname: String) -> Bool:
    """True iff `fname` is one of THIS store's in-flight temp files
    (`<final>.tmp.<nonce>`). They must be excluded from `list_with_delimiter`
    so a crash mid-rename never surfaces a half-written object as a key."""
    return fname.find(".tmp.") >= 0


@always_inline
def _starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True
