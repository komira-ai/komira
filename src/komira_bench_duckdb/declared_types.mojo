# Declared column types (stub, filled in by the next commit).

comptime UNMAPPED_PREFIX: String = "UNMAPPED("


def unmapped_type(raw: String) -> String:
    return String("")


def is_unmapped(declared: String) -> Bool:
    return False


def duckdb_declared_type(raw: String) -> String:
    return String("")
