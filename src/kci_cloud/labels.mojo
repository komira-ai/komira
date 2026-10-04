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
#   * the one character a value must carry and may not is `/` (a role such as
#     `uses/jobs`). It is written `--`, which no machine, cell or resource id
#     can contain (the id grammar forbids a doubled `-`), so decoding is
#     exact;
#   * anything else outside the rule is REFUSED, never rewritten: a lossy
#     rewrite would make two different owners read as one.
#
# A cloud object that cannot carry labels (a scheduler job, an IAM binding)
# carries the identity as the first line of its description instead
# (`OwnerStamp.identity()`); that is the adapter's own business.
# =============================================================================

from kci_reconciler import Label, OwnerStamp

comptime LABEL_VALUE_MAX = 63
"""The longest label value the standard rule writes."""


def _legal_value_byte(c: Int) -> Bool:
    return (
        (c >= ord("a") and c <= ord("z"))
        or (c >= ord("0") and c <= ord("9"))
        or c == ord("_")
        or c == ord("-")
    )


def encode_label_value(v: String) raises -> String:
    """`/` -> `--`, then the value must be `[a-z0-9_-]{0,63}`, else raise."""
    var out = v.replace("/", "--")
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
    return v.replace("--", "/")


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
