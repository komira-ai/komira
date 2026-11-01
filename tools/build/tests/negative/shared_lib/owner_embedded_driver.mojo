from std.ffi import OwnedDLHandle

comptime LIB = "./owner_embedded.so"
comptime OWNER = "libkomira_libc_native.so.1"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.call["native_owner_write_probe", Int64](Int32(100)) != 100:
        raise Error("native_owner_write_probe(100) is not 100")
    # The library is NEEDED on the owner's shared library only when it links
    # it; opening that SONAME finds the loaded copy.
    var owner = OwnedDLHandle(OWNER)
    if not owner.check_symbol("komira_openat_creat"):
        raise Error(OWNER + " does not define komira_openat_creat")
    if not lib.check_symbol("native_owner_write_probe"):
        raise Error("native_owner_write_probe is not exported")
