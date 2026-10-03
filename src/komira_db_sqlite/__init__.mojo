# =============================================================================
# komira_db/sqlite/__init__.mojo — the sqlite FFI carve-out subpackage.
# =============================================================================
#
# This subpackage holds the FFI BOUNDARY for the sqlite
# backend: `ffi.mojo` (thin external_call wrappers over libsqlite3). It is an
# INTERNAL subpackage — the FFI declarations are NOT re-exported here. The
# safe `SqliteDatabase` driver (komira_db/sqlite_driver.mojo) imports from
# `komira_db.sqlite.ffi` directly and is the only legitimate consumer; it
# hides every UnsafePointer / opaque handle behind the `Database` trait
# surface (the encapsulation rule — no UnsafePointer crosses the
# komira_db module boundary).
# =============================================================================
