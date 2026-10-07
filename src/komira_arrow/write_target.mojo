# =============================================================================
# komira_arrow/write_target.mojo — WHERE A QUERY'S ROWS GO.
# =============================================================================
#
# `(path, format, compression)`. Three fields, one struct, and the two
# enumerations they name.
#
# ★ WHY THIS IS IN `komira_arrow` AND NOT BESIDE THE SQL PARSER THAT USES IT.
# `WFMT_*` and `WCOMP_*` are not a SQL-frontend detail: `komira.plan.v1.WirePlanEnvelope`
# carries a `write_target` field, and a code that crosses the wire is a WIRE
# VOCABULARY. A wire-vocabulary completeness check derives its candidate
# universe from the TRANSITIVE the core packages IMPORT CLOSURE of the plan wire
# codec. The SQL frontend is not in that closure and never can be (the codec
# sits BELOW the engine), so a write vocabulary declared there is one the
# completeness check CANNOT SEE — structurally, not by oversight.
#
# `komira_sdk` imports the core packages, so declaring it here is legal and
# declaring it above is not. The codec imports this file, which puts it in
# that closure, which is what makes `WriteFormat` / `WriteCompression`
# registrable wire spaces.
#
# ⚠ `SINK_VARIANT_FILE_*` DELIBERATELY DID **NOT** MOVE, and the distinction is
# the whole reason this file is small. Those 13 constants are the RECEIVER'S ARM
# LOOKUP — which of `SinkVariant`'s file arms writes this pair — and they do not
# cross the wire in any direction. A (fmt, codec) pair does; the arm it resolves
# to is the receiver's own business and may differ between builds. Only what
# crosses needs to be governed, and governing more than crosses would publish an
# append-only, never-renumberable wire identity for an implementation detail.
#
# ⚠ NAMES THAT LOOK LIKE EACH OTHER AND ARE NOT:
#   `write_format_name(fmt)`      HERE. The SQL word ("parquet"), for ERROR TEXT.
#   `write_format_wire_name(w)`   GENERATED, in `plan_wire_vocabulary.mojo`. The
#                                 published WIRE enum name ("WFMT_PARQUET").
# The first renders what a user typed; the second renders what a frontend in
# another language binds to. Reaching for the wrong one produces a diagnostic
# that reads fine and names the wrong space.
# =============================================================================


# --- Write formats (on `SqlStatement.fmt`, `WriteTarget.fmt`) ----------------
# The three formats the SDK has a file sink for. Each (fmt, codec) pair below
# resolves to exactly one `SinkVariant` arm at the exec layer; a pair with no arm
# raises a clean bind error (negative-corpus contract) rather than writing a file
# that is not what the SQL asked for.
#
# ⚠ THESE VALUES ARE NOW PUBLISHED WIRE IDENTITIES. `WriteFormat` in
# `plan_vocabulary.proto` is derived from these `comptime` lines at wire number
# = value + 1, and a wire baseline records every one of them append-only.
# Renumbering `WFMT_CSV` is not a local edit: it changes what every
# previously-written envelope MEANS, and the generator refuses it by name.
comptime WFMT_PARQUET: UInt8 = 0
comptime WFMT_CSV: UInt8 = 1
comptime WFMT_JSONL: UInt8 = 2            # DuckDB spells it FORMAT 'json'

# --- Write compression codes (on `SqlStatement.codec`, `WriteTarget.codec`) —
# resolved to a concrete `SinkVariant` arm at the exec layer
# (`plan_write._sink_tag_for`), kept OUT of the sink layer so the AST, the wire and
# the sink stay decoupled. Same append-only wire rule as the formats above.
comptime WCOMP_SNAPPY: UInt8 = 0          # DuckDB's default parquet codec
comptime WCOMP_UNCOMPRESSED: UInt8 = 1
comptime WCOMP_ZSTD: UInt8 = 2
comptime WCOMP_GZIP: UInt8 = 3
comptime WCOMP_LZ4: UInt8 = 4             # parquet: lz4_raw (id 7); csv/jsonl: whole-file Lz4Raw


# ⚠ BOTH HELPERS BELOW ARE `-> StaticString`, NOT `-> String`, AND THE `write_`
# PREFIX HERE MEANS THE SQL *WRITE* (COPY TO) — not the Writer shape.
# A ladder that RETURNS one of three-or-more string literals is lowered to two
# parallel constant arrays (pointers, lengths) selected by one register through
# independently relocated bases, and a link can bind such a pair CROSSED — a
# query then dies with SIGSEGV. The binding is a property of the whole LINK, so
# every returning ladder in a linked artifact is a ticket in the same lottery.
# the core packages is reached by nearly every target, so the exposure is wide.
def write_format_name(fmt: UInt8) -> StaticString:
    """Render a WFMT_* code as the word the SQL surface uses — for error text
    ONLY. Kept beside the codes so a new format cannot be added without a name."""
    if fmt == WFMT_CSV:
        return "csv"
    if fmt == WFMT_JSONL:
        return "json"
    return "parquet"


def write_codec_name(codec: UInt8) -> StaticString:
    """Render a WCOMP_* code as the word the SQL surface uses — for error text
    ONLY."""
    if codec == WCOMP_UNCOMPRESSED:
        return "uncompressed"
    if codec == WCOMP_ZSTD:
        return "zstd"
    if codec == WCOMP_GZIP:
        return "gzip"
    if codec == WCOMP_LZ4:
        return "lz4"
    return "snappy"


def write_target_supported(fmt: UInt8, codec: UInt8) -> Bool:
    """True iff a (format, compression) pair has a wired SDK file sink.

    THE ONE TABLE. The parser (which rejects an unwritable COPY at parse time —
    the negative-corpus contract), the exec layer (which maps the pair onto a
    `SinkVariant` arm) and the WIRE DECODER (which must not admit a pair no sink
    can serve) all read this predicate, so "what the SQL surface accepts", "what
    a sink exists for" and "what may arrive from another language" cannot drift
    apart. 13 pairs, matching the 13 file arms of `SinkVariant` one-for-one:

      parquet  x {snappy, uncompressed, zstd(3), gzip(6), lz4_raw}
      csv      x {uncompressed, gzip(6), zstd(3), lz4}
      json     x {uncompressed, gzip(6), zstd(3), lz4}

    Snappy is parquet-only (it is a Parquet page codec, not a whole-file wrapper),
    which is why the pair — not the codec alone — is what gets validated.

    ⚠ THE WIRE CANNOT DELEGATE THIS TO THE PARSER. The two enumerations are
    INDEPENDENT on the wire — 3 formats x 5 codecs = 15 encodable pairs against
    13 servable ones — so a frontend in another language can author
    `(WFMT_CSV, WCOMP_SNAPPY)` from the published enums alone and every
    per-space `*_from_wire` will accept it. The pair is the unit of validity;
    the members are not."""
    if fmt == WFMT_PARQUET:
        return (
            codec == WCOMP_SNAPPY
            or codec == WCOMP_UNCOMPRESSED
            or codec == WCOMP_ZSTD
            or codec == WCOMP_GZIP
            or codec == WCOMP_LZ4
        )
    if fmt == WFMT_CSV or fmt == WFMT_JSONL:
        return (
            codec == WCOMP_UNCOMPRESSED
            or codec == WCOMP_ZSTD
            or codec == WCOMP_GZIP
            or codec == WCOMP_LZ4
        )
    return False


@fieldwise_init
struct WriteTarget(Copyable, Movable, Deinitable):
    """WHERE A QUERY'S ROWS GO — the whole of it.

    ★ THIS IS AN ENVELOPE FIELD, NOT A PLAN NODE, AND THAT IS A DESIGN
    DECISION rather than an implementation convenience. A `PLAN_WRITE` arm on
    `WirePlan`'s oneof would make a SIDE EFFECT placeable anywhere in the tree —
    under a join, twice, below a filter — and every optimizer pass,
    `structural_hash`, `_check_output_schema`, `plan_validator` and
    `plan_wire_check_values` would have to be taught what it means there. As an
    envelope field the arithmetic is fixed and permanent: ONE envelope carries
    ONE statement, so it carries at most one destination, and no pass needs to
    know it exists.

    ⚠ IT IS NOT PART OF `LogicalPlan` AND MUST NOT BECOME PART OF IT. The plan
    is a description of WORK; this is a description of WHERE THE ANSWER GOES.
    Folding it in would put a filesystem path inside the value that
    `EngineContext`'s plan-compile cache keys on, so two identical queries
    writing to two different files would miss the cache — and, worse, a cache
    HIT would then be a plan that writes to somebody else's path.

    Fields:
        path:  the destination, verbatim as the producer wrote it. NOT resolved,
               NOT canonicalised, NOT checked for existence — the RECEIVER's
               filesystem is the only one that can answer any of those, and a
               producer-side check would be a claim about a machine it cannot
               see.
        fmt:   a `WFMT_*` code.
        codec: a `WCOMP_*` code.
    """

    var path: String
    var fmt: UInt8
    var codec: UInt8

    def copy(self) -> Self:
        return Self(self.path, self.fmt, self.codec)

    def describe(self) -> String:
        """`'/tmp/x.parquet' (FORMAT 'parquet', COMPRESSION 'uncompressed')` —
        the SQL spelling, for diagnostics. Reads back as the COPY that would
        have produced it, which is what a reader needs when a refusal names a
        destination."""
        return (
            String("'") + self.path + String("' (FORMAT '")
            + String(write_format_name(self.fmt))
            + String("', COMPRESSION '")
            + String(write_codec_name(self.codec))
            + String("')")
        )
