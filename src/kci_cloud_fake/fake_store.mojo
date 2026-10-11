# =============================================================================
# kci_cloud_fake/fake_store.mojo: the memory a fake cloud deploys to.
# =============================================================================
#
# What exists (per engine node: its kind, digest, the URL it serves, whether
# it is in the failed state, the LABELS it carries, its provenance
# annotation, and any out-of-band value on a field kci does not model) and
# every mutating call the cloud served, in order. Shared by a cloud and the
# nodes it lowers through an `ArcPointer`, so a test can read both the state
# and the call log after a run. Nothing here is a network or a clock.
#
# IT BEHAVES LIKE A CLOUD API WHERE KCI MUST NOT ASSUME OTHERWISE:
#   * a create of a name that exists is REFUSED (`ALREADY_EXISTS`), never
#     an overwrite: that is how a second writer of the same name is seen;
#   * an update of a name that does not exist is REFUSED (`NOT_FOUND`);
#   * labels are kept exactly as written and read back exactly; an update
#     rewrites the retention mark (`kci-retention`, the label it is handed)
#     in the same call and leaves every other label as it was;
#   * an object's NAME (the author's cloud name, `names`; empty when the
#     cloud chose it) is written by the create, or by the adoption that takes
#     it over, and by nothing else: an update or a tamper never renames;
#   * a RELEASE drops every kci label of an object (`kci_*`, `kci-*`) and
#     changes nothing else: the object stays, with its kind, state and name.
#
# THE FAULTY VARIANT (constructor arguments, each independent):
#   * `fail_at_call = k` (1-based, 0 = never): the k-th mutating call raises
#     instead of acting, once: nothing changes and nothing is logged for it,
#     as when a cloud API refuses a request. A partial apply and its recovery.
#   * `read_lag = n`: reads are eventually consistent. After a create, the
#     next n reads of that name still see it ABSENT; after a delete, the next
#     n reads still see the old object. Lists (`list_owned`) see the truth.
#   * `foreign = [names]`: objects that exist before kci ever ran, carrying
#     no kci stamp (made by hand, or by another tool). `plant_object` makes
#     one of a given kind, state (digest) and name: what an adoption reads.
#   * `fail_reads_of(id)`: from then on every live read of the node `id`
#     (`read_status`, `read_presence`) raises, as when a cloud API refuses
#     a read. Lists and the adoption read (`read_existing`) are not
#     affected.
#   * `race_next()`: the next create meets an object a second apply of the
#     same cell created a moment earlier (same name, same labels): that
#     create is served for the other writer and logged, and this one is
#     refused as ALREADY_EXISTS.
#   * `fail_after_create_of(id)`: the next create of `id` stores the object
#     as the request carried it (stamp included), logs it, then raises, as
#     when a create lands and its wait times out; `failed_after` names it,
#     and `failed_log` keeps every such id, in order.
#
# MEMBER BINDINGS (a shape whose grants are DERIVED, `roles` non-empty): a
# binding object is stored at its node id like every object, with NO labels:
# what it holds is a member (`b_member`: an identity object's id, or
# `ALL_USERS`) holding a role (`b_role`, resolved through the role table
# `roles` at create and update) on a target (`b_target`: an object's id, or
# `CELL_SCOPE`, the cell's own policy). Every read derives its labels by
# kci_cloud's attribution (`attribute`) from the objects at its two ends, so
# a binding whose member or target is not this cell's reads as unstamped.
# Members planted out of band (`plant_member`) sit on a policy (a target, or
# the cell scope; on a labelled shape the grant object itself), are never
# objects, never counted and never removed by an apply; a read of a grant
# node reports each one not attributed to its cell as an unmanaged
# difference. A foreign member is an identity of another cell (`outside_*`:
# objects outside this cell, never counted).
# `fail(id)` puts a present node into the failed state (a new version that
# never became ready); the next update clears it. `replace_only(id)` is the
# fake's model of a field the cloud cannot change in place: from then on, a
# drifted object at `id` is planned as a replace (nodes.mojo), never an
# update.
# =============================================================================

from kci_reconciler import LABEL_CELL, Label

from kci_cloud import (
    ACCESS_PUBLIC,
    ALL_USERS,
    BindingEnd,
    CELL_PATH_PREFIX,
    DerivedStamp,
    RoleRow,
    attribute,
    encode_label_value,
    is_kci_label_key,
    role_for,
)


comptime CELL_SCOPE = "(cell)"
"""A binding's target when it is on the cell's own policy (a cell edge's;
on GCP the project's)."""
comptime UNMAPPED_ROLE = "roles/owner"
"""The role the fakes plant for the kit's `ROLE_UNMAPPED`: in no table."""
comptime FOREIGN_LABELLED_MEMBER = "outsider@elsewhere"
"""The kit's `MEMBER_FOREIGN` on a labelled grant object."""
comptime CELL_LABELLED_MEMBER = "principal@cell"
"""The kit's `MEMBER_CELL` on a labelled grant object."""
comptime MAPPED_LABELLED_ROLE = "granted"
"""The kit's `ROLE_MAPPED` on a labelled grant object."""
comptime OUTSIDE_PREFIX = "outside/"
"""The id of a foreign member: an identity of another cell."""


struct FakeView(Copyable, Movable, Deinitable):
    """What one read of a name sees."""

    var present: Bool
    var kind: String
    var digest: String
    var url: String
    var failed: Bool
    var labels: List[Label]
    var annotation: String
    var extra: String
    var name: String
    var members: String
    """The planted members of its policy that are not its cell's, as text
    (empty when none)."""

    def __init__(out self):
        self.members = String("")
        self.name = String("")
        self.present = False
        self.kind = String("")
        self.digest = String("")
        self.url = String("")
        self.failed = False
        self.labels = List[Label]()
        self.annotation = String("")
        self.extra = String("")

    def __init__(out self, *, copy: Self):
        self.present = copy.present
        self.kind = copy.kind.copy()
        self.digest = copy.digest.copy()
        self.url = copy.url.copy()
        self.failed = copy.failed
        self.labels = copy.labels.copy()
        self.annotation = copy.annotation.copy()
        self.extra = copy.extra.copy()
        self.name = copy.name.copy()
        self.members = copy.members.copy()


struct FakeStore(Movable):
    var ids: List[String]
    var kinds: List[String]
    var digests: List[String]
    var urls: List[String]
    var failed: List[Bool]
    var labels: List[List[Label]]
    var annotations: List[String]
    var extras: List[String]
    var names: List[String]
    var created: List[Int]
    var calls: List[String]
    var fail_at_call: Int
    var read_lag: Int
    var raced_id: String
    var _race_next: Bool
    var _attempts: Int
    var _seq: Int
    var _hidden: List[String]
    var _hidden_left: List[Int]
    var _ghosts: List[String]
    var _ghost_views: List[FakeView]
    var _ghost_left: List[Int]
    var replaces: List[String]
    var read_faults: List[String]
    var b_target: List[String]
    var b_member: List[String]
    var b_role: List[String]
    var roles: List[RoleRow]
    var planted_key: List[String]
    var planted_member: List[String]
    var planted_role: List[String]
    var outside_ids: List[String]
    var outside_labels: List[List[Label]]
    var _fail_after: String
    var failed_after: String
    var failed_log: List[String]

    def __init__(
        out self,
        fail_at_call: Int = 0,
        read_lag: Int = 0,
        foreign: List[String] = List[String](),
    ):
        self.ids = List[String]()
        self.kinds = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.failed = List[Bool]()
        self.labels = List[List[Label]]()
        self.annotations = List[String]()
        self.extras = List[String]()
        self.names = List[String]()
        self.created = List[Int]()
        self.calls = List[String]()
        self.fail_at_call = fail_at_call
        self.read_lag = read_lag
        self.raced_id = String("")
        self._race_next = False
        self._attempts = 0
        self._seq = 0
        self._hidden = List[String]()
        self._hidden_left = List[Int]()
        self._ghosts = List[String]()
        self._ghost_views = List[FakeView]()
        self._ghost_left = List[Int]()
        self.replaces = List[String]()
        self.read_faults = List[String]()
        self.b_target = List[String]()
        self.b_member = List[String]()
        self.b_role = List[String]()
        self.roles = List[RoleRow]()
        self.planted_key = List[String]()
        self.planted_member = List[String]()
        self.planted_role = List[String]()
        self.outside_ids = List[String]()
        self.outside_labels = List[List[Label]]()
        self._fail_after = String("")
        self.failed_after = String("")
        self.failed_log = List[String]()
        for i in range(len(foreign)):
            self.plant(foreign[i], String("foreign"))

    def find(self, id: String) -> Int:
        """The TRUE state (tests and lists); reads go through `read`."""
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def _view(self, i: Int) -> FakeView:
        var v = FakeView()
        v.present = True
        v.kind = self.kinds[i].copy()
        v.digest = self.digests[i].copy()
        v.url = self.urls[i].copy()
        v.failed = self.failed[i]
        v.labels = self.labels_of(i)
        v.members = self.members_report(i)
        v.annotation = self.annotations[i].copy()
        v.extra = self.extras[i].copy()
        v.name = self.names[i].copy()
        return v^

    def read(mut self, id: String) -> FakeView:
        """One read, eventually consistent under `read_lag`."""
        for h in range(len(self._hidden)):
            if self._hidden[h] == id and self._hidden_left[h] > 0:
                self._hidden_left[h] -= 1
                return FakeView()
        var i = self.find(id)
        if i >= 0:
            return self._view(i)
        for g in range(len(self._ghosts)):
            if self._ghosts[g] == id and self._ghost_left[g] > 0:
                self._ghost_left[g] -= 1
                return self._ghost_views[g].copy()
        return FakeView()

    def _admit(mut self, verb: String, id: String) raises:
        """Count one mutating call; raise, without acting, if it is the one
        the faulty variant refuses."""
        self._attempts += 1
        if self.fail_at_call > 0 and self._attempts == self.fail_at_call:
            raise Error(
                String("fake: injected fault on call ")
                + String(self._attempts)
                + String(" (")
                + verb
                + String(" ")
                + id
                + String(")")
            )

    def _insert(
        mut self,
        id: String,
        kind: String,
        digest: String,
        url: String,
        labels: List[Label],
        annotation: String,
        name: String = String(""),
        target: String = String(""),
        member: String = String(""),
        role: String = String(""),
    ):
        self._seq += 1
        self.b_target.append(target)
        self.b_member.append(member)
        self.b_role.append(role)
        self.ids.append(id)
        self.kinds.append(kind)
        self.digests.append(digest)
        self.urls.append(url)
        self.failed.append(False)
        self.labels.append(labels.copy())
        self.annotations.append(annotation)
        self.extras.append(String(""))
        self.names.append(name)
        self.created.append(self._seq)
        for g in range(len(self._ghosts)):
            if self._ghosts[g] == id:
                self._ghost_left[g] = 0
        if self.read_lag > 0:
            self._hidden.append(id)
            self._hidden_left.append(self.read_lag)

    def plant(mut self, id: String, kind: String):
        """An object made outside kci: no stamp, a digest kci never writes."""
        self.plant_object(id, kind, String("made-outside-kci"), String(""))

    def plant_object(mut self, id: String, kind: String, digest: String, name: String):
        """An object made outside kci, of `kind`, in the state `digest`
        renders, under the cloud name `name`: no stamp. Not a served call."""
        self._seq += 1
        self.b_target.append(String(""))
        self.b_member.append(String(""))
        self.b_role.append(String(""))
        self.ids.append(id)
        self.kinds.append(kind)
        self.digests.append(digest)
        self.urls.append(String(""))
        self.failed.append(False)
        self.labels.append(List[Label]())
        self.annotations.append(String(""))
        self.extras.append(String(""))
        self.names.append(name)
        self.created.append(self._seq)

    def replace_only(mut self, id: String):
        """A drifted object at `id` can only be replaced (the file header)."""
        self.replaces.append(id)

    def replaced_only(self, id: String) -> Bool:
        for i in range(len(self.replaces)):
            if self.replaces[i] == id:
                return True
        return False

    def fail_reads_of(mut self, id: String):
        """Every live read of the node `id` raises from now on (the file
        header)."""
        self.read_faults.append(id)

    def read_fault(self, id: String) raises:
        """Raise if a live read of `id` is refused (`fail_reads_of`)."""
        for i in range(len(self.read_faults)):
            if self.read_faults[i] == id:
                raise Error(String("fake: injected read fault (") + id + String(")"))

    def race_next(mut self):
        self._race_next = True

    def create(
        mut self,
        id: String,
        kind: String,
        digest: String,
        url: String,
        labels: List[Label],
        annotation: String,
        name: String = String(""),
        target: String = String(""),
        member: String = String(""),
        role: String = String(""),
    ) raises:
        self._admit(String("create"), id)
        if self._race_next:
            # The second apply's create of the same name lands first.
            self._race_next = False
            self.raced_id = id
            if self.find(id) < 0:
                self._insert(id, kind, digest, url, labels, annotation, name, target, member, role)
                self.calls.append(String("create ") + id)
        if self.find(id) >= 0:
            raise Error(String("fake: ALREADY_EXISTS: ") + id)
        self._insert(id, kind, digest, url, labels, annotation, name, target, member, role)
        self.calls.append(String("create ") + id)
        if self._fail_after.byte_length() > 0 and self._fail_after == id:
            # The object landed as the request carried it; the caller hears
            # an error (its wait timed out).
            self._fail_after = String("")
            self.failed_after = id
            self.failed_log.append(id)
            raise Error(String("fake: DEADLINE_EXCEEDED waiting for the create of ") + id + String(", which landed"))

    def fail_after_create_of(mut self, id: String):
        """Arm the next create of `id` to land and then raise (the file
        header)."""
        self._fail_after = id
        self.failed_after = String("")

    def update(
        mut self, id: String, digest: String, url: String, retention: Label, role: String = String("")
    ) raises:
        """Rewrite the state and the retention mark; on a binding (which
        carries no labels), the role it holds instead (`role`)."""
        self._admit(String("update"), id)
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: NOT_FOUND: ") + id)
        self.calls.append(String("update ") + id)
        self.digests[i] = digest
        self.urls[i] = url
        self.failed[i] = False
        if self.is_binding(i):
            if role.byte_length() > 0:
                self.b_role[i] = role
            return
        var kept = List[Label]()
        for k in range(len(self.labels[i])):
            if self.labels[i][k].key != retention.key:
                kept.append(self.labels[i][k].copy())
        kept.append(retention.copy())
        self.labels[i] = kept^

    def relabel(
        mut self, id: String, labels: List[Label], annotation: String, name: String = String(""),
        kind: String = String(""),
    ) raises:
        """Stamp an object (an adoption): its labels, its annotation, and
        the name the adopting node knows it by; an object planted with the
        placeholder kind `foreign` takes the adopting node's kind (the object
        of a wanted name is of that node's kind; a binding's role is read
        from its target's kind)."""
        self._admit(String("relabel"), id)
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: NOT_FOUND: ") + id)
        self.calls.append(String("relabel ") + id)
        if not self.is_binding(i):
            # A binding carries no labels: its stamp is derived.
            self.labels[i] = labels.copy()
        self.annotations[i] = annotation
        self.names[i] = name
        if kind.byte_length() > 0 and self.kinds[i] == "foreign":
            self.kinds[i] = kind

    def release(mut self, id: String) raises:
        """Drop every kci label of `id` and nothing else (the object, its
        state and its name stay). A served call."""
        self._admit(String("release"), id)
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: NOT_FOUND: ") + id)
        self.calls.append(String("release ") + id)
        var kept = List[Label]()
        for k in range(len(self.labels[i])):
            if not is_kci_label_key(self.labels[i][k].key):
                kept.append(self.labels[i][k].copy())
        self.labels[i] = kept^

    def remove(mut self, id: String) raises:
        """Idempotent: removing what is not there is a no-op, but still a
        served call."""
        self._admit(String("delete"), id)
        self.calls.append(String("delete ") + id)
        var i = self.find(id)
        if i < 0:
            return
        # The object's policy goes with it.
        var k = 0
        while k < len(self.planted_key):
            if self.planted_key[k] == id:
                _ = self.planted_key.pop(k)
                _ = self.planted_member.pop(k)
                _ = self.planted_role.pop(k)
            else:
                k += 1
        if self.read_lag > 0:
            self._ghosts.append(id)
            self._ghost_views.append(self._view(i))
            self._ghost_left.append(self.read_lag)
        for h in range(len(self._hidden)):
            if self._hidden[h] == id:
                self._hidden_left[h] = 0
        _ = self.ids.pop(i)
        _ = self.kinds.pop(i)
        _ = self.digests.pop(i)
        _ = self.urls.pop(i)
        _ = self.failed.pop(i)
        _ = self.labels.pop(i)
        _ = self.annotations.pop(i)
        _ = self.extras.pop(i)
        _ = self.names.pop(i)
        _ = self.created.pop(i)
        _ = self.b_target.pop(i)
        _ = self.b_member.pop(i)
        _ = self.b_role.pop(i)

    def tamper(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot tamper with absent node ") + id)
        self.digests[i] = String("changed-out-of-band")

    def tamper_unmodelled(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot tamper with absent node ") + id)
        self.extras[i] = String("team=payments")

    def fail(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot fail absent node ") + id)
        self.failed[i] = True

    def creates_of(self, id: String) -> Int:
        var n = 0
        var want = String("create ") + id
        for i in range(len(self.calls)):
            if self.calls[i] == want:
                n += 1
        return n

    # ---- member bindings (the file header) ----

    def is_binding(self, i: Int) -> Bool:
        """The object at index `i` is a member binding."""
        return self.b_member[i].byte_length() > 0

    def binding_role(self, target: String, member: String, access: String, cell: String) raises -> String:
        """The role a binding of `member` on `target` with `access` (or on
        the cell resource `cell`) holds, from the role table; raises when
        the table has none (validate refuses what the shape cannot bind)."""
        var on = String("")
        var verb = access.copy()
        if member == ALL_USERS:
            verb = String(ACCESS_PUBLIC)
        if target == CELL_SCOPE:
            on = String(CELL_PATH_PREFIX) + cell
        else:
            var t = self.find(target)
            if t >= 0:
                on = self.kinds[t].copy()
        var role = role_for(self.roles, on, verb)
        if not role:
            raise Error(String("fake: no role for ") + verb + String(" on ") + on + String(" (") + target + String(")"))
        return role.value().copy()

    def _end(self, id: String) -> BindingEnd:
        """What the cloud holds at `id` (an object of this cell, an outside
        identity, or nothing)."""
        var i = self.find(id)
        if i >= 0:
            if self.is_binding(i):
                return BindingEnd(self.kinds[i].copy())
            return BindingEnd(self.kinds[i].copy(), self.labels[i].copy())
        for k in range(len(self.outside_ids)):
            if self.outside_ids[k] == id:
                return BindingEnd(String(""), self.outside_labels[k].copy())
        return BindingEnd()

    def _attribute(self, target: String, member: String, role: String) -> Optional[DerivedStamp]:
        """kci_cloud's attribution of one binding over this store; None for
        none (and for a label rule that raises)."""
        try:
            return attribute(target == CELL_SCOPE, self._end(target), member == ALL_USERS, self._end(member), role, self.roles)
        except:
            return None

    def labels_of(self, i: Int) -> List[Label]:
        """The labels object `i` reads as: as written, or, for a binding,
        what attribution derives (none when it is not attributed)."""
        if not self.is_binding(i):
            return self.labels[i].copy()
        var d = self._attribute(self.b_target[i], self.b_member[i], self.b_role[i])
        if not d:
            return List[Label]()
        return d.value().labels.copy()

    def _policy_of(self, i: Int) -> String:
        """The policy a member planted on object `i`'s grant lands on: its
        target's (or the cell scope's) for a binding, else the object."""
        if self.is_binding(i):
            return self.b_target[i].copy()
        return self.ids[i].copy()

    def members_report(self, i: Int) -> String:
        """Every planted member on object `i`'s policy that is not its
        cell's, as text; empty when none."""
        var key = self._policy_of(i)
        var mine: Optional[DerivedStamp] = None
        if self.is_binding(i):
            mine = self._attribute(self.b_target[i], self.b_member[i], self.b_role[i])
        var out = String("")
        for k in range(len(self.planted_key)):
            if self.planted_key[k] != key:
                continue
            if mine:
                var d = self._attribute(key, self.planted_member[k], self.planted_role[k])
                if d and d.value().machine == mine.value().machine and d.value().cell == mine.value().cell:
                    continue
            if out.byte_length() > 0:
                out += String(", ")
            out += self.planted_member[k] + String(" holding ") + self.planted_role[k]
        return out^

    def _member_value(self, i: Int, member: String) -> String:
        """The kit's member word as this store's value, for the grant object
        at index `i`: on a binding, the node's own principal, or an identity
        of ANOTHER cell (`OUTSIDE_PREFIX` + the principal: its stamp, in a
        cell whose name differs; `plant_member` makes it)."""
        if not self.is_binding(i):
            if member == "FOREIGN":
                return String(FOREIGN_LABELLED_MEMBER)
            return String(CELL_LABELLED_MEMBER)
        if member != "FOREIGN":
            return self.b_member[i].copy()
        return String(OUTSIDE_PREFIX) + self.b_member[i]

    def _make_outsider(mut self, i: Int) raises:
        """The foreign identity `_member_value` names for object `i`: a copy
        of its principal's stamp in another cell, outside this one."""
        var id = String(OUTSIDE_PREFIX) + self.b_member[i]
        for k in range(len(self.outside_ids)):
            if self.outside_ids[k] == id:
                return
        var src = self.find(self.b_member[i])
        if src < 0:
            raise Error(String("fake: the principal of ") + self.ids[i] + String(" is not live"))
        var labels = self.labels[src].copy()
        for k in range(len(labels)):
            if labels[k].key == LABEL_CELL:
                labels[k].value = encode_label_value(labels[k].value + String("-elsewhere"))
        self.outside_ids.append(id)
        self.outside_labels.append(labels^)

    def _role_value(self, i: Int, role: String) -> String:
        if role == "UNMAPPED":
            return String(UNMAPPED_ROLE)
        if self.is_binding(i):
            return self.b_role[i].copy()
        return String(MAPPED_LABELLED_ROLE)

    def plant_member(mut self, node: String, member: String, role: String) raises:
        """Add, out of band, the kit's `member` holding `role` to the policy
        of the grant at `node` (the file header). Not a served call."""
        var i = self.find(node)
        if i < 0:
            raise Error(String("fake: cannot plant a member on absent node ") + node)
        if self.is_binding(i) and member == "FOREIGN":
            self._make_outsider(i)
        var m = self._member_value(i, member)
        self.planted_key.append(self._policy_of(i))
        self.planted_member.append(m^)
        self.planted_role.append(self._role_value(i, role))

    def member_present(self, node: String, member: String, role: String) -> Bool:
        """Whether the kit's `member` holds `role` on the policy of the grant
        at `node` now."""
        var i = self.find(node)
        if i < 0:
            return False
        var m = self._member_value(i, member)
        var r = self._role_value(i, role)
        if self.is_binding(i) and self.b_member[i] == m and self.b_role[i] == r:
            return True
        var key = self._policy_of(i)
        for k in range(len(self.planted_key)):
            if self.planted_key[k] == key and self.planted_member[k] == m and self.planted_role[k] == r:
                return True
        return False
