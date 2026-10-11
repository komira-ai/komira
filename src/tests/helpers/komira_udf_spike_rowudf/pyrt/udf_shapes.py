"""Row functions whose signatures and return hints the runtime's validate
(the source, never run) and open_instance (the imported object) accept or
refuse. The rebound_* names are rebound after their definitions: validate
reads the def, open_instance the object the name then holds.
"""

import typing
from typing import Optional


def str_hint(row) -> "float":
    return row.price


def none_hint(row) -> None:
    return None


def str_optional(row) -> "float | None":
    return row.price


def str_unparsable(row) -> "float (":
    return row.price


def str_hinted(row) -> str:
    return ""


def str_and(row) -> "float & None":
    return row.price


def optional_hint(row) -> Optional[float]:
    return row.price


def typing_optional(row) -> typing.Optional[int]:
    return 1


def list_hint(row) -> list[float]:
    return [row.price]


def str_const_union(row) -> "float | 3":
    return row.price


def with_varargs(row, *rest) -> float:
    return row.price


def with_kwargs(row, **kw) -> float:
    return row.price


def with_kwonly(row, *, k=1) -> float:
    return row.price


async def coroutine(row) -> float:
    return row.price


def _two(row, other) -> float:
    return row.price


def rebound_two(row) -> float:
    return row.price


rebound_two = _two  # noqa: F811


def _listed(row) -> list[float]:
    return [row.price]


def rebound_list(row) -> float:
    return row.price


rebound_list = _listed  # noqa: F811


def _either(row) -> int | str:
    return 1


def rebound_union(row) -> float:
    return row.price


rebound_union = _either  # noqa: F811


def _unresolved(row) -> "Undefined":  # noqa: F821
    return row.price


def rebound_unresolved(row) -> float:
    return row.price


rebound_unresolved = _unresolved  # noqa: F811


def rebound_value(row) -> float:
    return row.price


rebound_value = 3  # noqa: F811
