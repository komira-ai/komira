"""A String's lifetime at a decision (test 47): `first` owns `s`, and on the
`if`'s return path the String is destroyed at the `if`'s location (Mojo's
String destructor is `nodebug`), four branches the classifier reads as the
String's, not as more decisions of the `if`."""


def first(var s: String, flag: Bool) -> Int:
    if flag:
        return 1
    return s.byte_length()
