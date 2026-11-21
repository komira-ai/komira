"""Column-name checks shared by the relational nodes and the verbs."""

from __future__ import annotations

import difflib


def unknown_column(name: str, columns: tuple[str, ...]) -> KeyError:
    """The `KeyError` for a column the frame does not have; the caller raises it."""
    listed = ", ".join(columns)
    close = difflib.get_close_matches(name, columns, n=1, cutoff=0.6)
    if close:
        return KeyError(
            f"no column named '{name}' in this frame; the closest is "
            f"'{close[0]}'; the frame's columns are: {listed}"
        )
    return KeyError(f"no column named '{name}' in this frame; the frame's columns are: {listed}")


def require_columns(names, columns: tuple[str, ...]) -> None:
    """Raise `unknown_column` for the first of `names` that is not in `columns`."""
    for name in names:
        if name not in columns:
            raise unknown_column(name, columns)


def require_unique(names: tuple[str, ...], what: str) -> None:
    """Raise `ValueError` for the first name that appears more than once."""
    seen = set()
    for name in names:
        if name in seen:
            raise ValueError(f"{what}: the output name '{name}' appears more than once")
        seen.add(name)
