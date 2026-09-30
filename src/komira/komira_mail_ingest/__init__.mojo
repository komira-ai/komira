"""`komira_mail_ingest` — the PROVIDER-NEUTRAL inbound-mail ingestion seam.

★ WHAT THIS PACKAGE IS. What it means for a domain's mail to have somewhere to
land, said without naming a provider: an exact-match recipient, a routing table
of which the account has exactly ONE active, a drop target, and a verified
identity whose DNS records can rotate underneath you.

★ WHY IT EXISTS. The abstraction does not exist to enable a second cloud; it
exists because the three ways this path silently loses customer mail are all
PROVIDER-INDEPENDENT statements, and a rule that lives only in prose is not
enforced:

  ⛔ HAZARD 1 — the account has exactly ONE ACTIVE route table, so "ensure ours
     is active" DEACTIVATES whatever is live. If the live table's name differs
     from a client's default, activating the default is an account-wide inbound
     outage with no error reported anywhere. Now `plan_activation`, which
     REFUSES.

  ⛔ HAZARD 2 — a recipient is an EXACT WHOLE STRING, not a suffix and not a
     domain tree. `example.com` and `inbound.example.com` cover neither the
     other, so a domain served on both needs two separate rules. Now
     `MailRecipient` (which offers no suffix
     comparison at all) + `assert_table_covers`.

  ⛔ HAZARD 3 — re-creating an identity ROTATES its DKIM keys, leaving the domain
     unverified until DNS is republished, while the create reports success. Now
     `dkim_republish_required`, which DERIVES the rotation from the records
     rather than trusting a status field.

★ THE PACKAGE IS A ZERO-DEPENDENCY LEAF, AND THAT IS THE POINT. Its `deps` list
is empty, so the neutrality is a BUILD-GRAPH FACT rather than a claim in a
comment: a package with no edges cannot reach an AWS client, and nothing here
can quietly grow one. Every function is a PURE decision over values the caller
already read — no socket, no credential, no I/O — which is what makes all three
refusals testable with zero mocks.

WHAT IS IN IT:
  * `mail_ingest`  — the value types (`MailRecipient`, `MailDropTarget`,
                     `MailIngestRoute`, `MailRouteTable`, `MailIdentity`,
                     `DkimRecord`), the three refusals (`plan_activation`,
                     `assert_table_covers`, `assert_route_deliverable`), the
                     rotation predicate (`dkim_republish_required`), the ONE
                     derivation of a route rule's NAME
                     (`receipt_rule_name_for` + its legality refusals
                     `assert_receipt_rule_name_legal` and
                     `assert_receipt_rule_prefix_legal`; the prefix is a
                     parameter defaulting to `DEFAULT_RECEIPT_RULE_PREFIX` —
                     see §1b for why there
                     is exactly one), and the
                     `MailIngestProvider` trait itself.

THE ONE IMPLEMENTATION lives in `komira_aws_iac` (AWS SES). It is deliberately
NOT here: an implementation in the neutral package would put an AWS edge on this
leaf and dissolve the property above.
"""

from .mail_ingest import (
    ACTIVATION_NOOP,
    ACTIVATION_BOOTSTRAP,
    IDENTITY_ABSENT,
    IDENTITY_PENDING,
    IDENTITY_VERIFIED,
    IDENTITY_FAILED,
    MailRecipient,
    recipients_for_domain,
    DEFAULT_RECEIPT_RULE_PREFIX,
    RECEIPT_RULE_NAME_MAX_BYTES,
    receipt_rule_name_for,
    assert_receipt_rule_prefix_legal,
    assert_receipt_rule_name_legal,
    MailDropTarget,
    MailIngestRoute,
    MailRouteTable,
    assert_route_deliverable,
    assert_table_covers,
    plan_activation,
    DkimRecord,
    MailIdentity,
    dkim_republish_required,
    MailIngestProvider,
)
