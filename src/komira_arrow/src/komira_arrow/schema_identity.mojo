# =============================================================================
# schema_identity_hash — THE shared structural hash of a `Schema`.
# =============================================================================
#
# Without this, `Schema` exposes NO hash method and every consumer that
# needs one rolls a private fold:
#   * `InMemorySource._structural_id_compute` folds batch CONTENT (which
#     transitively covers the schema via `RecordBatch.content_hash`).
#   * every file source folds a PATH and an mtime and never touches the schema.
# So there was no single answer to "are these two schemas the same shape", and
# `ScanBinding.identity_hash` needs exactly that.
#
# WHAT IS FOLDED, AND WHY EACH:
#   column count      — a prefix-equal schema must not alias a longer one.
#   field name        — the projection vocabulary; renaming a column changes
#                       which predicates bind.
#   arrow type id     — INT64 vs STRING changes every kernel selected.
#   nullable          — changes null-handling codegen and join semantics.
#   decimal (p, s)    — DECIMAL128(10,2) and DECIMAL128(10,4) are different
#                       types that share an ArrowType id.
#
# WHAT IS DELIBERATELY *NOT* FOLDED: field metadata, timezone strings, dict
# index types, union type-ids, child fields. These are carried by `Field` but
# do not change the STRUCTURAL identity two plans need to agree on, and folding
# them would make the hash sensitive to metadata a writer attaches
# incidentally. If a future kind needs them discriminated, it puts the
# discriminator in its `ScanParams` — that is what params are for.
#
# ⚠ THIS FUNCTION'S OUTPUT IS A CACHE KEY INPUT. Changing the fold changes
# every `ScanBinding.identity_hash` in the tree, which silently invalidates
# every plan cache. Treat a change here as a breaking change and pin it with a
# golden hash test.
# =============================================================================

from komira_arrow.schema import Schema


comptime _SCHEMA_ID_FNV_OFFSET: UInt64 = 14695981039346656037
comptime _SCHEMA_ID_FNV_PRIME: UInt64 = 1099511628211

comptime _SCHEMA_ID_SALT: UInt64 = 0x5C_4E_3A_11
"""Domain salt, so a schema identity can never alias a raw numeric id from
another source family folded with the same FNV construction."""


@always_inline
def _schema_id_fold_bytes(s: String, seed: UInt64) -> UInt64:
    var h = seed
    var b = s.as_bytes()
    for i in range(len(b)):
        h = h ^ UInt64(b[i])
        h = h * _SCHEMA_ID_FNV_PRIME
    return h


def schema_identity_hash(schema: Schema) -> UInt64:
    """Structural identity of a `Schema` — see the module header for the
    exact fold and what is deliberately excluded.

    Properties the callers rely on:
      * Two schemas with the same (name, type, nullable, decimal) sequence
        hash EQUAL, regardless of how they were built.
      * Reordering columns changes the hash (column order is part of a
        schema's identity — projection is positional downstream).
      * The empty schema has a well-defined non-zero hash, so an
        `Optional[Schema]` that is present-but-empty is distinguishable from
        one that is absent (callers fold a separate presence bit).
    """
    var h = _SCHEMA_ID_FNV_OFFSET
    h = (h ^ _SCHEMA_ID_SALT) * _SCHEMA_ID_FNV_PRIME
    var n = schema.num_columns()
    h = (h ^ UInt64(n)) * _SCHEMA_ID_FNV_PRIME
    for i in range(n):
        h = _schema_id_fold_bytes(schema.field_name(i), h)
        h = (
            h ^ UInt64(schema.field_arrow_type(i).type_id)
        ) * _SCHEMA_ID_FNV_PRIME
        h = (
            h ^ (UInt64(1) if schema.field_nullable(i) else UInt64(0))
        ) * _SCHEMA_ID_FNV_PRIME
        h = (
            h ^ UInt64(schema.field_decimal_precision(i))
        ) * _SCHEMA_ID_FNV_PRIME
        h = (h ^ UInt64(schema.field_decimal_scale(i))) * _SCHEMA_ID_FNV_PRIME
    return h
