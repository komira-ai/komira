# =============================================================================
# komira_db_sqlite/ffi.mojo — thin external_call wrappers over libsqlite3.
# =============================================================================
#
# The FFI BOUNDARY for the sqlite backend.
# The same pattern as the s2n TLS bindings in `komira_http`:
# a module of thin `external_call["<symbol>", RetType](args)` wrappers over the
# system `libsqlite3`, each typing the C args + return for the Mojo type
# checker. Bodies do NOTHING other than the external_call.
#
# sqlite's public API is entirely NON-variadic (`sqlite3_open_v2`,
# `sqlite3_prepare_v2`, `sqlite3_bind_*`, `sqlite3_column_*`, ...), so a direct
# `external_call` suffices — NO C shim is needed (unlike the variadic posix
# shim). The opaque handles (`sqlite3*` / `sqlite3_stmt*`) are passed as
# `UnsafePointer[UInt8, _FFI_ORIGIN]` (= `SqliteHandle`) — the FFI-POD
# opaque-handle shape. The origin is the CONCRETE `_FFI_ORIGIN`
# (StaticConstantOrigin), NOT the banned `MutExternalOrigin` wildcard.
#
# ENCAPSULATION DISCIPLINE:
# This module IS the FFI boundary. UnsafePointer / `_FFI_ORIGIN` types in
# signatures here are PERMITTED because:
#   - This module is inside `src/komira_db_sqlite/`, the canonical FFI
#     carve-out for the sqlite backend.
#   - Every `external_call` site carries a `# SAFETY:` comment.
#   - The safe `SqliteDatabase` driver (sqlite_driver.mojo) is the
#     public-facing surface; it hides these declarations behind safe APIs
#     (execute / query / claim_pending returning DbRows). No UnsafePointer
#     and no opaque handle crosses the komira_db_sqlite module boundary.
#
# This module MUST NOT be imported by anything other than `sqlite_driver.mojo`.
#
# LINKING: `libsqlite3` is a ubiquitous system lib (present on macOS via the
# dyld shared cache + every Linux). A binary that reaches the sqlite driver
# links it with `-lsqlite3`. On macOS `ld` resolves `-lsqlite3` from the dyld
# shared cache (no on-disk `.dylib` needed); on Linux from the system
# `libsqlite3.so`.
# No vendored archive, no network fetch — as ubiquitous as `libm`.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.collections import Optional


# -----------------------------------------------------------------------------
# The FFI origin (FFI-BOUNDARY).
#
# Mojo 1.0.0b2 removed the `UnsafePointer[T]()` null constructor and the
# `Boolable`/`__bool__` conversion (non-null-by-design; see
# the Mojo non-null-pointer proposal). Instead of a `MutExternalOrigin`
# wildcard (banned), this uses `StaticConstantOrigin`,
# a CONCRETE (non-wildcard) origin valid for the FFI ABI boundary. The opaque
# `sqlite3*` / `sqlite3_stmt*` handles are passed BY VALUE to `external_call`
# and never written through Mojo-side, so an immutable static origin is sound
# (the same shape the crypto FFI bindings use). Data-buffer pointers
# (path / SQL / bound text+blob bytes) are coerced to the same origin in the
# driver's `_*_ptr` helpers; the SAFETY contract is that the caller holds the
# buffer's real origin in scope across the synchronous external_call (sqlite
# copies bound bytes via SQLITE_TRANSIENT and retains no pointer past the call).
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null_byte() -> _FfiByte:
    """A raw NULL FFI byte pointer (replaces the b2-removed
    `UnsafePointer[UInt8, o]()` null ctor) for explicit C-NULL arguments
    (default VFS / SQLITE_STATIC destructor sentinel).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the Mojo non-null-pointer proposal), and `None`
    # is the all-zero (NULL) bit pattern. We reinterpret an `Optional`-None
    # slot to obtain a raw NULL WITHOUT the removed null ctor and WITHOUT the
    # banned `unsafe_from_address=Int(0)`. sqlite treats NULL VFS as the
    # default and a NULL destructor as SQLITE_STATIC (we pass non-NULL bytes
    # only with SQLITE_TRANSIENT, so the static-NULL case is for the empty /
    # length-0 binds where sqlite reads nothing).
    """
    var none: Optional[_FfiByte] = None
    return UnsafePointer(to=none).bitcast[_FfiByte]()[]


# -----------------------------------------------------------------------------
# sqlite result codes (sqlite3.h) — the subset the driver branches on.
# -----------------------------------------------------------------------------
comptime SQLITE_OK: Int32 = 0
comptime SQLITE_ROW: Int32 = 100
comptime SQLITE_DONE: Int32 = 101
comptime SQLITE_CONSTRAINT: Int32 = 19

# sqlite3_open_v2 flags (sqlite3.h).
comptime SQLITE_OPEN_READWRITE: Int32 = 0x00000002
comptime SQLITE_OPEN_CREATE: Int32 = 0x00000004

# sqlite3_column_type fundamental datatypes (sqlite3.h).
comptime SQLITE_INTEGER: Int32 = 1
comptime SQLITE_FLOAT: Int32 = 2
comptime SQLITE_TEXT: Int32 = 3
comptime SQLITE_BLOB: Int32 = 4
comptime SQLITE_NULL_TYPE: Int32 = 5

# The destructor sentinel for sqlite3_bind_{text,blob}. SQLITE_TRANSIENT
# (== -1 cast to the destructor fn-ptr type) tells sqlite to make its OWN
# private copy of the bound bytes BEFORE returning, so our Mojo-side buffer
# need not outlive the bind call. (SQLITE_STATIC == 0 would require the bytes
# to outlive the statement — unsafe across our scope boundaries.) Passed as a
# raw pointer value of -1.
comptime SQLITE_TRANSIENT_ADDR: Int = -1


# An opaque C handle (sqlite3* / sqlite3_stmt*) — the FFI-POD opaque-pointer
# shape. Never dereferenced on the Mojo side; only handed back to libsqlite3.
# Held as `UInt8*` (the opaque-handle convention — Mojo
# 1.0.0b1's `NoneType`-payload pointers collide with the `None` singleton, so
# `UInt8*` is the correct opaque carrier). Null-checked via `Int(ptr) == 0`.
#
# b2: the origin is the CONCRETE `_FFI_ORIGIN` (StaticConstantOrigin), NOT the
# banned `MutExternalOrigin` wildcard. The handle is opaque-by-value to
# external_call and never dereferenced Mojo-side, so the immutable static
# origin is sound.
comptime SqliteHandle = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def sqlite_null_handle() -> SqliteHandle:
    """A NULL `SqliteHandle` (replaces the b2-removed `SqliteHandle()` null
    ctor) for the driver's null-until-opened `_conn` field and the
    pre-declared-then-reassigned stack out-slots (`handle_local`,
    `stmt_local`).

    # SAFETY: layout-compat `Optional[ptr]`-None reinterpret (same as
    # `_ffi_null_byte`); `None` is the all-zero NULL bit pattern. NOT the
    # banned `unsafe_from_address=Int(0)`. The driver null-checks via
    # `Int(handle) == 0` before any close/finalize (sqlite's free fns are
    # also NULL-safe).
    """
    var none: Optional[SqliteHandle] = None
    return UnsafePointer(to=none).bitcast[SqliteHandle]()[]


# =============================================================================
# Connection lifecycle
# =============================================================================


def sqlite3_open_v2(
    filename: _FfiByte,
    pp_db: UnsafePointer[SqliteHandle, _FFI_ORIGIN],
    flags: Int32,
    z_vfs: _FfiByte,
) -> Int32:
    """Open (or create) a database file. `filename` is a NUL-terminated UTF-8
    path (or ":memory:"); `pp_db` is an out-param the call writes the new
    `sqlite3*` handle into. Returns SQLITE_OK on success.

    Maps to `int sqlite3_open_v2(const char*, sqlite3**, int, const char*)`.
    """
    # SAFETY: `filename` / `z_vfs` are caller-owned NUL-terminated buffers held
    # alive across this call by the SqliteDatabase ctor. `pp_db` is a
    # caller-owned one-slot buffer that receives the opaque handle. No pointer
    # is retained by sqlite past the populated handle. FFI carve-out.
    return external_call["sqlite3_open_v2", Int32](
        filename, pp_db, flags, z_vfs
    )


def sqlite3_close_v2(db: SqliteHandle) -> Int32:
    """Close a database connection, finalizing any leaked statements. Returns
    SQLITE_OK on success.

    Maps to `int sqlite3_close_v2(sqlite3*)`.
    """
    # SAFETY: caller (SqliteDatabase.__del__) ensures exactly-one close per
    # handle; a null-sentinel guard prevents a double-close on moved-from
    # drivers.
    return external_call["sqlite3_close_v2", Int32](db)


def sqlite3_errmsg(db: SqliteHandle) -> _FfiByte:
    """The English text of the most recent error on `db` (NUL-terminated UTF-8,
    owned by sqlite — valid until the next API call). Used for diagnostics.

    Maps to `const char *sqlite3_errmsg(sqlite3*)`.
    """
    # SAFETY: returns a sqlite-owned const char*; the caller copies it into a
    # Mojo String immediately (does not retain the pointer).
    return external_call[
        "sqlite3_errmsg", _FfiByte
    ](db)


def sqlite3_busy_timeout(db: SqliteHandle, ms: Int32) -> Int32:
    """Arm this connection's busy handler to sleep/retry for up to `ms`
    milliseconds when a lock is held by another connection.

    The C-API form of `PRAGMA busy_timeout`, and the ONLY safe way to arm a
    connection that is about to touch a WAL database: it is a direct call with
    no statement to prepare, so unlike the PRAGMA it cannot itself lose a race
    to another connection's WAL recovery (`SQLITE_BUSY_RECOVERY`, extended rc
    261) and leave the connection unarmed. A connection that runs its arming
    PRAGMA first and only then reaches WAL is unarmed for exactly the one
    statement that needed the arming.

    Maps to `int sqlite3_busy_timeout(sqlite3*, int ms)`.
    """
    # SAFETY: scalar-args, scalar-return, opaque-handle-arg. No pointer crosses
    # any boundary; sqlite retains nothing.
    return external_call["sqlite3_busy_timeout", Int32](db, ms)


def sqlite3_extended_errcode(db: SqliteHandle) -> Int32:
    """The EXTENDED result code of the most recent failed API call on `db`.

    Load-bearing for diagnosis, not decoration: `sqlite3_errmsg` renders every
    member of the SQLITE_BUSY family as the one string "database is locked",
    and they have opposite remedies. `SQLITE_BUSY` (5) is an ordinary lock wait
    that a busy-timeout fixes; `SQLITE_BUSY_SNAPSHOT` (517) is a stale-snapshot
    write upgrade that NO timeout can ever fix (the fix is `BEGIN IMMEDIATE`);
    `SQLITE_BUSY_RECOVERY` (261) is a collision with WAL recovery. Reporting
    only the text throws the distinction away.

    Maps to `int sqlite3_extended_errcode(sqlite3*)`.
    """
    # SAFETY: scalar-return, opaque-handle-arg. No pointer crosses any boundary.
    return external_call["sqlite3_extended_errcode", Int32](db)


def sqlite3_changes(db: SqliteHandle) -> Int32:
    """The number of rows modified by the most recent INSERT/UPDATE/DELETE on
    `db` (the `execute` rows-affected return).

    Maps to `int sqlite3_changes(sqlite3*)`.
    """
    # SAFETY: scalar-return, opaque-handle-arg. No pointer crosses any boundary.
    return external_call["sqlite3_changes", Int32](db)


# =============================================================================
# Statement lifecycle
# =============================================================================


def sqlite3_prepare_v2(
    db: SqliteHandle,
    z_sql: _FfiByte,
    n_byte: Int32,
    pp_stmt: UnsafePointer[SqliteHandle, _FFI_ORIGIN],
    pz_tail: UnsafePointer[_FfiByte, _FFI_ORIGIN],
) -> Int32:
    """Compile the first SQL statement of `z_sql` into a prepared statement
    written to the `pp_stmt` out-param. `n_byte` < 0 means "read to the first
    NUL"; `pz_tail` (may be null) receives a pointer past the consumed SQL.
    Returns SQLITE_OK on success.

    Maps to `int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**,
    const char**)`.
    """
    # SAFETY: `z_sql` is a caller-owned NUL-terminated buffer alive across the
    # call. `pp_stmt` is a caller-owned one-slot buffer receiving the opaque
    # statement handle. `pz_tail` is a caller-owned slot (or null). FFI
    # carve-out.
    return external_call["sqlite3_prepare_v2", Int32](
        db, z_sql, n_byte, pp_stmt, pz_tail
    )


def sqlite3_step(stmt: SqliteHandle) -> Int32:
    """Advance a prepared statement: SQLITE_ROW (a result row is available),
    SQLITE_DONE (finished), or an error code.

    Maps to `int sqlite3_step(sqlite3_stmt*)`.
    """
    # SAFETY: opaque-handle-arg, scalar-return.
    return external_call["sqlite3_step", Int32](stmt)


def sqlite3_reset(stmt: SqliteHandle) -> Int32:
    """Reset a prepared statement to its pre-step state (re-executable).

    Maps to `int sqlite3_reset(sqlite3_stmt*)`.
    """
    # SAFETY: opaque-handle-arg, scalar-return.
    return external_call["sqlite3_reset", Int32](stmt)


def sqlite3_finalize(stmt: SqliteHandle) -> Int32:
    """Destroy a prepared statement, releasing its resources.

    Maps to `int sqlite3_finalize(sqlite3_stmt*)`.
    """
    # SAFETY: caller (the driver's prepare/step/finalize scope) ensures
    # exactly-one finalize per statement.
    return external_call["sqlite3_finalize", Int32](stmt)


# =============================================================================
# Parameter binding (1-based index)
# =============================================================================


def sqlite3_bind_int64(stmt: SqliteHandle, idx: Int32, v: Int64) -> Int32:
    """Bind an INTEGER parameter (INT8 / TIMESTAMPTZ µs)."""
    # SAFETY: by-value scalar bind; no pointer crosses any boundary.
    return external_call["sqlite3_bind_int64", Int32](stmt, idx, v)


def sqlite3_bind_int(stmt: SqliteHandle, idx: Int32, v: Int32) -> Int32:
    """Bind an INTEGER parameter (INT4)."""
    # SAFETY: by-value scalar bind.
    return external_call["sqlite3_bind_int", Int32](stmt, idx, v)


def sqlite3_bind_text(
    stmt: SqliteHandle,
    idx: Int32,
    text: _FfiByte,
    n: Int32,
    destructor: _FfiByte,
) -> Int32:
    """Bind a TEXT parameter (TEXT / JSONB / JSON-array). `n` is the byte length
    (NOT NUL-terminated; we always pass the explicit length). `destructor` is
    the SQLITE_TRANSIENT sentinel so sqlite copies the bytes before returning.
    """
    # SAFETY: `text` is a caller-owned buffer alive across the call; sqlite
    # copies the bytes (SQLITE_TRANSIENT) so no Mojo buffer is retained.
    return external_call["sqlite3_bind_text", Int32](
        stmt, idx, text, n, destructor
    )


def sqlite3_bind_blob(
    stmt: SqliteHandle,
    idx: Int32,
    blob: _FfiByte,
    n: Int32,
    destructor: _FfiByte,
) -> Int32:
    """Bind a BLOB parameter (UUID 16 bytes / opaque bytes). `n` is the byte
    length; `destructor` is the SQLITE_TRANSIENT sentinel (sqlite copies)."""
    # SAFETY: `blob` is a caller-owned buffer alive across the call; sqlite
    # copies the bytes (SQLITE_TRANSIENT).
    return external_call["sqlite3_bind_blob", Int32](
        stmt, idx, blob, n, destructor
    )


def sqlite3_bind_null(stmt: SqliteHandle, idx: Int32) -> Int32:
    """Bind a NULL parameter (typed NULL)."""
    # SAFETY: index-only bind; no pointer crosses any boundary.
    return external_call["sqlite3_bind_null", Int32](stmt, idx)


# =============================================================================
# Result column readers (0-based index)
# =============================================================================


def sqlite3_column_count(stmt: SqliteHandle) -> Int32:
    """The number of columns in the current result row."""
    # SAFETY: opaque-handle-arg, scalar-return.
    return external_call["sqlite3_column_count", Int32](stmt)


def sqlite3_column_type(stmt: SqliteHandle, col: Int32) -> Int32:
    """The fundamental datatype of result column `col` (SQLITE_INTEGER / FLOAT /
    TEXT / BLOB / NULL)."""
    # SAFETY: opaque-handle-arg + index, scalar-return.
    return external_call["sqlite3_column_type", Int32](stmt, col)


def sqlite3_column_int64(stmt: SqliteHandle, col: Int32) -> Int64:
    """Read result column `col` as a 64-bit integer (INT8 / TIMESTAMPTZ µs)."""
    # SAFETY: opaque-handle-arg + index, scalar-return.
    return external_call["sqlite3_column_int64", Int64](stmt, col)


def sqlite3_column_bytes(stmt: SqliteHandle, col: Int32) -> Int32:
    """The byte length of result column `col`'s TEXT / BLOB value. MUST be read
    in tandem with the matching `_text` / `_blob` pointer (sqlite's type-
    conversion contract: call the value accessor, then `_bytes`)."""
    # SAFETY: opaque-handle-arg + index, scalar-return.
    return external_call["sqlite3_column_bytes", Int32](stmt, col)


def sqlite3_column_text(
    stmt: SqliteHandle, col: Int32
) -> _FfiByte:
    """A pointer to result column `col`'s TEXT bytes (UTF-8, sqlite-owned, valid
    until the next step/reset/finalize). Read the length via
    `sqlite3_column_bytes` immediately after."""
    # SAFETY: returns a sqlite-owned buffer pointer; the driver copies the
    # `_bytes`-many bytes into a Mojo List[UInt8] immediately and never retains
    # the pointer past the column read.
    return external_call[
        "sqlite3_column_text", _FfiByte
    ](stmt, col)


def sqlite3_column_blob(
    stmt: SqliteHandle, col: Int32
) -> _FfiByte:
    """A pointer to result column `col`'s BLOB bytes (sqlite-owned, valid until
    the next step/reset/finalize). Read the length via `sqlite3_column_bytes`
    immediately after."""
    # SAFETY: returns a sqlite-owned buffer pointer; the driver copies the
    # `_bytes`-many bytes into a Mojo List[UInt8] immediately and never retains
    # the pointer past the column read.
    return external_call[
        "sqlite3_column_blob", _FfiByte
    ](stmt, col)


def sqlite3_column_name(
    stmt: SqliteHandle, col: Int32
) -> _FfiByte:
    """A pointer to result column `col`'s name (NUL-terminated UTF-8, sqlite-
    owned). Copied into a Mojo String immediately."""
    # SAFETY: returns a sqlite-owned NUL-terminated const char*; the driver
    # copies it into a Mojo String and does not retain the pointer.
    return external_call[
        "sqlite3_column_name", _FfiByte
    ](stmt, col)
