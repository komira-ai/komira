from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./spike_exact.so")
    if lib.call["spike_c_add", Int32](Int32(40), Int32(2)) != 42:
        raise Error("spike_c_add(40, 2) is not 42")
    # The C dependency's own symbol must not be in the dynamic table.
    if lib.check_symbol("komira_example_add"):
        raise Error("komira_example_add leaked into the dynamic symbol table")
    print("ok")
