"""Fixtures whose annotations are strings (`from __future__ import annotations`)."""

from __future__ import annotations

import dataclasses
from typing import NotRequired, Optional, Required, TypedDict

from komira._capture import udf


class Pair(TypedDict):
    a: int
    b: int


class Partial(TypedDict):
    a: int
    b: NotRequired[int]


class AllRequired(TypedDict, total=False):
    a: Required[int]
    b: Required[str]


@dataclasses.dataclass
class Point:
    x: int
    y: int


@udf
def scalar(x: int) -> int:
    return x


@udf
def optional(x: int) -> Optional[float]:
    return None


@udf
def piped(x: int) -> int | None:
    return None


@udf(kind="row")
def typed_row(r: Pair) -> int:
    return r["a"]


@udf(kind="row")
def dataclass_row(r: Point) -> float:
    return r.x


@udf(kind="row")
def scanned(r: dict) -> int:
    return r.p + r["q"]


@udf
def partial(x: int) -> Partial:
    return {"a": x}


@udf
def all_required(x: int) -> AllRequired:
    return {"a": x, "b": ""}
