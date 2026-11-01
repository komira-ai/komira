from komira_libc.posix_io import RawWriteFd


@export
def native_owner_write_probe(n: Int32) abi("C") -> Int64:
    """Writes `n` bytes to a file in the working directory and returns the
    file's size, or -1 on any error. Every step goes through C that
    komira_libc owns: komira_openat_creat, komira_write_bytes and
    komira_lseek_end."""
    try:
        var fd = RawWriteFd.open_truncate("native_owner_probe.bin")
        var bytes = List[UInt8](length=Int(n), fill=UInt8(7))
        fd.write_bytes(Span(bytes))
        var size = fd.seek_to_end()
        fd.close()
        return Int64(size)
    except:
        return -1
