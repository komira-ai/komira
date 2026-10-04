# =============================================================================
# kci_reconciler/unpinned_plan.mojo: what a plan renders for an image whose
#   build step has not run yet, and the record that lists every one.
# =============================================================================
#
# THE CASE. `kci run --plan` may reach a service or job whose `Image` is a
# step output (`Image.output { step, name }`) of a build step in the same run
# that has not run yet. There is no digest to show. Refusing the whole plan
# would leave nothing to review until the build had run; inventing a digest
# would report a graph nobody can apply.
#
# THE PLACEHOLDER. `UNPINNED-NOT-A-DIGEST:<step>/<name>`. It does not start
# with `sha256:`, it says NOT-A-DIGEST in words, and it names the step output
# it stands in for, so it cannot be copied into an `image { digest }` as if it
# were a pin, and a reader of the rendered plan can tell which image is
# missing. `is_unpinned_plan_digest` is the one predicate a consumer that must
# refuse to act on a placeholder uses, instead of re-spelling the prefix.
#
# THE RECORD IS THE PRICE OF THE PLACEHOLDER. `unpinned_image_digest` has two
# forms. Without an `UnpinnedImages` record it always refuses, naming the node
# and the step output. With one, it records the substitution and returns the
# placeholder. A placeholder that reaches a rendered plan and is recorded
# nowhere is a plan that silently succeeded; the record is what lets the
# caller list every unpinned image by kind, node and step output (never a bare
# count) and decide its exit status from that list.
#
# Only a service and a job carry an image, so those are the only two kinds.
#
# Pure leaf: values in, values out. No I/O, no proto, no pointer.
# Mojo 1.0.0b2 (def-only).
# =============================================================================


comptime UNPINNED_PLAN_DIGEST_PREFIX = "UNPINNED-NOT-A-DIGEST:"
"""The prefix of the placeholder a plan renders in place of a digest no build
has produced yet. Not `sha256:`-shaped, and says so in words."""

comptime UNPINNED_KIND_SERVICE = "service"
"""A service's image."""

comptime UNPINNED_KIND_JOB = "job"
"""A job's image."""


def unpinned_build_ref(step: String, name: String) -> String:
    """The step output an `Image.output { step, name }` names, as one string:
    `<step>/<name>`."""
    return step + "/" + name


def is_unpinned_plan_digest(value: String) -> Bool:
    """True iff `value` is a placeholder this module produced."""
    return value.startswith(UNPINNED_PLAN_DIGEST_PREFIX)


def _has_image(kind: String) -> Bool:
    return kind == UNPINNED_KIND_SERVICE or kind == UNPINNED_KIND_JOB


def _refuse_kind(kind: String, node_id: String) -> Error:
    return Error(
        "unpinned plan: "
        + kind
        + " node '"
        + node_id
        + "' has no image; only a service or a job has one"
    )


@fieldwise_init
struct UnpinnedImage(Copyable, Movable):
    """One substitution: the kind, the node, and the step output it reads."""

    var kind: String
    var node_id: String
    var step: String
    var name: String

    def build_ref(self) -> String:
        return unpinned_build_ref(self.step, self.name)

    def placeholder(self) -> String:
        return UNPINNED_PLAN_DIGEST_PREFIX + self.build_ref()

    def render(self) -> String:
        """One line an operator can act on: which node, which step output."""
        return (
            self.kind
            + " node '"
            + self.node_id
            + "': image is step output '"
            + self.build_ref()
            + "', not built yet (rendered as "
            + self.placeholder()
            + ")"
        )


struct UnpinnedImages(Movable):
    """The caller-owned record of every unpinned image a plan rendered, in the
    order first recorded. Keyed on (kind, node): recording a node again
    overwrites its entry rather than adding one.

    An empty record is the ordinary answer: every image was pinned."""

    var _rows: List[UnpinnedImage]

    def __init__(out self):
        self._rows = List[UnpinnedImage]()

    def _record(
        mut self, kind: String, node_id: String, step: String, name: String
    ) -> String:
        var row = UnpinnedImage(kind.copy(), node_id.copy(), step.copy(), name.copy())
        var placeholder = row.placeholder()
        for i in range(len(self._rows)):
            if self._rows[i].kind == kind and self._rows[i].node_id == node_id:
                self._rows[i] = row^
                return placeholder^
        self._rows.append(row^)
        return placeholder^

    def count(self) -> Int:
        return len(self._rows)

    def build_refs(self) -> List[String]:
        """The step outputs left unpinned, `<step>/<name>`, in record order."""
        var refs = List[String]()
        for i in range(len(self._rows)):
            refs.append(self._rows[i].build_ref())
        return refs^

    def rendered_rows(self) -> List[String]:
        """One line per unpinned image (kind, node, step output), in record
        order."""
        var rows = List[String]()
        for i in range(len(self._rows)):
            rows.append(self._rows[i].render())
        return rows^


def unpinned_image_digest(
    kind: String, node_id: String, step: String, name: String
) raises -> String:
    """No record passed in: an unpinned image is refused, naming the node and
    the step output. There is no way to get a placeholder without a record."""
    if not _has_image(kind):
        raise _refuse_kind(kind, node_id)
    raise Error(
        "unpinned plan: "
        + kind
        + " node '"
        + node_id
        + "' reads step output '"
        + unpinned_build_ref(step, name)
        + "', which has no digest yet; a plan over it needs a record of"
        + " unpinned images from the caller"
    )


def unpinned_image_digest(
    kind: String,
    node_id: String,
    step: String,
    name: String,
    mut images: UnpinnedImages,
) raises -> String:
    """A record passed in: the substitution is recorded in `images` and the
    placeholder `UNPINNED-NOT-A-DIGEST:<step>/<name>` is returned. A kind with
    no image (anything but service or job) is refused and not recorded."""
    if not _has_image(kind):
        raise _refuse_kind(kind, node_id)
    return images._record(kind, node_id, step, name)
