"""branchlib: the library of the branch coverage tests (test 47)."""

from .loops import letters, total
from .lookup import lookup
from .mask import roomy
from .score import classify_score
from .shapes import any_positive, shapes
from .strings import first
from .unrun import Tag
from .trial import (
    both,
    calls,
    keyed,
    looped,
    nested,
    normal_only,
    outside,
    raise_in_try,
    with_else,
    with_finally,
)
