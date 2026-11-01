# The native owners are linked, not embedded: libkomira is NEEDED on each.
#
# `native_owners` links an owner's shared library ahead of the C archives, but
# the archives stay on the link line, so an owner dropped from the list is
# embedded silently and every other gate stays green. This driver reads the
# library's own ELF64 dynamic section (little endian), collects its DT_NEEDED
# names and requires the SONAME of each of the eight owners the BUCK file lists.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency and does not
# load the library: it only reads the file "./libkomira.so" as bytes.

comptime LIB = "./libkomira.so"
comptime OWNERS = (
    "libkomira_async_native.so.1",
    "libkomira_async_api_native.so.1",
    "libkomira_compression_native.so.1",
    "libkomira_fs_native.so.1",
    "libkomira_libc_native.so.1",
    "libkomira_metrics_native.so.1",
    "libkomira_parquet_codec_native.so.1",
    "libkomira_scan_source_native.so.1",
)
comptime SHT_DYNAMIC = 6
comptime DT_NEEDED = 1


def _le(data: List[UInt8], at: Int, n: Int) raises -> Int:
    if at < 0 or at + n > len(data):
        raise Error("ELF read out of range at " + String(at))
    var v = 0
    for i in range(n):
        v |= Int(data[at + i]) << (8 * i)
    return v


def _c_string(data: List[UInt8], at: Int) raises -> String:
    var end = at
    while end < len(data) and data[end] != 0:
        end += 1
    return String(from_utf8=Span(data)[at:end])


def _needed(data: List[UInt8]) raises -> List[String]:
    """The DT_NEEDED names of an ELF64 little-endian shared object."""
    if len(data) < 64 or data[0] != 0x7F or data[1] != UInt8(ord("E")):
        raise Error(LIB + " is not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise Error(LIB + " is not ELF64 little endian")
    var shoff = _le(data, 0x28, 8)
    var shentsize = _le(data, 0x3A, 2)
    var shnum = _le(data, 0x3C, 2)
    var names = List[String]()
    var found = False
    for i in range(shnum):
        var sh = shoff + i * shentsize
        if _le(data, sh + 4, 4) != SHT_DYNAMIC:
            continue
        found = True
        var offset = _le(data, sh + 0x18, 8)
        var size = _le(data, sh + 0x20, 8)
        var strtab = shoff + _le(data, sh + 0x28, 4) * shentsize
        var str_offset = _le(data, strtab + 0x18, 8)
        for e in range(size // 16):
            var entry = offset + e * 16
            var tag = _le(data, entry, 8)
            if tag == 0:  # DT_NULL ends the table
                break
            if tag == DT_NEEDED:
                names.append(_c_string(data, str_offset + _le(data, entry + 8, 8)))
    if not found:
        raise Error(LIB + " has no dynamic section")
    return names^


def main() raises:
    var needed = _needed(open(LIB, "r").read_bytes())
    comptime for i in range(len(OWNERS)):
        var present = False
        for name in needed:
            if name == OWNERS[i]:
                present = True
        if not present:
            raise Error(
                LIB + " is not NEEDED on " + OWNERS[i] + ": that owner's C is embedded or missing"
            )
    print("ok")
