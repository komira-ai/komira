# =============================================================================
# flat_schema — the footer shape the leaf-to-schema mapping assumes
# =============================================================================
#
# Every decode in this package takes a leaf index `c` and reads
# `schema[c + 1]` for its type, repetition and annotation. That is the schema
# element of leaf `c` only when the footer is flat: every element after the
# root a leaf, none REPEATED. On a nested footer the element at `c + 1` can be
# a group, and a leaf's definition level is not its own element's. The
# decisions this package makes for itself (the selection class, the
# row-selective decode, the dictionary-codes paths) decline on a footer that
# is not flat instead of answering from the wrong element.
# =============================================================================

from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import FieldRepetitionType


def schema_is_flat(schema: List[SchemaElement]) -> Bool:
    """True when every element after the root (element 0) is a leaf and none
    is REPEATED."""
    for i in range(1, len(schema)):
        if schema[i].num_children > 0:
            return False
        if schema[i].repetition_type and schema[i].repetition_type.value() == FieldRepetitionType.REPEATED:
            return False
    return True
