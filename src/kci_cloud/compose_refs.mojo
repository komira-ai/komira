# =============================================================================
# kci_cloud/compose_refs.mojo: every reference of a resource, as a list; the
#   id grammars of a resource and a component, the names of a composite; and
#   the owner of a path.
# =============================================================================
#
# Expansion (compose.mojo) rewrites every `Ref` and every `Value` a resource
# holds. This module is the ONE walk over them: `ref_sites` reads them in a
# fixed order, each with the path an author would write (`uses[0].target`,
# `service.env.HOST`, `dns_record.values[1]`, `composite.input.zone`), and
# `with_sites` writes a list of the same length back, in the same order,
# where each site is kept, replaced or dropped. Both are `_walk`, so the two
# orders cannot differ.
#
# THE POSITIONS (the catalog's `.proto` files, every `Ref`, `Value` and
# `SecretRef`):
#   * `uses[i].target`;
#   * a workload's (`service`, `container_job`, `worker`) `env` values,
#     `secret_env` secrets and `run_as`, and a service's `network`;
#   * a grant's `principal` and `target`; a queue's `dead_letter`; a
#     subscription's `topic` and `queue`; a DNS record's `zone` and `values`;
#     a certificate's `zone`; a schedule's `target`; an event trigger's
#     `source` and `target`; a subnet's `network`;
#   * a composite instance's `input` values, and the values of its
#     `map_input` maps.
# A new reference field of the catalog is one more line in `_walk`. One
# it lacks is not silent: `unrewritten` reads the rewritten resource's
# proto3 JSON for a `local`, `input` or `path` key, which only a reference
# can hold, and expansion raises on one (compose.mojo).
#
# A DROPPED site is removed: an optional reference becomes unset, a map
# entry and a list element are deleted. That is what an optional input left
# unbound does to the reference or value that names it.
# =============================================================================

from komira_proto_codec import encode_json
from kci_resource_proto.refs import Ref, SecretRef, Value
from kci_resource_proto.resource import Resource


comptime SITE_REF: Int = 1
"""A site holding a `Ref`."""
comptime SITE_VALUE: Int = 2
"""A site holding a `Value`."""


struct RefSite(Copyable, Movable, Deinitable):
    """One reference position of a resource: where it is (`path`), what it
    holds (a `Ref` or a `Value`), and, when written back, whether it is
    dropped."""

    var path: String
    var kind: Int
    var ref_: Optional[Ref]
    var value: Optional[Value]
    var drop: Bool

    def __init__(out self, path: String, r: Ref):
        self.path = path.copy()
        self.kind = SITE_REF
        self.ref_ = r.copy()
        self.value = None
        self.drop = False

    def __init__(out self, path: String, v: Value):
        self.path = path.copy()
        self.kind = SITE_VALUE
        self.ref_ = None
        self.value = v.copy()
        self.drop = False

    def __init__(out self, *, copy: Self):
        self.path = copy.path.copy()
        self.kind = copy.kind
        self.ref_ = copy.ref_.copy()
        self.value = copy.value.copy()
        self.drop = copy.drop


def no_ref() -> Ref:
    """A `Ref` with nothing written."""
    return Ref(String(""), None, None, None, 0, None, None)


def literal_value(text: String) -> Value:
    """`Value { literal: text }`."""
    return Value(1, text.copy(), None, None, None)


def ref_value(r: Ref) -> Value:
    """`Value { ref: r }`."""
    return Value(3, None, None, r.copy(), None)


def _sorted[V: Copyable & Movable & ImplicitlyDestructible](d: Dict[String, V]) -> List[String]:
    var keys = List[String]()
    for entry in d.items():
        keys.append(entry.key.copy())
    for i in range(1, len(keys)):
        var k = i
        while k > 0 and keys[k] < keys[k - 1]:
            var t = keys[k].copy()
            keys[k] = keys[k - 1].copy()
            keys[k - 1] = t^
            k -= 1
    return keys^


struct _Walk:
    """The cursor of one walk: reading appends to `sites`; writing consumes
    them in order from `at`."""

    var sites: List[RefSite]
    var write: Bool
    var at: Int

    def __init__(out self, var sites: List[RefSite], write: Bool):
        self.sites = sites^
        self.write = write
        self.at = 0

    def ref_slot(mut self, mut slot: Optional[Ref], path: String) raises:
        if not slot:
            return
        if not self.write:
            self.sites.append(RefSite(path, slot.value()))
            return
        var s = self.sites[self.at].copy()
        self.at += 1
        if s.kind != SITE_REF or s.path != path:
            raise Error(String("reference walk out of step at ") + path)
        if s.drop:
            slot = None
        else:
            slot = s.ref_.value().copy()

    def value_map(mut self, mut d: Dict[String, Value], prefix: String) raises:
        var keys = _sorted(d)
        for i in range(len(keys)):
            var path = prefix + String(".") + keys[i]
            if not self.write:
                self.sites.append(RefSite(path, d[keys[i]]))
                continue
            var s = self.sites[self.at].copy()
            self.at += 1
            if s.kind != SITE_VALUE or s.path != path:
                raise Error(String("reference walk out of step at ") + path)
            if s.drop:
                _ = d.pop(keys[i])
            else:
                d[keys[i]] = s.value.value().copy()

    def secret_map(mut self, mut d: Dict[String, SecretRef], prefix: String) raises:
        var keys = _sorted(d)
        for i in range(len(keys)):
            var entry = d[keys[i]].copy()
            self.ref_slot(entry.secret, prefix + String(".") + keys[i] + String(".secret"))
            if self.write:
                d[keys[i]] = entry^

    def value_list(mut self, mut l: List[Value], prefix: String) raises:
        var kept = List[Value]()
        for i in range(len(l)):
            var path = prefix + String("[") + String(i) + String("]")
            if not self.write:
                self.sites.append(RefSite(path, l[i]))
                continue
            var s = self.sites[self.at].copy()
            self.at += 1
            if s.kind != SITE_VALUE or s.path != path:
                raise Error(String("reference walk out of step at ") + path)
            if not s.drop:
                kept.append(s.value.value().copy())
        if self.write:
            l = kept^


def _walk(mut r: Resource, mut w: _Walk) raises:
    """Every reference position of `r`, in one fixed order (the header)."""
    for i in range(len(r.uses)):
        w.ref_slot(r.uses[i].target, String("uses[") + String(i) + String("].target"))
    if r.service:
        ref s = r.service.value()
        w.value_map(s.env, String("service.env"))
        w.secret_map(s.secret_env, String("service.secret_env"))
        w.ref_slot(s.run_as, String("service.run_as"))
        w.ref_slot(s.network, String("service.network"))
    if r.container_job:
        ref j = r.container_job.value()
        w.value_map(j.env, String("container_job.env"))
        w.secret_map(j.secret_env, String("container_job.secret_env"))
        w.ref_slot(j.run_as, String("container_job.run_as"))
    if r.worker:
        ref k = r.worker.value()
        w.value_map(k.env, String("worker.env"))
        w.secret_map(k.secret_env, String("worker.secret_env"))
        w.ref_slot(k.run_as, String("worker.run_as"))
    if r.grant:
        w.ref_slot(r.grant.value().principal, String("grant.principal"))
        w.ref_slot(r.grant.value().target, String("grant.target"))
    if r.queue:
        w.ref_slot(r.queue.value().dead_letter, String("queue.dead_letter"))
    if r.subscription:
        w.ref_slot(r.subscription.value().topic, String("subscription.topic"))
        w.ref_slot(r.subscription.value().queue, String("subscription.queue"))
    if r.dns_record:
        w.ref_slot(r.dns_record.value().zone, String("dns_record.zone"))
        w.value_list(r.dns_record.value().values, String("dns_record.values"))
    if r.certificate:
        w.ref_slot(r.certificate.value().zone, String("certificate.zone"))
    if r.schedule:
        w.ref_slot(r.schedule.value().target, String("schedule.target"))
    if r.event_trigger:
        w.ref_slot(r.event_trigger.value().source, String("event_trigger.source"))
        w.ref_slot(r.event_trigger.value().target, String("event_trigger.target"))
    if r.subnet:
        w.ref_slot(r.subnet.value().network, String("subnet.network"))
    if r.composite:
        ref ci = r.composite.value()
        w.value_map(ci.input, String("composite.input"))
        var names = _sorted(ci.map_input)
        for i in range(len(names)):
            var vm = ci.map_input[names[i]].copy()
            w.value_map(vm.value, String("composite.map_input.") + names[i])
            if w.write:
                ci.map_input[names[i]] = vm^


def ref_sites(r: Resource) raises -> List[RefSite]:
    """Every reference position of `r` that holds something, in the walk's
    order."""
    var copy = r.copy()
    var w = _Walk(List[RefSite](), False)
    _walk(copy, w)
    return w.sites.copy()


def with_sites(r: Resource, sites: List[RefSite]) raises -> Resource:
    """`r` with each of its reference positions replaced by the site of the
    same order (`ref_sites(r)` edited): kept, replaced, or removed when the
    site is dropped. Raises if `sites` is not a list of `r`'s positions."""
    var out = r.copy()
    var w = _Walk(sites.copy(), True)
    _walk(out, w)
    if w.at != len(sites):
        raise Error(String("reference walk wrote ") + String(w.at) + String(" of ") + String(len(sites)) + String(" sites"))
    return out^


def unrewritten(r: Resource) raises -> String:
    """The first of `"local":`, `"input":` and `"path":` in `r`'s proto3
    JSON, or empty. Only a `Ref` (`local`, `input`, `path`), a `Value`
    (`input`) and a composite instance (`input`) have such keys, so a
    primitive that expansion has rewritten holds none: one found here is a
    reference position `_walk` does not know."""
    var text = encode_json(r)
    for key in [String('"local":'), String('"input":'), String('"path":')]:
        if text.find(key) >= 0:
            return key
    return String("")


# ---- the grammars -----------------------------------------------------------------


comptime ID_MAX_BYTES = 24
"""The longest resource id. Narrowing later breaks authors; widening is free."""

def id_problem(id: String) -> String:
    """Why `id` is not a legal resource id, or empty if it is. The grammar is
    `[a-z][a-z0-9-]{0,23}`, with no trailing `-` and no `--`: a lowercase
    letter first, then lowercase letters, digits and single dashes. It keeps
    every id usable in a cloud name or label after a prefix, and it never
    contains `/`, the engine's node-id separator (only expansion writes one,
    between the segments of a path)."""
    var b = id.as_bytes()
    var n = len(b)
    if n == 0:
        return String("empty id")
    if n > ID_MAX_BYTES:
        return (
            String("id is ")
            + String(n)
            + String(" bytes; at most ")
            + String(ID_MAX_BYTES)
        )
    if Int(b[0]) < ord("a") or Int(b[0]) > ord("z"):
        return String("an id starts with a lowercase letter (a-z)")
    for i in range(n):
        var c = Int(b[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        if not lower and not digit and c != ord("-"):
            return String("an id is lowercase letters, digits and '-' only")
        if c == ord("-") and i > 0 and Int(b[i - 1]) == ord("-"):
            return String("an id may not contain '--'")
    if Int(b[n - 1]) == ord("-"):
        return String("an id may not end with '-'")
    return String("")


def owner_of_node(node_id: String) -> String:
    """The authored resource that owns node (or produced resource)
    `node_id`: its FIRST segment, at any depth (`top/a/b/c/run` -> `top`).
    An authored id and a component id cannot hold `/`, so this is exact
    however deep a node is."""
    var i = node_id.find("/")
    if i < 0:
        return node_id.copy()
    return String(node_id[byte=0:i])


comptime COMPONENT_ID_MAX_BYTES = 12
"""The longest component id. 12 keeps depth 4 inside the 63-byte role label
at the longest ids (validate.mojo)."""

comptime NAME_PART_MAX_BYTES = 32
"""The longest namespace, definition name, input name or output name."""


def _dash_grammar(s: String, max_bytes: Int, what: String) -> String:
    """`[a-z][a-z0-9-]{0,max-1}` with no `--` and no trailing `-`, or why
    not."""
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return String("empty ") + what
    if n > max_bytes:
        return what + String(" is ") + String(n) + String(" bytes; at most ") + String(max_bytes)
    if Int(b[0]) < ord("a") or Int(b[0]) > ord("z"):
        return String("a ") + what + String(" starts with a lowercase letter (a-z)")
    for i in range(n):
        var c = Int(b[i])
        var ok = (c >= ord("a") and c <= ord("z")) or (c >= ord("0") and c <= ord("9")) or c == ord("-")
        if not ok:
            return String("a ") + what + String(" is lowercase letters, digits and '-' only")
        if c == ord("-") and i > 0 and Int(b[i - 1]) == ord("-"):
            return String("a ") + what + String(" may not contain '--'")
    if Int(b[n - 1]) == ord("-"):
        return String("a ") + what + String(" may not end with '-'")
    return String("")


def component_id_problem(id: String) -> String:
    """Why `id` is not a legal component id, or empty. The grammar is
    `[a-z][a-z0-9-]{0,11}` with no `--` and no trailing `-`; the words of
    the role vocabulary (`run`, `public`, `identity`, `schedule`), `uses`,
    `cell`, and anything starting `u-` or `ix-` are reserved."""
    var bad = _dash_grammar(id, COMPONENT_ID_MAX_BYTES, String("component id"))
    if bad.byte_length() > 0:
        return bad^
    for w in [String("run"), String("public"), String("identity"), String("schedule"), String("uses"), String("cell")]:
        if id == w:
            return String("\"") + id + String("\" is reserved")
    if id.startswith("u-") or id.startswith("ix-"):
        return String("an id starting \"u-\" or \"ix-\" is reserved (kci's own roles)")
    return String("")


def definition_name_problem(name: String) -> String:
    """Why `name` is not `<namespace>.<name>`, each part
    `[a-z][a-z0-9-]{0,31}`, or empty."""
    var dot = name.find(".")
    if dot < 0 or name.find(".", dot + 1) >= 0:
        return String("a definition name is <namespace>.<name>, with exactly one '.'")
    var ns = _dash_grammar(String(name[byte=0:dot]), NAME_PART_MAX_BYTES, String("namespace"))
    if ns.byte_length() > 0:
        return ns^
    return _dash_grammar(String(name[byte = dot + 1 : name.byte_length()]), NAME_PART_MAX_BYTES, String("name"))


def version_problem(v: String) -> String:
    """Why `v` is not a definition version (`[A-Za-z0-9][A-Za-z0-9._-]{0,31}`),
    or empty."""
    var b = v.as_bytes()
    if len(b) == 0:
        return String("a definition has a version")
    if len(b) > NAME_PART_MAX_BYTES:
        return String("a version is at most ") + String(NAME_PART_MAX_BYTES) + String(" bytes")
    for i in range(len(b)):
        var c = Int(b[i])
        var alnum = (c >= ord("a") and c <= ord("z")) or (c >= ord("A") and c <= ord("Z")) or (c >= ord("0") and c <= ord("9"))
        if not alnum and (i == 0 or (c != ord(".") and c != ord("_") and c != ord("-"))):
            return String("a version is letters, digits, '.', '_' and '-', starting with a letter or digit")
    return String("")


def snake_name_problem(name: String, what: String) -> String:
    """Why `name` is not `[a-z][a-z0-9_]{0,31}` (an input or output name), or
    empty."""
    var b = name.as_bytes()
    if len(b) == 0:
        return String("empty ") + what
    if len(b) > NAME_PART_MAX_BYTES:
        return what + String(" is ") + String(len(b)) + String(" bytes; at most ") + String(NAME_PART_MAX_BYTES)
    if Int(b[0]) < ord("a") or Int(b[0]) > ord("z"):
        return String("a ") + what + String(" starts with a lowercase letter (a-z)")
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or (c >= ord("0") and c <= ord("9")) or c == ord("_")):
            return String("a ") + what + String(" is lowercase letters, digits and '_' only")
    return String("")
