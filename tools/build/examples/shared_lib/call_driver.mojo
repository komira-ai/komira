from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./spike.so")
    var add = lib.call["spike_add", Int32](Int32(2), Int32(3))
    if add != 5:
        raise Error("spike_add(2, 3) = " + String(add))
    var sq = lib.call["spike_sum_squares", Int64](Int32(4))
    if sq != 14:
        raise Error("spike_sum_squares(4) = " + String(sq))
    var c = lib.call["spike_c_add", Int32](Int32(40), Int32(2))
    if c != 42:
        raise Error("spike_c_add(40, 2) = " + String(c))
    var f = lib.call["komira_spike_forced", Int32]()
    if f != 4242:
        raise Error("komira_spike_forced() = " + String(f))
    print("ok")
