from std.ffi import external_call


def main() raises:
    var got = external_call["komira_example_add", Int32](Int32(40), Int32(2))
    if got != 42:
        raise Error("komira_example_add(40, 2) returned " + String(got))
    print("test_add_direct: PASS")
