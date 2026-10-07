# =============================================================================
# declared_scalar_udf.mojo — ★ THE TRAIT THAT MAKES A SECOND DTYPE DECLARATION
#                              UNSPELLABLE AT A NAME-RESOLUTION DOOR.
# =============================================================================
#
# Every non-SQL UDF surface resolves its function at
# COMPTIME: `register_scalar[affine]` takes the customer's function as a
# comptime parameter, so `T` and `O` are `//`-inferred from its signature and
# `ScalarUdf`'s `IN_TYPE`/`OUT_TYPE` are `comptime` MEMBERS with no field, no
# constructor argument and no method parameter behind them. Nothing can state
# a dtype a second time because there is nowhere to write one.
#
# SQL HAS ONLY A RUNTIME STRING. `SELECT affine(x) FROM t` yields the name
# `"affine"` and nothing else, so a name -> (handle, dtypes) index has to exist
# as RUNTIME DATA for the binder to read. That index is the new place a dtype
# could be written — and if it can be written, it can disagree with the one the
# customer's signature already states. That is a real bug class (a
# COUNT(DISTINCT) reading at a fixed 8-byte stride, a kernel bitcasting int32
# to int64), so the index needs to be populated by
# something that CANNOT be handed a dtype.
#
# ── WHY A TRAIT AND NOT A FUNCTION WITH TWO `ArrowType` ARGUMENTS ────────────
#
# `declare_udf(name, handle, in_type, out_type)` would work and would be wrong
# in the specific way this file exists to prevent: it has two parameters whose
# arguments a caller CHOOSES. One caller deriving them correctly does not stop
# the next from typing `ArrowType.INT64` because the function it wraps happens
# to return one today. The check would then be a REVIEW obligation.
#
# A generic over this trait has NO dtype parameter at all:
#
#     def declare[U: DeclaredScalarUdf](mut self, read udf: U) raises
#
# The two types are read off `U` — `U.IN_TYPE`, `U.OUT_TYPE` — which for the
# only conformer in the tree are `ArrowType.from_dtype(Self.T)` /
# `(Self.O)`, i.e. the SAME `T`/`O` inferred from the customer's function
# signature that produce the kernel's `IN_TAG`/`OUT_TAG` and the plan node's
# types. The call site cannot state a dtype because the call site has no
# argument for one, and it cannot state a NAME either: `name()` is read off the
# value, and that value's name came from `register_scalar`'s single `name`
# parameter. ⇒ `catalog.declare_udf(affine)` restates NOTHING.
#
# ── WHY IT LIVES IN `komira_plan_expr` ───────────────────────────────────────────
#
# The two parties are `komira_engine_operators` (declares `ScalarUdf`) and
# `komira_sdk` (declares the SQL catalog the binder reads). The edge runs
# komira_sdk -> komira_engine_operators, so engine_operators cannot name a type
# from the SDK, and `komira_sdk` HAS NO SOURCE IMPORT OF ENGINE_OPERATORS AT
# ALL (the SDK is engine-free by design). Both packages depend on the core packages, and this
# trait is what lets the SQL catalog accept a `ScalarUdf` WITHOUT NAMING IT:
# the catalog's method is generic over the trait, and the concrete type is
# supplied by the one caller that can already see both (`komira_sdk_exec`).
#
# ⛔ SO DO NOT "SIMPLIFY" THIS BY IMPORTING `ScalarUdf` INTO THE SQL CATALOG.
# That single import re-couples the SDK to the engine and undoes that
# separation; the generic is not indirection for its own sake, it is the only
# spelling that satisfies both constraints at once.
#
# ⚠ NON-RAISING ACCESSORS, MATCHING `ScalarUdf`. `handle()` and `name()` are
# plain `def`s on the conformer; a trait requirement that raised would force
# every reader of the index into a `try`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType


trait DeclaredScalarUdf(Copyable, Movable):
    """A registered scalar UDF whose two dtypes are properties of its TYPE.

    Conformed by `komira_engine_operators.scalar_udf.ScalarUdf`, which is the
    only conformer and is meant to stay that way: the trait's whole value is
    that `IN_TYPE`/`OUT_TYPE` are `comptime` members derived from a customer
    function's signature, and a conformer that computed them from a field
    would satisfy the trait while giving up the property.

    ⛔ DO NOT ADD A `dtype` METHOD, A `set_*` OR A FIELD. Every member here is
    read-only and derived; the trait is a proof obligation, not a container.
    """

    comptime IN_TYPE: ArrowType
    """The `ArrowType` of the argument column, from the function's signature."""

    comptime OUT_TYPE: ArrowType
    """The `ArrowType` of the produced column, from the function's signature."""

    def handle(self) -> Int:
        """The generation-carrying registry handle. PROCESS-LOCAL."""
        ...

    def name(self) -> String:
        """THE name. There is only one, which is the point."""
        ...
