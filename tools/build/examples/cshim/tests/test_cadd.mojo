from cadd import add


def check(a: Int32, b: Int32, want: Int32) raises:
    var got = add(a, b)
    if got != want:
        raise Error("add(" + String(a) + ", " + String(b) + ") returned " + String(got))


def main() raises:
    check(2, 3, 5)
    check(-7, 7, 0)
    print("test_cadd: PASS")
