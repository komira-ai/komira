from std.ffi import OwnedDLHandle, RTLD
from std.sys import CompilationTarget

comptime MACOS = CompilationTarget.is_macos()
comptime LIB = "./dist/spike_native.dylib" if MACOS else "./dist/spike_native.so"
comptime OWNER = "dist/lib/libkomira_libc_native.1.dylib" if MACOS else "dist/lib/libkomira_libc_native.so.1"


def main() raises:
    """A host of spike_native's `[dist]` directory, staged at ./dist.

    The owner's library is in dist/lib/ and nowhere else in the run tree (the
    check stages no `native_owners`), so the open below, RTLD_NOW, resolves
    the library's NEEDED edge on the owner only through `[dist]`: a `[dist]`
    without the owner fails it (tests//negative/shared_lib:dist_without_owner).
    """
    var lib = OwnedDLHandle(LIB, RTLD.NOW | RTLD.LOCAL)
    var got = lib.call["native_owner_write_probe", Int64](Int32(100))
    if got != 100:
        raise Error("native_owner_write_probe(100) from " + LIB + " is " + String(got) + ", not 100")
    # The owner is a file of the directory itself, at the path the library's
    # run path names, as a language package copies it.
    _ = open(OWNER, "r").read_bytes()
    print("ok")
