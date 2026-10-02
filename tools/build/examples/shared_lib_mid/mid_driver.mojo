from std.ffi import OwnedDLHandle


def expect(name: String, got: Int64, want: Int64) raises:
    if got != want:
        raise Error(name + ": got " + String(got) + " want " + String(want))


def main() raises:
    var lib = OwnedDLHandle("./mid.so")
    expect("json", Int64(lib.call["mid_json_serialized_len", Int32]()), 34)
    expect("b64", Int64(lib.call["mid_base64_len", Int32](Int32(10))), 16)
    # sha256 of 0x00..0x09 starts 0x1e? only the call must succeed and be in range
    var sh = Int64(lib.call["mid_sha256_first_byte", Int32](Int32(10)))
    if sh < 0 or sh > 255:
        raise Error("sha256 byte out of range")
    expect("pb", Int64(lib.call["mid_pb_roundtrip", UInt64](UInt64(300))), 300)
    expect("gcp", Int64(lib.call["mid_gcp_code_from_http", Int32](Int32(404))), 5)
    expect("batch", Int64(lib.call["mid_batch_rows", Int32]()), 3)
    print("ok")
