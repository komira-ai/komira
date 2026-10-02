from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./leaks_by_default.dylib" if CompilationTarget.is_macos() else "./leaks_by_default.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.check_symbol("komira_example_add"):
        raise Error("komira_example_add leaked into the dynamic symbol table")
