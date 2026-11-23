"""The column types of a user function (komira/python, src/udf_python/README.md,
"Types"), as the SDK names them.

A dtype is written as the text `str()` of the matching pyarrow type gives
(`int64`, `timestamp[us, tz=UTC]`, `decimal128(10, 2)`, `list<item: int64>`,
`struct<a: int64, b: string>`), which is the canonical spelling. `parse` reads
that text, with optional white space around the punctuation, `list<T>` for
`list<item: T>`, and the aliases `utf8`, `large_utf8` and `date32`, into a
`DType`; `canonical` gives the text back in the canonical spelling.

The engine's column keeps one level of children for a list or struct, each a
name, a type id and a nullability (src/plan_expr/udf_type_field.mojo). So a
list's item and a struct's fields are flat types: any carried type that is not
a list, a struct, a decimal or a timestamp with a time zone. `wire` gives the
facts a plan field carries for a `DType`.

This module never imports pyarrow.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import NamedTuple

from komira._errors import UnsupportedOperation

__all__ = [
    "ARROW_NAMES",
    "CARRIED",
    "DType",
    "FLAT_ARROW_NAMES",
    "MAX_NAME_BYTES",
    "Wire",
    "canonical",
    "field_name_problem",
    "parse",
    "render",
    "wire",
]

CARRIED = (
    "bool, int8, int16, int32, int64, float32, float64, string, large_string, binary, large_binary, "
    "date32[day], timestamp[s|ms|us|ns] with an optional tz, decimal128(p, s), list<item: T>, "
    "large_list<item: T> and struct<name: T, ...>, where a list item or struct field is not a list, "
    "a struct, a decimal or a zoned timestamp"
)

# The longest name or time zone the runtime carries, in UTF-8 bytes
# (UDFPY_MAX_NAME is 64, with the terminating byte).
MAX_NAME_BYTES = 63

# The dtypes that are one word; each is also its Arrow type's name on the plan wire.
_SIMPLE = frozenset(
    {
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "float32",
        "float64",
        "string",
        "large_string",
        "binary",
        "large_binary",
    }
)
_ALIASES = {"utf8": "string", "large_utf8": "large_string"}
_UNITS = ("s", "ms", "us", "ns")
_LISTS = frozenset({"list", "large_list"})
_NOT_FLAT = frozenset({"list", "large_list", "struct", "decimal128"})

# The Arrow type names a carried column has on the plan wire.
ARROW_NAMES = frozenset(
    _SIMPLE
    | {"date32", "decimal128", "list", "large_list", "struct"}
    | {f"timestamp_{unit}" for unit in _UNITS}
)
# Those a list's item or a struct's field may have (a timestamp's zone is a fact
# of the field, so a flat child timestamp has none).
FLAT_ARROW_NAMES = ARROW_NAMES - _NOT_FLAT

# How deep `parse` follows the text: a list or struct that nests more than this
# is refused as no carried type, without reading further.
_MAX_PARSE_DEPTH = 8

_IDENT = re.compile(r"\s*([a-z][a-z0-9_]*)")
_INT = re.compile(r"\s*([0-9]+)")
_LABEL = re.compile(r"\s*([^,:<>]*?)\s*:")


@dataclass(frozen=True, slots=True)
class DType:
    """A carried type. `kind` is the Arrow type's name (`int64`, `string`,
    `date32`, `timestamp`, `decimal128`, `list`, `large_list`, `struct`).

    - `unit`: a timestamp's, one of `s`, `ms`, `us`, `ns`.
    - `tz`: a timestamp's time zone, or None.
    - `precision`, `scale`: a decimal's.
    - `children`: `(name, DType)` pairs: a list's one `item`, a struct's fields.
    """

    kind: str
    unit: str | None = None
    tz: str | None = None
    precision: int | None = None
    scale: int | None = None
    children: tuple = ()


class Wire(NamedTuple):
    """What a plan field holds for a `DType`: the name of its Arrow type, a
    decimal's precision and scale (0 otherwise), a timestamp's zone ("" for
    none), and a list's or struct's flat children as `(name, Arrow type name)`."""

    type_name: str
    precision: int
    scale: int
    tz: str
    children: tuple


def render(d: DType) -> str:
    """The canonical text of `d`: what `str()` of the pyarrow type gives."""
    kind = d.kind
    if kind == "date32":
        return "date32[day]"
    if kind == "timestamp":
        return f"timestamp[{d.unit}, tz={d.tz}]" if d.tz else f"timestamp[{d.unit}]"
    if kind == "decimal128":
        return f"decimal128({d.precision}, {d.scale})"
    if kind in _LISTS:
        return f"{kind}<item: {render(d.children[0][1])}>"
    if kind == "struct":
        return "struct<" + ", ".join(f"{name}: {render(child)}" for name, child in d.children) + ">"
    return kind


def wire(d: DType) -> Wire:
    """The facts a plan field of type `d` carries."""
    children = tuple((name, wire(child).type_name) for name, child in d.children)
    return Wire(
        f"timestamp_{d.unit}" if d.kind == "timestamp" else d.kind,
        d.precision or 0,
        d.scale or 0,
        d.tz or "",
        children,
    )


def field_name_problem(name: str) -> str | None:
    """Why `name` cannot be a struct field's name, else None."""
    if name == "":
        return "is empty"
    if any(c in name for c in ",:<>"):
        return "holds one of the characters , : < >"
    if name != name.strip():
        return "starts or ends with white space"
    if len(name.encode("utf-8", "surrogatepass")) > MAX_NAME_BYTES:
        return f"is longer than {MAX_NAME_BYTES} bytes"
    return None


def _is_flat(d: DType) -> bool:
    return d.kind not in _NOT_FLAT and not (d.kind == "timestamp" and d.tz)


class _Refused(Exception):
    """The text is no carried type."""


class _Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0
        # The text of the first list item or struct field met that is not flat;
        # it is refused once the whole text has been read as a type.
        self.nested: str | None = None

    def _match(self, pattern: re.Pattern) -> str:
        m = pattern.match(self.text, self.pos)
        if m is None:
            raise _Refused
        self.pos = m.end()
        return m.group(1)

    def _skip(self) -> None:
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1

    def _peek(self, mark: str) -> bool:
        self._skip()
        return self.text.startswith(mark, self.pos)

    def _punct(self, mark: str) -> None:
        if not self._peek(mark):
            raise _Refused
        self.pos += len(mark)

    def _ident(self) -> str:
        return self._match(_IDENT)

    def _int(self) -> int:
        return int(self._match(_INT))

    def end(self) -> None:
        self._skip()
        if self.pos != len(self.text):
            raise _Refused

    def _child(self, depth: int) -> DType:
        child = self.dtype(depth + 1)
        if self.nested is None and not _is_flat(child):
            self.nested = render(child)
        return child

    def dtype(self, depth: int) -> DType:
        if depth > _MAX_PARSE_DEPTH:
            raise _Refused
        word = self._ident()
        word = _ALIASES.get(word, word)
        if word in _SIMPLE:
            return DType(word)
        if word == "date32":
            if self._peek("["):
                self._punct("[")
                if self._ident() != "day":
                    raise _Refused
                self._punct("]")
            return DType("date32")
        if word == "timestamp":
            return self._timestamp()
        if word == "decimal128":
            return self._decimal()
        if word in _LISTS:
            self._punct("<")
            label = _LABEL.match(self.text, self.pos)
            if label is not None:
                if label.group(1) != "item":
                    raise _Refused
                self.pos = label.end()
            child = self._child(depth)
            self._punct(">")
            return DType(word, children=(("item", child),))
        if word == "struct":
            return self._struct(depth)
        raise _Refused

    def _timestamp(self) -> DType:
        self._punct("[")
        unit = self._ident()
        if unit not in _UNITS:
            raise _Refused
        tz = None
        if self._peek(","):
            self._punct(",")
            if self._ident() != "tz":
                raise _Refused
            self._punct("=")
            stop = self.text.find("]", self.pos)
            if stop < 0:
                raise _Refused
            tz = self.text[self.pos : stop].strip()
            if tz == "" or "," in tz or len(tz.encode("utf-8", "surrogatepass")) > MAX_NAME_BYTES:
                raise _Refused
            self.pos = stop
        self._punct("]")
        return DType("timestamp", unit=unit, tz=tz)

    def _decimal(self) -> DType:
        self._punct("(")
        precision = self._int()
        self._punct(",")
        scale = self._int()
        self._punct(")")
        if not (1 <= precision <= 38 and 0 <= scale <= precision):
            raise _Refused
        return DType("decimal128", precision=precision, scale=scale)

    def _struct(self, depth: int) -> DType:
        self._punct("<")
        fields = []
        while True:
            name = self._match(_LABEL)
            if field_name_problem(name) is not None or any(name == seen for seen, _ in fields):
                raise _Refused
            fields.append((name, self._child(depth)))
            if self._peek(","):
                self._punct(",")
                continue
            self._punct(">")
            return DType("struct", children=tuple(fields))


def parse(text: str, what: str = "dtype") -> DType:
    """The `DType` `text` names, or an `UnsupportedOperation` that names `what`
    (where the text was given) and the carried types."""
    parser = _Parser(text)
    try:
        d = parser.dtype(0)
        parser.end()
    except _Refused:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: {what} {text!r} is not a type komira/python carries; "
            f"the carried types are {CARRIED}"
        ) from None
    if parser.nested is not None:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: {what} {text!r} nests {parser.nested} in a list or struct, "
            f"which a komira column cannot hold; the carried types are {CARRIED}"
        )
    return d


def canonical(text: str, what: str = "dtype") -> str:
    """`text` in the canonical spelling, or the refusal `parse` gives."""
    return render(parse(text, what))
