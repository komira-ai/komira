from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./leaks_by_default.so")
    if lib.check_symbol("komira_example_add"):
        raise Error("komira_example_add leaked into the dynamic symbol table")
