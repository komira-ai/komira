"""A Dict subscript (test 47): `d[key]` raises KeyError, so the IR branches
on the error flag `Dict.__getitem__` returns, at the `[`: a branch the
compiler made, not a decision."""


def lookup(d: Dict[String, Int], key: String) raises -> Int:
    return d[key]
