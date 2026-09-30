# =============================================================================
# komira_validation_run/validation_run_tag.mojo — THE ONE PLACE THE
#   VALIDATION-RUN CORRELATOR'S TAG/LABEL KEY IS WRITTEN DOWN.
# =============================================================================
#
# ── WHY THIS PACKAGE EXISTS, AND WHY IT IS A LEAF WITH NO DEPS ───────────────
#
# A cleanup that deletes by matching rules alone can delete a concurrent run's
# IN-FLIGHT resource: the resource genuinely matches every rule the billing
# class states, so nothing is wrong with the delete mechanism. What is missing
# is ownership — the only fact that could stop it: **whose it is.**
#
# Without a per-run correlation ("was resource R created by THIS validation
# run"), a cloud-leak checker can only guess, fleet-wide, and a guess that
# deletes is an outage waiting for a concurrent run. This constant is the fact
# that replaces the guess: ONE id, generated once per validation RUN (never per step), stamped
# on every billable resource that run creates, and the ONLY thing an unattended
# auto-delete is permitted to act on.
#
# ── ⛔ WHY THE KEY LIVES HERE AND NOT BESIDE EITHER CLOUD'S CLIENT ───────────
# It is stamped by BOTH clouds' creation paths (an ECS `RunTask` tag and a Cloud
# Run label) and READ by a third party that is neither (an external cloud-leak
# checker). A copy in each would be three copies that drift silently — and a tag key that
# drifts does not fail: it stamps a key nothing looks for, and the checker
# reports a clean fleet forever. So it is written down ONCE, here, and every
# consumer imports it.
#
# Having no deps is deliberate and load-bearing: this package is imported by
# both cloud wire layers (the ECS wire and the Cloud Run wire), whose closures
# are deliberately tight and disjoint. A dep here would be placed upstream of
# both, widening both closures to carry one string.
#
# ── ⛔ THE SPELLING IS CONSTRAINED BY BOTH CLOUDS AT ONCE, AND THE TWO
#      COMMON KEY CONVENTIONS EACH FAIL ON THE OTHER CLOUD ──────────────────
#
#   `komira:placement` / `komira:managed-by` — the colon-namespaced AWS
#       tag-key convention the AWS clients use. A COLON is
#       legal in an AWS tag key (percent-encoded on the wire) and is REJECTED by
#       GCP: a resource label key is `[a-z]([a-z0-9_-]{0,61}[a-z0-9])?` — no
#       colon, no dot, no slash, no uppercase.
#
#   `<domain>/<name>` (for example `example.dev/job-id`) — the KUBERNETES
#       label-key convention. A dot and a slash are legal in a
#       k8s label key and are REJECTED by GCP resource labels for the same rule.
#
# ⇒ the key below is the intersection: lowercase alphanumerics and hyphens only,
# starting with a letter. Legal verbatim as an AWS tag key AND as a GCP resource
# label key, with no per-cloud rewriting — because a key that is rewritten per
# cloud is two keys, which is what this file exists to prevent.
#
# ⚠ AND IT IS DELIBERATELY NOT SPELLED `run-id`. The bare term `run_id` already
# names other things in a deploy system (a throwaway-run scope, a job-store
# partition key), and neither of those meanings is this one. Another meaning
# sharing the name would make every search for `run_id` ambiguous for a reader
# trying to answer "who deletes this resource".
# =============================================================================

comptime VALIDATION_RUN_TAG_KEY: String = "komira-ci-run-id"
"""The AWS tag key / GCP label key carrying the id of the validation RUN that
created a resource.

⛔ THE VALUE IS PER-RUN, NEVER PER-STEP. A run's driver mints ONE id before its
first step and passes the same one to every release-tool invocation underneath
and to the terminal cloud-leak check. Minting per step would make the terminal
check unable to name its own earlier steps' resources — which
is the capability, not a detail of it.

⛔ AND IT IS NOT A SECRET, NOT AN AUTHORIZATION, AND NOT A NAMESPACE. Anything
can stamp any value. It narrows an UNATTENDED auto-delete to resources this run
can PROVE it made; it does not defend against a hostile stamper, and no code may
grant a capability on the strength of it."""


comptime VALIDATION_RUN_ID_MAX_LEN: Int = 63
"""GCP resource-label VALUES cap at 63 characters (AWS tag values allow 256), so
63 is the binding constraint. A generated id longer than this would be TRUNCATED
BY GCP and stamped in full on AWS — i.e. the same run would carry two different
ids on the two clouds, and the checker would match neither reliably."""


def is_valid_validation_run_id(value: String) -> Bool:
    """Is `value` legal as BOTH an AWS tag value and a GCP label value?

    ⛔ THE INTERSECTION, NOT EITHER CLOUD'S RULE. GCP is the strict side:
    `[a-z0-9_-]{0,63}` (lowercase only). AWS accepts far more. Validating
    against AWS alone would let a run mint an id that GCP silently rejects at
    create time, turning "this resource is mine" into "this resource failed to
    be created" — a much worse failure than a refused flag.

    ⚠ EMPTY IS NOT VALID, and that is the point of having a predicate at all:
    an empty id is the absent-versus-empty collapse, which here would mean
    "delete everything that carries an empty tag" — i.e. everything
    untagged.

    ⚠ MEASURED IN BYTES, DELIBERATELY. Mojo refuses a bare `len(String)` because
    UTF-8 makes "length" ambiguous, and here the byte count is the RIGHT reading
    of the three: AWS and GCP both cap a tag/label value in BYTES on the wire,
    not in code points — so a byte length is what the clouds will measure. The
    character-set loop below makes every legal value ASCII anyway, where all
    three readings coincide; the distinction only bites on a value this predicate
    is about to reject."""
    var n = value.byte_length()
    if n == 0:
        return False
    if n > VALIDATION_RUN_ID_MAX_LEN:
        return False
    for i in range(n):
        var c = Int(value.as_bytes()[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        var sep = c == ord("-") or c == ord("_")
        if not (lower or digit or sep):
            return False
    return True


# =============================================================================
# ⭐ THE SECOND MARK — THE AUTHORED RETENTION OF THE NODE THAT MADE THE RESOURCE
# =============================================================================
#
# ── THE INTERACTION THIS EXISTS TO RESOLVE ──────────────────────────────────
# Design rule: RETAIN is respected on both REPLACEMENT and DELETE. The default
# is DELETE, and the author opts into retain.
#
# ⇒ A RETAIN'd node the platform would otherwise destroy — a node a rollback's
# delete set names, or one a replacement supersedes — is LEFT STANDING, outside
# the graph, still live, still billing. That is the only coherent reading of
# that rule and it is what CloudFormation does. It also manufactures EXACTLY the
# shape a cloud-leak checker hunts: an orphan nothing in the
# declared state accounts for. Without an agreement, the platform honouring the
# author's own instruction produces a resource the enforcement gate reports as a
# leak on every run, FOREVER — and a gate that cries wolf on the correct path is
# a gate people learn to ignore.
#
# ── ⛔ WHY A MARK ON THE RESOURCE, AND NOT A LEDGER ROW ──────────────────────
# The alternative considered and rejected was a "deliberately retained" ledger
# the deploy plane writes and the checker reads. Four grounds, in order of
# weight:
#
#   1. A LEDGER IS A SELF-REPORT; A MARK IS AN OBSERVATION. A ledger is written
#      by the party being gated, into a store that party owns — the shape of a
#      self-written attestation file, which must never be read as
#      authorization. A label read out of the same cloud API response that
#      found the resource has nothing to forge and nothing to go stale.
#   2. A LEDGER CANNOT SURVIVE THE FAILURE IT DESCRIBES. A rollback runs because
#      a process is dying; a row written at rollback time is precisely a
#      JOURNAL, which a rollback should not depend on when a manifest diff can
#      say the same thing.
#      The retention statement is available at CREATE time, when the process is
#      healthy — stamp it then.
#   3. A LEDGER IS A SUPPRESSION LIST. One bug that writes a row for a node it
#      should have deleted silences the checker permanently. A mark projected
#      from AUTHORED retention cannot suppress a node whose author said DELETE.
#   4. IT COSTS THE CHECKER NOTHING. The retention label rides in the same
#      `labels` / `Tags` map the run-id already does, in the same response. A
#      ledger would need a bucket read, a credential, and a proto parse in the
#      checker — three new failure modes on the enforcement path.
#
# ── ⛔ THE ABSENCE OF THE MARK IS NEVER A PASS ──────────────────────────────
# A resource-plane resource carrying the run-id and NO retention mark is
# LEFT-BEHIND, not retained. Forgetting to stamp therefore produces a RED run
# rather than a silent exemption — the property that makes a mark safe where a
# suppression list is not. And a failure to DERIVE this key is an ENUMERATION
# ERROR in the checker, never a clean fleet: "found nothing to look for" and
# "found nothing" must not be the same output.

comptime RESOURCE_RETENTION_TAG_KEY: String = "komira-ci-retention"
"""The AWS tag key / GCP label key carrying the AUTHORED `Retention` of the
manifest node that created this resource.

⛔ SAME CHARACTER-SET INTERSECTION AS `VALIDATION_RUN_TAG_KEY` and for the same
reason: legal verbatim as an AWS tag key AND as a GCP resource label key
(`[a-z]([a-z0-9_-]{0,61}[a-z0-9])?`), with no per-cloud rewriting — a key
rewritten per cloud is two keys.

⛔ IT IS A STATEMENT ABOUT POLICY, NOT AN AUTHORIZATION. It tells a reader why a
resource the declared state no longer references is still standing. It grants
nothing, and no code may take a capability from it — the same sentence
`VALIDATION_RUN_TAG_KEY` carries."""

comptime RETENTION_TAG_VALUE_DELETE: String = "delete"
"""The mark on a node whose author did NOT ask for retention — the DEFAULT, and
the value `RETENTION_UNSPECIFIED` projects to. A resource carrying this and no
longer referenced by the declared state IS a leak."""

comptime RETENTION_TAG_VALUE_RETAIN: String = "retain"
"""The mark on a node whose author explicitly asked to keep it. A resource
carrying this and no longer referenced by the declared state is a DELIBERATE
RETAINED ORPHAN — reported by name, never deleted by the enforcer, and not
red."""

# The wire ordinals of the manifest's `Retention` enum. ⛔ WRITTEN AS INTS HERE
# ON PURPOSE: this package has no deps, and importing the generated manifest
# module to reach `Retention.RETENTION_RETAIN_KEEP` would place a proto codegen
# dep upstream of BOTH cloud wire layers — the one thing having no deps exists
# to prevent. The duplication must therefore be CHECKED rather than trusted: a
# consumer that does depend on the generated enum asserts these three ints
# against it.
comptime _RETENTION_ORDINAL_UNSPECIFIED: Int = 0
comptime _RETENTION_ORDINAL_DELETE: Int = 1
comptime _RETENTION_ORDINAL_RETAIN_KEEP: Int = 2


def retention_tag_value(retention_ordinal: Int) raises -> String:
    """Project a manifest `Retention` ordinal onto the mark's value.

    UNSPECIFIED (the proto3 zero) and DELETE both project to `delete` — the
    retention rule above (default DELETE; the author says retain), and the same
    collapse a graph teardown makes (it skips only RETAIN_KEEP).

    ⛔ AN ORDINAL OUTSIDE THE ENUM RAISES. There is no default arm, because both
    defaults are catastrophic in opposite directions: defaulting to `delete`
    would let a retained resource be reported (and one day deleted) as a leak,
    and defaulting to `retain` would let a genuinely leaked resource be
    classified as deliberate and disappear from the enforcement gate forever. A
    `Retention` value added tomorrow must state which side it is on."""
    if (
        retention_ordinal == _RETENTION_ORDINAL_UNSPECIFIED
        or retention_ordinal == _RETENTION_ORDINAL_DELETE
    ):
        return String(RETENTION_TAG_VALUE_DELETE)
    if retention_ordinal == _RETENTION_ORDINAL_RETAIN_KEEP:
        return String(RETENTION_TAG_VALUE_RETAIN)
    raise Error(
        String("retention_tag_value: unknown Retention ordinal ")
        + String(retention_ordinal)
        + String(
            " — this projection has NO default arm on purpose. Defaulting to"
            " 'delete' would let a retained resource be reported as a leak;"
            " defaulting to 'retain' would let a real leak be classified as"
            " deliberate and vanish from the enforcement gate. State the new"
            " value's side here."
        )
    )


def is_valid_retention_tag_value(value: String) -> Bool:
    """Is `value` one of the two marks this projection can emit?

    ⛔ THE CHECKER'S CLASSIFICATION MUST NOT TREAT AN UNRECOGNISED VALUE AS
    `retain`. A mark it cannot parse is a mark it cannot act on, and the
    fail-closed reading is "not proven retained" — i.e. still left-behind. This
    predicate is what a reader on either side of the agreement asks."""
    return (
        value == String(RETENTION_TAG_VALUE_DELETE)
        or value == String(RETENTION_TAG_VALUE_RETAIN)
    )
