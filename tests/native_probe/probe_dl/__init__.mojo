# Opens the native library by soname at run time and calls the symbol.
from std.ffi import OwnedDLHandle


def answer() raises -> Int64:
    var handle = OwnedDLHandle("libkomira_probe.so.1")
    return handle.call["komira_probe_answer", Int64]()
