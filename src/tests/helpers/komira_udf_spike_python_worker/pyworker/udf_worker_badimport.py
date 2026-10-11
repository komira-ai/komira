"""A module that validates (it parses, and its function has the right
hints) but fails when it is imported."""

raise RuntimeError("this module refuses to be imported")


def f(x: int) -> int:
    return x
