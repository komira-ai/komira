@export
def plain_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


# Named by no `exports` list.
@export
def plain_hidden() abi("C") -> Int32:
    return 7
