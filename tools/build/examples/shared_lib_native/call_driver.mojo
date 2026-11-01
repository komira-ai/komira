from std.ffi import OwnedDLHandle

comptime LIB = "./spike_native.so"
comptime OWNER = "libkomira_libc_native.so.1"
comptime OWNED_SYMBOLS = ("komira_openat_creat", "komira_write_bytes", "komira_lseek_end")


def le(data: List[UInt8], at: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(data[at + i]) << (8 * i)
    return v


def c_string(data: List[UInt8], at: Int) raises -> String:
    var end = at
    while data[end] != 0:
        end += 1
    return String(from_utf8=Span(data)[at:end])


def undefined_dynamic_symbols(path: String) raises -> List[String]:
    """The names the library's dynamic symbol table leaves undefined (ELF64,
    little endian): what its loader binds at load time."""
    var data = open(path, "r").read_bytes()
    var shoff = le(data, 0x28, 8)
    var shentsize = le(data, 0x3A, 2)
    var shnum = le(data, 0x3C, 2)
    var names = List[String]()
    for i in range(shnum):
        var sh = shoff + i * shentsize
        if le(data, sh + 4, 4) != 11:  # SHT_DYNSYM
            continue
        var offset = le(data, sh + 0x18, 8)
        var size = le(data, sh + 0x20, 8)
        var strtab = shoff + le(data, sh + 0x28, 4) * shentsize
        var str_offset = le(data, strtab + 0x18, 8)
        for s in range(size // 24):
            var sym = offset + s * 24
            if le(data, sym + 6, 2) == 0:  # SHN_UNDEF
                names.append(c_string(data, str_offset + le(data, sym, 4)))
    return names^


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var got = lib.call["native_owner_write_probe", Int64](Int32(100))
    if got != 100:
        raise Error("native_owner_write_probe(100) is " + String(got) + ", not 100")
    # The library is NEEDED on the owner's shared library. Opening that SONAME
    # finds the copy the loader mapped for the edge; nothing else puts it on a
    # search path.
    var owner = OwnedDLHandle(OWNER)
    if not owner.check_symbol("komira_openat_creat"):
        raise Error(OWNER + " does not define komira_openat_creat")
    # The owner's C is bound to that copy, not embedded: the library's own
    # dynamic symbol table leaves each name undefined.
    var undefined = undefined_dynamic_symbols(LIB)
    comptime for i in range(len(OWNED_SYMBOLS)):
        var found = False
        for name in undefined:
            if name == OWNED_SYMBOLS[i]:
                found = True
        if not found:
            raise Error(OWNED_SYMBOLS[i] + " is defined inside the library: the owner's C is embedded")
    # Keep the library open until here.
    if not lib.check_symbol("native_owner_write_probe"):
        raise Error("native_owner_write_probe is not exported")
    print("ok")
