# A shared library of two C-ABI exports (test 43): its driver calls the
# first only, so a coverage run of the driver reports the first's lines run
# and the second's not.
@export
def covso_scale(x: Int32) abi("C") -> Int32:
    var y = x * 2
    return y + 1


@export
def covso_unused(x: Int32) abi("C") -> Int32:
    var y = x - 1
    return y * 3
