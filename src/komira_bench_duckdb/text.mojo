# Byte slices of a String as a new String. Assigning a slice of a String back
# to the same variable in one expression is refused by the compiler (the
# argument and the result alias); a call through this function is not.


def slice_bytes(s: String, start: Int, end: Int) -> String:
    """The bytes of `s` from `start` up to `end`, as a String."""
    return String(s[byte=start:end])
