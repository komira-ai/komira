"""The text rules the pandas-shaped `.str` and komira.pl's `str` share.

- `PYTHON_WHITESPACE`: the characters Python's `str.strip()` removes with no
  argument, exactly those for which `str.isspace()` is true, which pandas'
  `Series.str.strip(to_strip=None)` follows.
- `UNICODE_WHITE_SPACE`: the characters with the Unicode `White_Space`
  property, which Rust's `char::is_whitespace` tests and polars'
  `str.strip_chars(characters=None)` removes. It is `PYTHON_WHITESPACE`
  without U+001C to U+001F, which Python counts as whitespace and Unicode does not.
- `trim`: the engine's character-set trim, `trim(s, chars)`, `ltrim` or
  `rtrim` as DuckDB has them; `chars` is a set of characters, not a prefix.
- `escape`: a text as an engine regular expression that matches the text itself.
- `polars_replacement`: a polars replacement string (`$1`, `${1}`, `$$`) as the
  engine's (`\\1`, a literal `$`, `\\\\` for a backslash).

The engine's regular expressions are RE2's syntax with no backreferences or
lookaround, matched over bytes (docs/design/query_semantics.md, section 7.8).
"""

from __future__ import annotations

import re

from . import _ops
from ._errors import UnsupportedOperation

__all__ = ["PYTHON_WHITESPACE", "UNICODE_WHITE_SPACE", "escape", "matches_empty", "polars_replacement", "trim"]

UNICODE_WHITE_SPACE = (
    "\t\n\v\f\r \x85\xa0 "
    "           "
    "    　"
)
PYTHON_WHITESPACE = UNICODE_WHITE_SPACE + "\x1c\x1d\x1e\x1f"

_SIDES = {"both": "trim", "left": "ltrim", "right": "rtrim"}

# The characters an engine pattern reads as syntax; `\` before any of them is the character itself.
_META = frozenset("\\.^$|?*+()[]{}")


def trim(child: _ops.Node, chars: str, side: str) -> _ops.Node:
    """`child` with every character of the set `chars` removed from `side`
    ('both', 'left' or 'right')."""
    return _ops.StringFnN(_SIDES[side], (child, _ops.Lit(chars)))


def escape(text: str) -> str:
    """`text` as an engine regular expression that matches exactly it."""
    return "".join("\\" + c if c in _META else c for c in text)


def matches_empty(pattern: str) -> bool:
    """Does the regular expression `pattern` match the empty string (`""`,
    `x*`, `a?`, `a|`, `^`)? Such a pattern matches between characters, which
    the engine counts in bytes. A pattern Python's `re` cannot read is left to
    the engine, which refuses it by name if it cannot read it either."""
    try:
        return re.compile(pattern).fullmatch("") is not None
    except re.error:
        return False


def _group_count(pattern: str, verb: str) -> int:
    try:
        return re.compile(pattern).groups
    except re.error as e:
        raise UnsupportedOperation(
            f"{verb}: the groups of the pattern {pattern!r} cannot be counted ({e}), and the value refers to one; "
            "write the value without $"
        ) from None


def polars_replacement(value: str, pattern: str, verb: str) -> str:
    """The polars replacement `value` of a match of `pattern` in the engine's
    spelling. polars (the Rust regex crate) reads `$$` as `$`, `$n` and `${n}`
    as group n, `$name` and `${name}` as a named group, and any other `$` as
    itself; a group the pattern does not have gives ''. A backslash is itself."""
    out = []
    i, end = 0, len(value)
    groups = None
    while i < end:
        c = value[i]
        if c == "\\":
            out.append("\\\\")
            i += 1
            continue
        if c != "$":
            out.append(c)
            i += 1
            continue
        if value.startswith("$$", i):
            out.append("$")
            i += 2
            continue
        name, after = _reference(value, i)
        if name is None:
            out.append("$")
            i += 1
            continue
        if _DIGITS.fullmatch(name) is None:
            raise UnsupportedOperation(
                f"{verb}: the value refers to the group named {name!r}, and the engine refers to a group by its "
                "number only: write $1 for the first group"
            )
        number = int(name)
        if number > 9:
            raise UnsupportedOperation(
                f"{verb}: the value refers to group {number}, and the engine refers to groups 0 to 9 only"
            )
        if groups is None:
            groups = _group_count(pattern, verb)
        if number <= groups:
            out.append("\\" + str(number))
        i = after
    return "".join(out)


_NAME = re.compile(r"[0-9A-Za-z_]+")
_DIGITS = re.compile(r"[0-9]+")


def _reference(value: str, i: int) -> tuple[str | None, int]:
    """The group name of the `$` at `i` of `value` and the index after it, or
    (None, i) when that `$` is the character itself."""
    if value.startswith("${", i):
        close = value.find("}", i + 2)
        if close == -1 or close == i + 2:
            return None, i
        return value[i + 2 : close], close + 1
    m = _NAME.match(value, i + 1)
    if m is None:
        return None, i
    return m.group(0), m.end()
