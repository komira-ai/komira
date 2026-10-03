# =============================================================================
# JsonCompatible — instance-form trait for inline struct ↔ JSON serde
# =============================================================================
#
# Mirror of `ArrowCompatible` (the Arrow-side serde trait used by
# `schema_auto` + `read_inline` / the typed-row inserter family). Tier 1/2/3
# reflection lattice:
#
#   - Tier 1 (manual): conformer writes BOTH schema + values by hand.
#     Used for one-off non-uniform shapes where reflection cannot enumerate
#     field types statically (e.g. fields whose type depends on a runtime
#     discriminator).
#   - Tier 2 (reflection-derived SCHEMA, hand-keyed VALUES): the canonical
#     shape. `reflect[Self]()` enumerates field NAMES + TYPES; the per-field
#     VALUE access is hand-keyed via a `comptime if i == N: self.<field>`
#     cascade, the same shape as `schema_auto`.
#   - Tier 3 (per-field override / escape valve): a possible
#     `json_field_overrides()` static method on the conformer to specify
#     per-field encoding divergence (e.g. Decimal128 string-vs-numeric;
#     Variant numeric-pair round-trip-loss). Not part of the surface; the
#     Tier 2 cascade can pattern-match on `(FieldT == Decimal128[*, *])`
#     today to route divergent types without a separate override method.
#
# Why Tier 2 and not pure reflection: `reflect[T]()` exposes field NAMES +
# field TYPES but NOT a value-extraction API (no `r.field_value(self, i)`
# accessor; `Reflected[T]` has no `param_values()` either). So `to_json` /
# `from_json` bodies cannot be PURELY reflect-driven — they must hand-key
# the field VALUE access via `comptime if i == N`. This is not a
# JSON-specific limit; it is the established trait shape for reflection.
#
# Trait surface kept minimal: instance-form `to_json(self)`; static-form
# `from_json` matches the `_FieldwiseDecoder` / `read_inline` shape (no
# instance to project at construction).
# =============================================================================


trait JsonCompatible(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Inline struct ↔ JSON serde. Mirror of `ArrowCompatible`.

    Conformers implement two methods:

      - `fn to_json(self) raises -> String`
          — emit a single JSON object for this record. Output is a JSON
            primitive object (no trailing newline; the JSONL framing in
            `komira_jsonl.encode.write_record` appends `\\n`). Edge
            cases:
              - String fields: escape `"` / `\\` / control chars per
                RFC 8259 §7. Conformer can call
                `komira_jsonl.encode._emit_string_escaped` as the helper.
              - Float64 fields: NaN / +Inf / -Inf serialize as JSON `null`
                (RFC 8259 §6 disallows non-finite floats; null is the
                canonical workaround; matches DuckDB / pyarrow).
              - Optional[T] fields: `Some(v)` -> `v.to_json` shape;
                `None` -> JSON `null`.

      - `@staticmethod fn from_json(s: String) raises -> Self`
          — parse one JSON object string into a new instance. Static-form
            (no instance to project at construction). Unknown keys in
            the input → ignored; missing required keys → raise.

    Conformer trait clause:

        @fieldwise_init
        struct MyRecord(
            JsonCompatible, Copyable, Movable, Deinitable
        ):
            var id: Int
            var name: String
            var price: Float64

            def to_json(self) raises -> String:
                # reflect-driven SCHEMA (field names + types) + hand-keyed
                # VALUES.
                ...

            @staticmethod
            def from_json(s: String) raises -> Self:
                ...

    The instance form lets `to_json` pattern-match on `self.<field>`
    directly via the comptime cascade; the static form on `from_json`
    matches `_FieldwiseDecoder` shape.

    Super-clause: `(Copyable, Movable, ImplicitlyCopyable)`. Copyable
    so JsonCompatible records can pass through `List[T]` / Slab[T] /
    DataFrame row inserters; ImplicitlyCopyable so call-site `^`-move
    is optional. Matches the ArrowCompatible super.
    """

    def to_json(self) raises -> String:
        ...

    @staticmethod
    def from_json(s: String) raises -> Self:
        ...
