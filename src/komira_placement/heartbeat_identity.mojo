# =============================================================================
# komira_placement/heartbeat_identity.mojo — THE JOB ID A PLACED VM BEATS WITH
# =============================================================================
#
# ⛔⛔ THE PLACEMENT NAME IS NOT THE JOB ID. A VM conformer stamps the job id its
# on-VM supervisor reports under:
#
#   GcpCloudProvider.create      inst.add_metadata(META_JOB_ID, <job id>)
#   build_vm_bootstrap (EC2)     _export(ENV_JOB_ID, <job id>)
#
# `spec.name` is `derive_pod_name(prefix, id)` = `<prefix>-<last 12 hex>`. The
# job manager's heartbeat handler decodes the beat's `job_id` as a hyphenated
# UUID, which raises on `t` — so stamping `spec.name` would make EVERY beat a
# placed VM sends a 400 `bad_request`, before the FSM is consulted, on every
# cloud. Such a defect hides behind any transport defect that stops beats
# reaching the wire at all: fixing the transport alone moves the failure from
# "nothing arrives" to "everything arrives and is refused".
#
# ★ THE CHECK IS THE CANONICAL TEXT `Uuid.to_hyphenated()` PRODUCES — 36
# characters, hyphens at 8/13/18/23, lowercase hex elsewhere — which is a STRICT
# SUBSET of what the handler's hyphenated-UUID decoder accepts. Strict on
# purpose: that decoder ignores separators and stops after sixteen bytes, so a
# value with trailing junk DECODES, and a boot contract must not rest on the
# handler happening to ignore part of what it was sent. That the handler ACCEPTS
# this form is asserted end to end by the bridges that place VMs (stamped value
# -> heartbeat parse -> RUNNING), not here.
#
# ⚠ A PURE STRING CHECK, DELIBERATELY, AND NOT A CALL INTO A DATABASE UUID
# TYPE. Every VM conformer imports this, and not all of them depend on the
# package that defines that type; the check it would buy is the one above,
# restated. Encapsulation: String in, String out; no pointer, no wildcard.
# =============================================================================

from komira_placement.placement_types import PlacementSpec


comptime _CANONICAL_UUID_LEN: Int = 36


def is_canonical_job_id(text: String) -> Bool:
    """True iff `text` is a UUID in the exact canonical form `to_hyphenated()`
    renders: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, LOWERCASE hex. Pure."""
    var b = text.as_bytes()
    if len(b) != _CANONICAL_UUID_LEN:
        return False
    for i in range(_CANONICAL_UUID_LEN):
        var c = b[i]
        if i == 8 or i == 13 or i == 18 or i == 23:
            if c != UInt8(ord("-")):
                return False
            continue
        var digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        var lower = c >= UInt8(ord("a")) and c <= UInt8(ord("f"))
        if not (digit or lower):
            return False
    return True


def heartbeat_job_id_for(spec: PlacementSpec) raises -> String:
    """The job id a placed unit's supervisor must stamp on EVERY heartbeat —
    `spec.job_id`, checked to be in the canonical form the job manager's
    heartbeat handler decodes (`is_canonical_job_id`). RAISES, naming the
    placement, otherwise.

    ⛔ IT RAISES RATHER THAN FALLING BACK TO `spec.name`, because `spec.name`
    is the exact value that made every VM beat a 400. Both VM conformers call
    this BEFORE any cloud mutation, so a refusal costs a no-op; the alternative
    is an instance that boots, beats, is refused on every beat, and bills by
    the hour while looking healthy."""
    if spec.job_id.byte_length() == 0:
        raise Error(
            String("heartbeat_job_id_for: REFUSED to render a heartbeat")
            + String(" identity for placement '")
            + spec.name
            + String(
                "' — `PlacementSpec.job_id` is EMPTY. The placed unit's"
                " supervisor stamps this value on every heartbeat and the job"
                " manager decodes it as the job row's UUID, so with nothing to"
                " stamp every beat would be refused. The job manager stamps it"
                " for every placement it makes;"
                " a caller that builds a PlacementSpec by hand must set it to"
                " the job's hyphenated id. ⛔ Do NOT substitute the placement"
                " name: it is `<prefix>-<last 12 hex of the id>`, which the"
                " handler cannot decode and which cannot be inverted."
            )
        )
    if not is_canonical_job_id(spec.job_id):
        raise Error(
            String("heartbeat_job_id_for: REFUSED heartbeat identity '")
            + spec.job_id
            + String("' for placement '")
            + spec.name
            + String(
                "' — it is not a canonical hyphenated lowercase UUID"
                " (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx). The job manager's"
                " heartbeat handler decodes `job_id` as the job row's UUID, so"
                " a value in any other shape is either refused 400 on every beat"
                " or accepted only by the decoder ignoring part of it. Set"
                " `PlacementSpec.job_id` to `job.id.to_hyphenated()`."
            )
        )
    return spec.job_id.copy()
