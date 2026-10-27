# =============================================================================
# `to_glob_options` — the ParquetReadOptions -> GlobDiscoveryOptions mapping,
# kept OFF the POD so the POD names nothing outside the plan and expression
# libraries.
# =============================================================================
#
# ⭐ WHY THIS FILE EXISTS AT ALL, AND WHY THE MAPPING IS NOT INLINED AT ITS ONE
# CALL SITE. `parquet_read_options.mojo` used to declare this as a METHOD, and
# the method's return type is the ONLY reason that file named
# `komira_fs.file_discovery`. That single import is what kept
# `ParquetReadOptions` off a facade's floor-clean set: the facade stages a
# module VERBATIM iff its transitive closure names only the plan libraries and
# the stdlib, and `parquet_read_options` is the single most-imported blocked
# module in the `komira_sdk` test corpus.
#
# ⛔ IT IS A MOVE, NOT A REWRITE. The body below is the old method's body,
# character for character; `parquet_read_options.mojo` keeps every field and
# every other verb. A SECOND SPELLING of the mapping is exactly the hazard a
# facade generator exists to prevent, so there is one spelling and it is here.
#
# ⚠ AND IT IS NOT INLINED AT THE CALL SITE, DELIBERATELY. Inlining
# `GlobDiscoveryOptions(allow_empty_glob=options.allow_empty_glob)` into
# `EngineContext._try_build_hive_partitioned_plan_eager` would have deleted the
# only unit test of the mapping, leaving a one-line self-evidently-correct
# conversion asserted by nothing. Keeping it a named, callable function keeps
# that assertion real (`test_plan_validation_gate_direct` carries it).
# =============================================================================

from komira_fs.file_discovery import GlobDiscoveryOptions

from komira_sdk.parquet_read_options import ParquetReadOptions


@always_inline
def to_glob_options(opts: ParquetReadOptions) -> GlobDiscoveryOptions:
    """Map a `ParquetReadOptions` down into the discovery-layer
    `GlobDiscoveryOptions` (which carries ONLY the empty-match policy the glob
    engine consumes).

    The mapping is total and one-way: `allow_empty_glob` is the ONE knob the
    discovery layer reads. The other four `ParquetReadOptions` fields are
    consumed above the discovery layer (or, for the two Hive-lowering knobs,
    not consumed at all today) and have no `GlobDiscoveryOptions` counterpart.
    """
    return GlobDiscoveryOptions(allow_empty_glob=opts.allow_empty_glob)
