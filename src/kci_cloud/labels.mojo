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
#   * keys are the six `kci_*` names, unchanged (`[a-z_]`, legal everywhere);
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
# plus a separator each. `role_budget_findings` (validate.mojo) checks every
# lowered node against `LABEL_VALUE_MAX` before anything is realized, so a
# role over the budget refuses the graph instead of failing at create time.
#
# RETENTION IS ONE MORE LABEL, OUTSIDE THE IDENTITY. An object of a node whose
# retention is KEEP is created with `kci_retain=keep` (`retain_labels`), and
# keeps it while the node is KEEP. It is not part of the stamp: the six
# identity labels decide whose an object is, this one decides whether kci
# may delete it once the file stops lowering it. `list_owned` reads it back
# (`retained_by`), so a kept object stays kept even when nothing in the file
# says so any more.
#
# A cloud object that cannot carry labels (a scheduler job, an IAM binding)
# carries the identity as the first line of its description instead
# (`OwnerStamp.identity()`); that is the adapter's own business.
# =============================================================================

from kci_reconciler import Label, OwnerStamp, RETAIN_KEEP

comptime LABEL_VALUE_MAX = 63
"""The longest label value the standard rule writes."""


def _legal_value_byte(c: Int) -> Bool:
    return (
        (c >= ord("a") and c <= ord("z"))
        or (c >= ord("0") and c <= ord("9"))
        or c == ord("_")
        or c == ord("-")
    )


comptime LABEL_RETAIN = "kci_retain"
"""The retention label's key: not part of the ownership identity."""
comptime RETAIN_KEEP_VALUE = "keep"
"""The retention label's one value."""


def retain_labels(retention: Int) -> List[Label]:
    """The retention label of a node with engine retention `retention`:
    `kci_retain=keep` for RETAIN_KEEP, nothing otherwise."""
    var out = List[Label]()
    if retention == RETAIN_KEEP:
        out.append(Label(String(LABEL_RETAIN), String(RETAIN_KEEP_VALUE)))
    return out^


def retained_by(labels: List[Label]) -> Bool:
    """True iff `labels` carry `kci_retain=keep`."""
    for i in range(len(labels)):
        if labels[i].key == LABEL_RETAIN and labels[i].value == RETAIN_KEEP_VALUE:
            return True
    return False


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


def standard_identity_of(labels: List[Label]) -> String:
    """The identity encoded labels carry (decoded), or empty."""
    var raw = List[Label]()
    for i in range(len(labels)):
        raw.append(Label(labels[i].key.copy(), decode_label_value(labels[i].value)))
    return OwnerStamp.identity_of_labels(raw)


def label_problems(labels: List[Label]) -> List[String]:
    """Every label of `labels` the standard rule would not have written."""
    var out = List[String]()
    for i in range(len(labels)):
        ref l = labels[i]
        var kb = l.key.as_bytes()
        if len(kb) == 0 or len(kb) > LABEL_VALUE_MAX:
            out.append(String("label key \"") + l.key + String("\" has a bad length"))
        for k in range(len(kb)):
            var c = Int(kb[k])
            if not ((c >= ord("a") and c <= ord("z")) or c == ord("_")):
                out.append(String("label key \"") + l.key + String("\" is not [a-z_]"))
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
