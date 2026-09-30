from std.ffi import external_call


def main():
    print(external_call["komira_example_add", Int32](Int32(40), Int32(2)))
