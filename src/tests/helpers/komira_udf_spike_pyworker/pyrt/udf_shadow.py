"""Functions whose hints read one way in the source and resolve to another
object when the module is imported: each annotation is evaluated when its
`def` runs, and the name it uses is rebound just before. validate (the
source) accepts each; open_instance (the live hints) must refuse each.
"""

import builtins

list = builtins.set


def set_hint(x: list[int]) -> list[int]:
    """Reads as list[int]; is set[int]."""
    return x


list = builtins.list
int = builtins.int | builtins.float


def union_hint(x: int) -> int:
    """Reads as int; is int | float."""
    return x


int = builtins.list[builtins.int]


def nested_hint(x: list[int]) -> list[int]:
    """Reads as list[int]; is list[list[int]]."""
    return x


int = builtins.int


class ndarray:
    """Not numpy's ndarray: a class of this module with the same name."""


def fake_ndarray(x: ndarray) -> ndarray:
    """Reads as a numpy array (a hint ending in ndarray); is this module's
    class."""
    return x
