# =============================================================================
# route_decision.mojo — what routing one request decided: DENY, PUBLIC, or
# GOVERNED by a requirement (an action on a resource).
# =============================================================================
#
# Five properties make a forgotten route land on DENY:
#
#   1. The zero value of `RouteDecision` is DENY. A default-constructed
#      decision, an unfilled field and an untouched list slot all deny; there
#      is no "unset" state distinct from deny.
#   2. `ResourceCatalog.route` returns a `RouteDecision`, never an `Optional`,
#      so there is no `None` for a caller to fall through on.
#   3. There is no `is_denied()`. A caller lets a request proceed only after
#      an affirmative `is_governed()` or `is_public()`, so an outcome kind
#      added later is refused at every existing call site.
#   4. `requirement()` raises unless the decision is governed, so the inert
#      requirement inside a deny or a public decision cannot be acted on.
#   5. A public route is a declared row (`RouteDecision.public()`); absence
#      from a table is never publicness.
#
# Encapsulation: value types only (Strings and the `komira_authz_api` values);
# no pointer, no wildcard origin.
# =============================================================================

from komira_authz_api import AuthzAction, AuthzResource


comptime ROUTE_OUTCOME_DENY: Int = 0
"""The zero value: refused. Also what a forgotten route yields."""

comptime ROUTE_OUTCOME_GOVERNED: Int = 1
"""The route names a resource and an action; `requirement()` says which."""

comptime ROUTE_OUTCOME_PUBLIC: Int = 2
"""The route is declared to be served without a credential."""


struct ResourceRequirement(Copyable, Movable, Deinitable):
    """What a governed request must be authorized for: `action` on
    `resource`. The resource's `id` is empty when the action applies to the
    kind as a whole (a create, a listing)."""

    var action: AuthzAction
    var resource: AuthzResource

    def __init__(out self, var action: AuthzAction, var resource: AuthzResource):
        self.action = action^
        self.resource = resource^

    def __init__(out self):
        """The inert requirement held by a non-governed decision: the `admin`
        action on an empty kind. `RouteDecision.requirement()` never returns
        it."""
        self.action = AuthzAction.admin()
        self.resource = AuthzResource(kind=String(""), id=String(""))


struct RouteDecision(Copyable, Movable, Deinitable):
    """The outcome of routing one request: DENY (the zero value), GOVERNED
    (with a requirement) or PUBLIC. There is no `is_denied()`: a caller must
    establish `is_governed()` or `is_public()` before serving."""

    var _outcome: Int
    var _requirement: ResourceRequirement

    def __init__(out self):
        """DENY, the zero value."""
        self._outcome = ROUTE_OUTCOME_DENY
        self._requirement = ResourceRequirement()

    def __init__(out self, outcome: Int, var requirement: ResourceRequirement):
        self._outcome = outcome
        self._requirement = requirement^

    @staticmethod
    def deny() -> RouteDecision:
        """DENY, spelled out where a call site means it."""
        return RouteDecision()

    @staticmethod
    def public() -> RouteDecision:
        """PUBLIC: served without a credential and without an identity."""
        return RouteDecision(ROUTE_OUTCOME_PUBLIC, ResourceRequirement())

    @staticmethod
    def governed(var requirement: ResourceRequirement) -> RouteDecision:
        """GOVERNED by `requirement`."""
        return RouteDecision(ROUTE_OUTCOME_GOVERNED, requirement^)

    @staticmethod
    def governed(
        var action: AuthzAction, var resource: AuthzResource
    ) -> RouteDecision:
        """GOVERNED by `action` on `resource`."""
        return RouteDecision(
            ROUTE_OUTCOME_GOVERNED, ResourceRequirement(action^, resource^)
        )

    def is_governed(self) -> Bool:
        """True iff the route names a resource and an action."""
        return self._outcome == ROUTE_OUTCOME_GOVERNED

    def is_public(self) -> Bool:
        """True iff the route was declared public."""
        return self._outcome == ROUTE_OUTCOME_PUBLIC

    def outcome(self) -> Int:
        """The `ROUTE_OUTCOME_*` value, for tests and logs."""
        return self._outcome

    def requirement(self) raises -> ResourceRequirement:
        """The requirement of a governed decision. Raises on any other
        outcome."""
        if not self.is_governed():
            raise Error(
                "RouteDecision.requirement: the decision is not governed"
                " (outcome "
                + String(self._outcome)
                + ")"
            )
        return self._requirement.copy()
