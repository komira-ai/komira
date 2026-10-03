# =============================================================================
# auto_komira_schema.mojo — `AutoKomiraSchema` marker trait for UDF row structs.
# =============================================================================
#
# The user-facing UDF traits
# (`FilterFn` / `MapFn` / `AggFn`) constrain their `comptime InRow` member to
# `AutoKomiraSchema`. The marker is empty (pure type tag) — conformance is the
# user's promise that the struct is shaped like a row (each field maps to one
# column). The name says what the marker enables: the Arrow schema is
# auto-derived from the struct's fields.
#
# - The trait bound on `comptime InRow: AutoKomiraSchema` compiles and is
#   enforced per-conformer.
# - A non-conforming assignment raises `error: cannot bind type 'X' to
#   trait 'AutoKomiraSchema'` at the offending line — a clear user-facing
#   diagnostic.
# - Field access `row.url` inside trait methods works (the compiler widens
#   `Self.InRow` to the bound concrete type at the call site).
# - An empty `...` body is a valid marker shape; `Copyable, Movable` is
#   the actual contract.
#
# Future Mojo capability watch: once a stable type-identity API
# (`_type_hash[T]()`) lands, the UDF trait surface can drop `UDF_ID` as
# a user-required member and derive it from `Self`.
# =============================================================================


trait AutoKomiraSchema(Copyable, Movable):
    """Marker trait for UDF row structs (auto-derived Arrow schema).

    Conformers participate as `InRow` types in the user-facing UDF traits
    (`FilterFn`, `MapFn`, `AggFn`). Empty body — pure type tag. The actual
    contract (Copyable + Movable) is inherited. The schema for the row is
    auto-derived from the struct's field types (the trait-default
    `_derive_schema[Self.InRow]()` on the typed-UDF traits).

    Required user pattern:

        @fieldwise_init
        struct MyRow(Copyable, Movable, AutoKomiraSchema):
            var price: Float64
            var quantity: Int64

    Each field maps to one input column. `@fieldwise_init` synthesizes the
    positional constructor the engine uses when building per-row instances
    from per-column primitive arrays (`MyRow(c0.get(i), c1.get(i))`).
    """
    ...
