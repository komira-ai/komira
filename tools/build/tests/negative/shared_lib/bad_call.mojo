from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./missing_call.so")
    if lib.call["neg_add", Int32](Int32(2), Int32(2)) != 5:
        raise Error("neg_add(2, 2) is not 5")
