# =============================================================================
# refusal_tokens -- the shared table of plan refusal tokens and their classes
# =============================================================================
#
# A plan producer or a door on a plan refuses by raising an `Error` whose text
# holds a named token. A caller that sorts those refusals into classes it can
# act on reads this table, so the optimizer's result type and a physical-plan
# result type give each token the same class. The package imports only the
# standard library: a package that may not depend on the optimizer can import
# it.
#
# The table holds the token strings. Their constants are declared in other
# packages, none of which this package may import:
#
#     SCAN_BINDING_EPOCH_MISMATCH, SCAN_BINDING_HANDLE_NOT_BOUND
#         komira_scan_source.scan_resolver
#     OPTIMIZER_UNRESOLVED_SCALAR_DEPS
#         komira_optimizer.optimizer_result (OPTIMIZE_REFUSAL_UNRESOLVED_DEPS).
#         No code in the tree raises it yet (the round-cap driver is not in
#         this tree); the row is kept for the UNRESOLVED_DEPS class.
#     PHYSICAL_PLAN_IR_VERSION_MISMATCH, PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE
#         komira_plan_ir.physical_plan
#     PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN,
#     PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG,
#     PHYSICAL_PLAN_PURITY_UNCHECKABLE
#         komira_plan_ir.physical_plan_purity_gate
#
# The welded test pins each string literally. komira_optimizer's
# test_optimizer_result checks the scan-binding and scalar-dependency strings
# equal the declared constants.
#
# No token is a substring of another (the welded test checks it), so a message
# that holds one token matches one entry. For a message that holds two,
# `message_class` answers with the entry that comes first in the table.
# =============================================================================


struct RefusalClass(ImplicitlyCopyable, Movable, Equatable):
    """What a caller can do about a refusal. Layout: one Int.

    PASS_REFUSAL     a pass refused the plan. No token in the table has this
                     class: it is the class of every refusal the table does
                     not name.
    PRODUCER_BUG     a door on a physical plan refused what its producer
                     built. The producer's defect, not the caller's.
    SCAN_BINDING     the plan carries a scan handle the executing registry
                     cannot resolve. The caller can rebind and resubmit.
    UNRESOLVED_DEPS  the plan's scalar dependencies did not reach a fixpoint.
                     Resubmitting the same plan gets the same answer.
    """

    var code: Int

    comptime PASS_REFUSAL = RefusalClass(0)
    comptime PRODUCER_BUG = RefusalClass(1)
    comptime SCAN_BINDING = RefusalClass(2)
    comptime UNRESOLVED_DEPS = RefusalClass(3)

    def __init__(out self, code: Int):
        self.code = code

    def __eq__(self, other: Self) -> Bool:
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        return self.code != other.code

    def is_known(self) -> Bool:
        """True iff `code` is one of the four classes above."""
        return self.code >= 0 and self.code <= 3

    def name(self) -> String:
        """The class's name as spelled above, or `UNKNOWN(<code>)`."""
        if self == RefusalClass.PASS_REFUSAL:
            return String("PASS_REFUSAL")
        if self == RefusalClass.PRODUCER_BUG:
            return String("PRODUCER_BUG")
        if self == RefusalClass.SCAN_BINDING:
            return String("SCAN_BINDING")
        if self == RefusalClass.UNRESOLVED_DEPS:
            return String("UNRESOLVED_DEPS")
        return String("UNKNOWN(") + String(self.code) + String(")")


struct RefusalToken(ImplicitlyCopyable, Movable):
    """One row of the table: a token and its class."""

    var token: StaticString
    var refusal_class: RefusalClass

    def __init__(out self, token: StaticString, refusal_class: RefusalClass):
        self.token = token
        self.refusal_class = refusal_class


def plan_refusal_tokens() -> List[RefusalToken]:
    """Every token the table names, with its class, in table order."""
    var t = List[RefusalToken](capacity=8)
    t.append(RefusalToken("SCAN_BINDING_EPOCH_MISMATCH", RefusalClass.SCAN_BINDING))
    t.append(RefusalToken("SCAN_BINDING_HANDLE_NOT_BOUND", RefusalClass.SCAN_BINDING))
    t.append(RefusalToken("OPTIMIZER_UNRESOLVED_SCALAR_DEPS", RefusalClass.UNRESOLVED_DEPS))
    t.append(RefusalToken("PHYSICAL_PLAN_IR_VERSION_MISMATCH", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG", RefusalClass.PRODUCER_BUG))
    t.append(RefusalToken("PHYSICAL_PLAN_PURITY_UNCHECKABLE", RefusalClass.PRODUCER_BUG))
    return t^


def token_class(token: StringSlice) -> Optional[RefusalClass]:
    """The class of `token` if it is exactly a token of the table, else None."""
    var wanted = String(token)
    var table = plan_refusal_tokens()
    for i in range(len(table)):
        if String(table[i].token) == wanted:
            return Optional[RefusalClass](table[i].refusal_class)
    return None


def message_class(message: StringSlice) -> Optional[RefusalClass]:
    """The class of the first table token that `message` contains, else None.

    A raiser writes its token inside a longer message, so this is a substring
    search; `token_class` is the exact lookup.
    """
    var text = String(message)
    var table = plan_refusal_tokens()
    for i in range(len(table)):
        if text.find(String(table[i].token)) >= 0:
            return Optional[RefusalClass](table[i].refusal_class)
    return None
