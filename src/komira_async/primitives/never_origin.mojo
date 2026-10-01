# =============================================================================
# komira_async.primitives.never_origin — static-origin sentinel
# =============================================================================
#
#
# An IoOp whose payload is "self-owned" (no borrow from any caller) is
# parameterized over `never_origin`. The sentinel is a static-constant
# immutable origin — there is no actual storage location it could borrow
# from, so the Mojo borrow checker treats it as inert.
#
# Validation: the obvious spelling
# `ImmutableOrigin[__origin_of(False)].value` does NOT compile in Mojo
# 0.26.3.0.dev2026040216 for THREE reasons:
#   (1) operator is single-underscore `origin_of`, not `__origin_of`
#   (2) `origin_of(False)` rejected — comptime rvalue has no memory origin
#   (3) `ImmutableOrigin` is not a stdlib type
# `StaticConstantOrigin` is the Mojo 0.26.3 stdlib's pre-declared
# static-constant immutable-origin sentinel — singleton origin value
# satisfying `Origin[mut=False]`.
#
# All ~30 IoOp[T, S, never_origin] callsites use this alias verbatim.
# =============================================================================
#
# `StaticConstantOrigin`
# is a Mojo 0.26.3 prelude / builtin symbol; no explicit `from` import is
# required (the bare reference compiles).
# =============================================================================

comptime never_origin = ImmStaticOrigin
