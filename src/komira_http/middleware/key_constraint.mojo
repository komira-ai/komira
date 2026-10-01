# =============================================================================
# komira_http/middleware/key_constraint.mojo — the credential ATTENUATION POD.
# =============================================================================
#
# `KeyConstraint` is what a CONSTRAINED credential (an `spk_` API key) puts on
# the request so the authorization decision point can INTERSECT it with the
# principal's membership-derived authority:
#
#     effective authority = the principal's grants ∩ the key's constraints
#
# ⛔ IT CAN ONLY SUBTRACT. There is no value of this type that means "allow X".
# `KEY_MASK_UNCONSTRAINED` and a NIL `workspace_id` are the ABSENCE of narrowing,
# not the presence of permission — a request carrying them is bounded by exactly
# what the memberships say, which is the unconstrained-session behaviour. A field
# with no allow-value cannot be misread into one.
#
# WHY IT LIVES HERE, in `komira_http`, and not in the auth package:
# for the SAME layering reason `AuthedUser` and `GrantClaim` do. The package
# that RESOLVES the credential and the package that makes the DECISION
# are deliberate SIBLINGS — neither depends on the other, by design.
# `komira_http`
# is the ONE package both already depend on, so it is the only home a shared
# carrier can have without inverting the layering (http → an app package).
#
# ⚠ IT IS NOT `AuthedUser.capabilities`, AND MUST NEVER BE FOLDED INTO IT.
# That field is an AMPLIFYING bitmask belonging to the managed-app GRANT
# credential class: bit 63 is `GRANT_PREAUTHORIZED_SENTINEL`, which makes a
# handler SKIP its store-backed `Authz.require` entirely
# handler SKIP its store-backed authorization check entirely, and an
# authorization adapter treats the bitmask AS
# the authorization with no store call. Folding an ATTENUATING mask into an
# AMPLIFYING bitmask would make bit 63 of a constraint read as "pre-authorized".
# One type per direction; that is the whole reason this is a separate POD.
#
# Encapsulation: two inline `Uuid`s + two scalars — no heap, no
# `UnsafePointer` anywhere, trivially safe in any container.
# =============================================================================

from komira_uuid.uuid import Uuid


comptime KEY_MASK_UNCONSTRAINED: Int64 = -1
"""The ONE spelling of "this credential narrows no capability".

⚠ `0` IS NOT THIS. An empty mask narrows to NOTHING — it denies every
capability. Reading an absent/empty mask as "all" is the open-by-default bug
this constant exists to make impossible to write by accident."""


def mask_allows_ordinal(mask: Int64, cap_ordinal: Int) -> Bool:
    """Does `mask` leave capability ordinal `cap_ordinal` REACHABLE?

    ⚠ THIS NEVER GRANTS. `True` means "the mask does not subtract this
    capability" — the membership-derived decision still has to allow it. The
    function is only ever consulted on a branch that has ALREADY allowed, so
    `True` returns an existing allow and `False` turns it into a deny.

    Total, and free of signed-shift semantics:
      * `KEY_MASK_UNCONSTRAINED` (-1) — no narrowing; every ordinal reachable.
      * an out-of-range ordinal (negative, or >= 63) — FALSE, fail-closed. A
        shift by >= 64 is UB-shaped and 63 is the sign bit; neither may be
        allowed to read as "permitted".
      * otherwise — bit `cap_ordinal` of `mask`. **`mask == 0` therefore denies
        EVERY capability.**"""
    if mask == KEY_MASK_UNCONSTRAINED:
        return True
    if cap_ordinal < 0 or cap_ordinal >= 63:
        return False
    return ((mask >> Int64(cap_ordinal)) & Int64(1)) == Int64(1)


struct KeyConstraint(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """The attenuation a constrained credential carries onto the request.

    Fields:
      constrained     — False ⇒ this request carries NO attenuation (a session).
                        The two constructors are the only way to set it, and
                        `constrained()` is reached only from a resolved
                        credential row, so a constrained value cannot be
                        conjured at a call site.
      org_id          — the ORG attenuation. Always set when `constrained`. ⚠
                        This is NOT the org the request is authorized BY — the
                        request's org is DERIVED (path / selector / sole
                        membership) and membership-checked FIRST; this value is
                        a filter it must ALSO satisfy. Both fences are
                        load-bearing and neither substitutes for the other.
      workspace_id    — the WORKSPACE attenuation. The NIL UUID means "no
                        workspace narrowing" — NOT "every workspace", which is
                        the same statement read from the other side: the
                        principal's memberships still bound it.
      capability_mask — the CAPABILITY attenuation. `KEY_MASK_UNCONSTRAINED`
                        (-1) = no narrowing; otherwise bit N ⇔ ordinal N is
                        reachable, and `0` reaches nothing."""

    var constrained: Bool
    var org_id: Uuid
    var workspace_id: Uuid
    var capability_mask: Int64

    def __init__(out self):
        """The UNCONSTRAINED value (the default) — a session. Deliberately the
        zero-arg constructor so a forgotten field cannot produce a *constrained*
        value with empty narrowings; the failure direction of a mistake here is
        "no attenuation applied", which is today's behaviour, never "a fabricated
        attenuation that happens to allow"."""
        self.constrained = False
        self.org_id = Uuid()
        self.workspace_id = Uuid()
        self.capability_mask = KEY_MASK_UNCONSTRAINED

    @staticmethod
    def unconstrained() -> KeyConstraint:
        """A request with NO attenuation — the SESSION path states this
        explicitly at its own site rather than defaulting into it."""
        return KeyConstraint()

    @staticmethod
    def of(
        org_id: Uuid, workspace_id: Uuid, capability_mask: Int64
    ) -> KeyConstraint:
        """The attenuation of a resolved API key. Built by exactly one function
        in the auth library, from exactly one source (an `api_key` row)."""
        var out = KeyConstraint()
        out.constrained = True
        out.org_id = org_id
        out.workspace_id = workspace_id
        out.capability_mask = capability_mask
        return out^

    def has_workspace_narrowing(self) -> Bool:
        """True iff this constraint narrows to ONE workspace (a non-NIL
        `workspace_id`). An unconstrained credential never narrows."""
        return self.constrained and self.workspace_id != Uuid()
