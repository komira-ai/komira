from syslib_codec import sqlite_is_loadable


@export
def probe_sqlite() abi("C") -> Int32:
    """1 when the codec found SQLite by its bare name, else 0."""
    try:
        return 1 if sqlite_is_loadable() else 0
    except:
        return 0
