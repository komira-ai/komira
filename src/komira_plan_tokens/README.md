# komira_plan_tokens

The named tokens a plan producer or a door on a plan puts in the text of a
refusal, and the class of each: what a caller can do about it. The optimizer's
result type and the packages that build or check a physical plan read the same
table, so a token has one class wherever it is caught. The package depends on
nothing but the standard library.

| class | meaning | tokens |
|---|---|---|
| `PASS_REFUSAL` | a pass refused the plan; the class of every refusal the table does not name | none |
| `PRODUCER_BUG` | a door on a physical plan refused what its producer built | `PHYSICAL_PLAN_IR_VERSION_MISMATCH`, `PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE`, `PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN`, `PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG`, `PHYSICAL_PLAN_PURITY_UNCHECKABLE` |
| `SCAN_BINDING` | the plan carries a scan handle the executing registry cannot resolve; rebind and resubmit | `SCAN_BINDING_EPOCH_MISMATCH`, `SCAN_BINDING_HANDLE_NOT_BOUND` |
| `UNRESOLVED_DEPS` | the plan's scalar dependencies did not reach a fixpoint | `OPTIMIZER_UNRESOLVED_SCALAR_DEPS` |

`token_class` looks a token up exactly. `message_class` finds the first table
token inside a longer message, which is how a raiser writes it. No token is a
substring of another.

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_plan_tokens import RefusalClass, plan_refusal_tokens, token_class, message_class

var cls = message_class("bind: SCAN_BINDING_EPOCH_MISMATCH (registry 2)")
assert_true(cls.value() == RefusalClass.SCAN_BINDING)
assert_false(Bool(message_class("pass x refused")))
assert_equal(token_class("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN").value().name(), String("PRODUCER_BUG"))
assert_equal(len(plan_refusal_tokens()), 8)
```
