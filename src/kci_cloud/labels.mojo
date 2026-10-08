# =============================================================================
# kci_cloud/labels.mojo: the standard label rule.
# =============================================================================
#
# The engine hands a cloud an `OwnerStamp` (machine, cell, resource, role,
# scheme) and asks for the labels to create the object with
# (`CloudAdapter.label_rule`), and later for the identity a live object's
# labels carry (`CloudAdapter.identity_of`). This is the rule every cloud
# built into kci uses unless it has a reason not to:
#
#   * keys are the six `kci_*` names, unchanged (`[a-z_]`, legal everywhere),
#     and the two marks komira_validation_run defines, verbatim
#     (`kci-run-id`, `kci-retention`; the only keys holding `-`);
#   * a value is `[a-z0-9_-]`, at most 63 bytes (the strictest common rule:
#     GCP label values; AWS tag values accept a superset);
#   * the one character a value must carry and may not is `/`: a role is the
#     rest of a node id after its owner, so it holds one `/` per level of
#     nesting (`api/run`, `web/api/u-mz4k2q`). It is written `_`, ONE byte, so
#     the 63-byte budget pays one byte per level. Decoding (`_` -> `/`) is
#     exact because no segment may hold `_`: resource ids and component ids
#     are `[a-z0-9-]`, and the role vocabulary uses `-` only. A value that
#     does hold `_` is REFUSED, since it would decode as a `/`;
#   * `--` was once written for `/`. That form was never deployed (no adapter
#     outside the offline fakes has ever stamped an object), so there is no
#     migration and no compatibility: a value holding `--` is an ordinary
#     value, never split into segments, so it can never read as an owner or a
#     role of a node it resembles;
#   * anything else outside the rule is REFUSED, never rewritten: a lossy
#     rewrite would make two different owners read as one.
#
# ⛔ AN EARLIER RULE WROTE `/` AS `--`, AND IT IS NOT DECODE-COMPATIBLE WITH
# THIS ONE: a `--` stamp decodes as a role no resource lowers, so the closed
# world would delete its object. No real adapter may ship while such stamps
# can exist without a relabel step (the precondition in adapter.mojo).
#
# THE BUDGET. The `role` label is the longest value: one segment per level
# plus a separator each. Validate checks every lowered node against
# `LABEL_VALUE_MAX` (`lowered_budget_findings`, validate.mojo), so a role
# over the budget is reported by `validate` and refuses a plan, an apply or
# a destroy before anything is created, instead of failing at create time.
#
# RETENTION IS ONE MORE LABEL, OUTSIDE THE IDENTITY, ON EVERY OBJECT. Every
# object kci creates or adopts carries komira_validation_run's retention mark
# `kci-retention=<retain|delete>` (`retain_labels`): the key is
# `resource_retention_tag_key` for the prefix `kci`, the value
# `retention_tag_value` of the node's retention (KEEP is `retain`, DELETE is
# `delete`; any other engine code raises, there is no default arm). An update
# rewrites it to the node's current retention in the same call. It is not part
# of the stamp: the six identity labels decide whose an object is, this one
# decides whether kci may delete it once the file stops lowering it.
# `list_owned` reads it back (`retained_by`: true only for `retain`; a value
# that is neither is not proven retained), so a kept object stays kept even
# when nothing in the file says so any more. It is the SAME mark a leak
# checker reads beside the run-id: kci has no second spelling of retention,
# so a KEEP object created under a validation run is a retained orphan to
# that checker, never a leak.
#
# THE VALIDATION RUN IS ONE MORE LABEL, OUTSIDE THE IDENTITY, WRITTEN ONLY AT
# CREATE. An object created in a scope with a validation run id
# (`CellScope.validation_run_id`) carries `kci-run-id=<id>`: the key is
# komira_validation_run's `validation_run_tag_key` for the prefix `kci`
# (`VALIDATION_RUN_TAG_PREFIX`), and the value is the id VERBATIM (it is not a
# node id, so the `/` -> `_` encoding does not apply; komira_validation_run's
# rule already makes it a legal value on every cloud). `create_labels` is the
# one place a create's labels are built: identity, then the validation run,
# then the retention mark. An adapter's node writes them by calling
# `create_labels` from its `create_owned`; the conformance kit runs its own
# pass under a validation run id it picks, so an adapter that does not is
# refused there. An adoption writes the identity and retention only
# (`standard_label_rule`, `retain_labels`): the run did not create an adopted
# object and must not be able to claim it. An object created outside a
# validation run carries no run-id label at all, never an empty or default
# value: a default id would let a cleanup delete what some other run owns.
# `validation_run_of` reads the label back for `list_owned`. No kci verb sets
# the scope's validation run id yet (kci_cli and kci_api have no flag for
# it), so today only callers that build a `CellScope` themselves stamp it.
#
# AN ADOPTION IS ONE MORE LABEL, OUTSIDE THE IDENTITY, WRITTEN ONLY BY THE
# ADOPTION. An object kci takes over for a resource that writes `adopt`
# (`LoweredNode.adopted`) carries `kci_adopted=true` (`adoption_labels`)
# beside its identity and retention mark: kci did not create it, and the
# mark is how that is still known once nothing in the file says so (the
# resource left the list). An update never writes or drops it.
# `adopted_by` reads it back for `list_owned`. An adopted object carries no
# run-id label, so it holds at most the six identity labels, the retention
# mark and this one: `KCI_LABELS_MAX` (metadata.mojo) still bounds it. A
# RELEASE drops every label `is_kci_label_key` names (`kci_*`, `kci-*`) and
# no other.
#
# A cloud object that cannot carry labels (a scheduler job, an IAM binding)
# carries the identity as the first line of its description instead
# (`OwnerStamp.identity()`); that is the adapter's own business.
# =============================================================================

from kci_reconciler import Label, OwnerStamp, RETAIN_DELETE, RETAIN_KEEP
from komira_validation_run.validation_run_tag import (
    RETENTION_TAG_VALUE_RETAIN,
    VALIDATION_RUN_ID_MAX_LEN,
    is_valid_validation_run_id,
    resource_retention_tag_key,
    retention_tag_value,
    validation_run_tag_key,
)

from kci_cloud.catalog import RETENTION_DELETE, RETENTION_KEEP

comptime LABEL_VALUE_MAX = 63
"""The longest label value the standard rule writes."""


def _legal_value_byte(c: Int) -> Bool:
    return (
        (c >= ord("a") and c <= ord("z"))
        or (c >= ord("0") and c <= ord("9"))
        or c == ord("_")
        or c == ord("-")
    )


def retention_label_key() raises -> String:
    """The retention mark's key kci writes: `kci-retention`
    (komira_validation_run's `resource_retention_tag_key` for
    `VALIDATION_RUN_TAG_PREFIX`)."""
    return resource_retention_tag_key(String(VALIDATION_RUN_TAG_PREFIX))


def retention_label_value(retention: Int) raises -> String:
    """The retention mark's value for engine retention `retention`:
    komira_validation_run's `retention_tag_value` of the catalog ordinal
    (RETAIN_KEEP is KEEP, `retain`; RETAIN_DELETE is DELETE, `delete`). Any
    other code raises: there is no default arm, for the reason
    `retention_tag_value` gives."""
    if retention == RETAIN_KEEP:
        return retention_tag_value(RETENTION_KEEP)
    if retention == RETAIN_DELETE:
        return retention_tag_value(RETENTION_DELETE)
    raise Error(
        String("retention_label_value: engine retention ")
        + String(retention)
        + String(" has no retention mark; state which side it is on")
    )


def retain_labels(retention: Int) raises -> List[Label]:
    """The retention mark of a node with engine retention `retention`:
    `kci-retention=retain` for RETAIN_KEEP, `kci-retention=delete` for
    RETAIN_DELETE. Every object kci creates or adopts carries it."""
    var out = List[Label]()
    out.append(Label(retention_label_key(), retention_label_value(retention)))
    return out^


def retained_by(labels: List[Label]) raises -> Bool:
    """True iff `labels` carry `kci-retention=retain`. A missing mark, or a
    value that is neither `retain` nor `delete`, is not proven retained."""
    var key = retention_label_key()
    for i in range(len(labels)):
        if labels[i].key == key and labels[i].value == RETENTION_TAG_VALUE_RETAIN:
            return True
    return False


comptime VALIDATION_RUN_TAG_PREFIX = "kci"
"""The prefix kci passes to komira_validation_run's `validation_run_tag_key`:
the run-id label key is `kci-run-id`. A reader of the mark must build its key
from the same prefix."""


def validation_run_label_key() raises -> String:
    """The run-id label key kci writes: `kci-run-id`."""
    return validation_run_tag_key(String(VALIDATION_RUN_TAG_PREFIX))


def validation_run_problem(id: Optional[String]) -> String:
    """Why `id` cannot be stamped as a validation run id, or empty when it
    can. None (no validation run) is never a problem; an id present must
    pass komira_validation_run's `is_valid_validation_run_id` (1 to 63 bytes
    of `[a-z0-9_-]`; empty is refused)."""
    if not id:
        return String("")
    if is_valid_validation_run_id(id.value()):
        return String("")
    return (
        String("validation run id \"")
        + id.value()
        + String("\" is not 1 to ")
        + String(VALIDATION_RUN_ID_MAX_LEN)
        + String(" bytes of [a-z0-9_-]; it would not be the same id on every cloud")
    )


def validation_run_labels(stamp: OwnerStamp) raises -> List[Label]:
    """The run-id label of an object created under `stamp`: `kci-run-id=<id>`
    when the stamp has a validation run, nothing otherwise. An id outside
    komira_validation_run's rule raises: it is never rewritten or dropped."""
    var out = List[Label]()
    if not stamp.validation_run_id:
        return out^
    var why = validation_run_problem(stamp.validation_run_id)
    if why.byte_length() > 0:
        raise Error(why)
    out.append(Label(validation_run_label_key(), stamp.validation_run_id.value().copy()))
    return out^


def validation_run_of(labels: List[Label]) raises -> Optional[String]:
    """The run-id label's value as the object stores it, or None when the
    object carries none."""
    var key = validation_run_label_key()
    for i in range(len(labels)):
        if labels[i].key == key:
            return labels[i].value.copy()
    return None


comptime SEGMENT_SEPARATOR = "_"
"""How a label value writes the node-id separator `/`."""


def encoded_label_bytes(v: String) -> Int:
    """The byte length of `v` once encoded (`/` is one byte either way)."""
    return v.byte_length()


def encode_label_value(v: String) raises -> String:
    """`/` -> `_`; a raw `_` is refused (it would decode as `/`); then the
    value must be `[a-z0-9_-]{0,63}`, else raise."""
    if v.find(SEGMENT_SEPARATOR) >= 0:
        raise Error(
            String("label value \"")
            + v
            + String("\" holds '_', which the rule writes for '/'; a segment may not hold it")
        )
    var out = v.replace("/", SEGMENT_SEPARATOR)
    var b = out.as_bytes()
    if len(b) > LABEL_VALUE_MAX:
        raise Error(
            String("label value \"")
            + v
            + String("\" is ")
            + String(len(b))
            + String(" bytes encoded; at most ")
            + String(LABEL_VALUE_MAX)
        )
    for i in range(len(b)):
        if not _legal_value_byte(Int(b[i])):
            raise Error(
                String("label value \"")
                + v
                + String("\" holds a character outside [a-z0-9_-/]")
            )
    return out^


def decode_label_value(v: String) -> String:
    return v.replace(SEGMENT_SEPARATOR, "/")


def standard_label_rule(stamp: OwnerStamp) raises -> List[Label]:
    """The stamp's six identity labels, values encoded."""
    var raw = stamp.labels()
    var out = List[Label]()
    for i in range(len(raw)):
        out.append(Label(raw[i].key.copy(), encode_label_value(raw[i].value)))
    return out^


def create_labels(stamp: OwnerStamp, retention: Int) raises -> List[Label]:
    """Every label a create writes: the stamp's identity
    (`standard_label_rule`), its validation run (`validation_run_labels`), and
    the retention mark of `retention` (`retain_labels`)."""
    var out = standard_label_rule(stamp)
    out.extend(validation_run_labels(stamp))
    out.extend(retain_labels(retention))
    return out^


def standard_identity_of(labels: List[Label]) -> String:
    """The identity encoded labels carry (decoded), or empty."""
    var raw = List[Label]()
    for i in range(len(labels)):
        raw.append(Label(labels[i].key.copy(), decode_label_value(labels[i].value)))
    return OwnerStamp.identity_of_labels(raw)


def label_problems(labels: List[Label]) raises -> List[String]:
    """Every label of `labels` the standard rule would not have written. A
    key is `[a-z_]`, 1 to 63 bytes (the identity keys), or exactly one of the
    two marks (`kci-run-id`, `kci-retention`): `-` is legal in no other key."""
    var run_key = validation_run_label_key()
    var retention_key = retention_label_key()
    var out = List[String]()
    for i in range(len(labels)):
        ref l = labels[i]
        var mark = l.key == run_key or l.key == retention_key
        var kb = l.key.as_bytes()
        if len(kb) == 0 or len(kb) > LABEL_VALUE_MAX:
            out.append(String("label key \"") + l.key + String("\" has a bad length"))
        for k in range(len(kb)):
            var c = Int(kb[k])
            if mark:
                break
            if not ((c >= ord("a") and c <= ord("z")) or c == ord("_")):
                out.append(
                    String("label key \"")
                    + l.key
                    + String("\" is not [a-z_] and not one of the two marks")
                )
                break
        var vb = l.value.as_bytes()
        if len(vb) > LABEL_VALUE_MAX:
            out.append(String("label \"") + l.key + String("\" value is too long"))
        for k in range(len(vb)):
            if not _legal_value_byte(Int(vb[k])):
                out.append(
                    String("label \"") + l.key + String("\" value is not [a-z0-9_-]")
                )
                break
    return out^


comptime ADOPTED_LABEL_KEY = "kci_adopted"
"""The adoption mark's key: `[a-z_]`, so the standard rule takes it as it
takes the identity keys; it is not one of them."""
comptime ADOPTED_LABEL_VALUE = "true"
"""The adoption mark's one value."""


def adoption_labels(adopted: Bool) -> List[Label]:
    """The adoption mark of an object kci takes over for a resource that
    writes `adopt` (`kci_adopted=true`), or nothing when `adopted` is
    False."""
    var out = List[Label]()
    if adopted:
        out.append(Label(String(ADOPTED_LABEL_KEY), String(ADOPTED_LABEL_VALUE)))
    return out^


def adopted_by(labels: List[Label]) -> Bool:
    """True iff `labels` carry `kci_adopted=true`. Any other value is not
    proven adopted."""
    for i in range(len(labels)):
        if labels[i].key == ADOPTED_LABEL_KEY and labels[i].value == ADOPTED_LABEL_VALUE:
            return True
    return False


def is_kci_label_key(key: String) -> Bool:
    """True iff `key` is in kci's own label space (`kci_*`, `kci-*`): the
    identity, the marks. A release drops exactly these."""
    return key.startswith("kci_") or key.startswith("kci-")
