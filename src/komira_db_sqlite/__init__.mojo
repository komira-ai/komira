"""`komira_db_sqlite` — the SQLite driver for `komira_db`.

`SqliteDatabase` conforms to the backend-generic `SqlDatabase` trait over the
in-process libsqlite3 library. The FFI declarations live in `ffi.mojo`, which
is internal: it is not re-exported here, and only `sqlite_driver.mojo` imports
it. The driver hides every UnsafePointer and opaque handle behind the
`Database` trait surface, so none crosses the package boundary.

Public surface:
  SqliteDatabase — the SQLite `SqlDatabase` conformer
"""

from komira_db_sqlite.sqlite_driver import SqliteDatabase
