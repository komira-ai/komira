# =============================================================================
# komira_plan_tokens -- the plan refusal tokens and the class of each.
# =============================================================================
#
# A leaf: it imports only the standard library, so the optimizer and the
# packages that build or check a physical plan can all depend on it.
#
#     from komira_plan_tokens import RefusalClass, message_class
#     var cls = message_class(String(e))
#     if cls and cls.value() == RefusalClass.SCAN_BINDING:
#         ...
# =============================================================================

from .refusal_tokens import (
    RefusalClass,
    RefusalToken,
    plan_refusal_tokens,
    token_class,
    message_class,
)
