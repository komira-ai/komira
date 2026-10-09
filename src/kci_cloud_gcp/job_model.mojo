# =============================================================================
# kci_cloud_gcp/job_model.mojo: a container job's run node as a Cloud Run job.
# =============================================================================
#
# THE MODEL is the job's modelled state as ordered (key, value) pairs, built
# the same way from the lowered node (`desired_model`) and from the job the
# cloud holds (`live_model`); a node is matched when the two are equal. Each
# key, and where it lives in the job (Cloud Run Admin v2 `Job`):
#   img         `template.template.containers[0].image`: the digest of the
#               lowered `img` (`<digest>@<platform>`); a Run job runs
#               linux/amd64 only, so the platform reads back as that
#   cmd         `...containers[0].command[]`, one per entry, in order
#   arg         `...containers[0].args[]`, one per entry, in order
#   env.<KEY>   `...containers[0].env[]` `{name, value}`, in key order: a
#               literal, or a reference's value once bound
#   size        `...containers[0].resources.limits` `cpu` (`<n>m`) and
#               `memory` (`<n>Mi` for the lowered `<n>MB`)
#   retries     `template.template.maxRetries`
#   timeout     `template.template.timeout` (a Duration: `600s`, or
#               `1.000000005s` with nanoseconds)
#   sa          `template.template.serviceAccount`: the email of the identity
#               the job runs as (its own, or its `run_as` account's)
#   label.<k>   `labels[k]`, each author label, in key order
#   retention   `labels["kci-retention"]`
#   ready       `true` unless the terminal condition is CONDITION_FAILED
# `job_json` writes a job from the model and the labels to write (kci's and
# the author's, merged by the caller); the service's own fields are never
# written. kci's labels and the author's go to the job's `labels` AND to its
# execution template's (`template.labels`): Cloud Run copies only the
# template's labels onto each execution, which is what is billed and
# logged, so every execution carries the identity, the run id and the
# retention mark too. `with_kci_labels` sets (an adoption) or drops (a
# release) kci's labels in both places and keeps every other label. An UPDATE writes `overlay_job`: the job as it stands with only
# those places replaced (the labels, the first container's image, command,
# args, env and resource limits, the task's maxRetries, timeout and service
# account), so every field kci does not model (a working directory, a
# volume, a parallelism, a second container) is kept, on an adopted job as
# on any other.
# =============================================================================

from kci_cloud import LoweredNode, V1_IMAGE_PLATFORM, is_kci_label_key, retention_label_key, retention_label_value
from kci_reconciler import Label, ModelledDigest
from komira_json import JsonValue, parse_json_value

from kci_cloud_gcp.session import json_text


comptime LABEL_FIELD = "label."
comptime ENV_MARK = ".env."


@fieldwise_init
struct ModelField(Copyable, Movable):
    var key: String
    var value: String


def model_value(model: List[ModelField], key: String) -> String:
    """The first value of `key`, or empty."""
    for i in range(len(model)):
        if model[i].key == key:
            return model[i].value.copy()
    return String("")


def model_values(model: List[ModelField], key: String) -> List[String]:
    var out = List[String]()
    for i in range(len(model)):
        if model[i].key == key:
            out.append(model[i].value.copy())
    return out^


def _sorted_pairs(var pairs: List[ModelField]) -> List[ModelField]:
    for i in range(1, len(pairs)):
        var k = i
        while k > 0 and pairs[k].key < pairs[k - 1].key:
            var t = pairs[k].copy()
            pairs[k] = pairs[k - 1].copy()
            pairs[k - 1] = t^
            k -= 1
    return pairs^


def timeout_duration(lowered: String) raises -> String:
    """`600s0n` as a Duration's JSON: `600s`, or `1.000000005s`."""
    var s = lowered.find("s")
    if s <= 0 or not lowered.endswith("n"):
        raise Error(String("kci_cloud_gcp: a timeout that is not <seconds>s<nanos>n: ") + lowered)
    var secs = String(lowered[byte=0:s])
    var nanos = atol(String(lowered[byte = s + 1 : lowered.byte_length() - 1]))
    if nanos == 0:
        return secs + String("s")
    var frac = String(nanos)
    while frac.byte_length() < 9:
        frac = String("0") + frac
    return secs + String(".") + frac + String("s")


def lowered_timeout(duration: String) -> String:
    """A Duration's JSON as the lowering writes it (`600s` -> `600s0n`); an
    empty duration reads as empty."""
    if not duration.endswith("s"):
        return duration.copy()
    var body = String(duration[byte = 0 : duration.byte_length() - 1])
    var dot = body.find(".")
    if dot < 0:
        return body + String("s0n")
    var frac = String(body[byte = dot + 1 : body.byte_length()])
    while frac.byte_length() < 9:
        frac += String("0")
    var nanos = 0
    try:
        nanos = atol(frac)
    except:
        return duration.copy()
    return String(body[byte=0:dot]) + String("s") + String(nanos) + String("n")


def size_limits(size: String) raises -> Tuple[String, String]:
    """`1000m/512MB` as the container's (cpu, memory) limits:
    (`1000m`, `512Mi`)."""
    var slash = size.find("/")
    if slash <= 0 or not size.endswith("MB"):
        raise Error(String("kci_cloud_gcp: a size that is not <cpu>m/<memory>MB: ") + size)
    var cpu = String(size[byte=0:slash])
    var mem = String(size[byte = slash + 1 : size.byte_length() - 2])
    return (cpu^, mem + String("Mi"))


def lowered_size(cpu: String, memory: String) -> String:
    var mem = memory.copy()
    if mem.endswith("Mi"):
        mem = String(mem[byte = 0 : mem.byte_length() - 2]) + String("MB")
    return cpu + String("/") + mem


def image_of(img: String) -> String:
    """The digest of a lowered `img` (`<digest>@<platform>`)."""
    var at = img.rfind("@")
    if at < 0:
        return img.copy()
    return String(img[byte=0:at])


def desired_model(
    node: LoweredNode, bound: List[String], sa_email: String, retention: Int
) raises -> List[ModelField]:
    """The node's model (the file header); `bound` holds the values of its
    input references, in order, and `sa_email` the identity it runs as."""
    var out = List[ModelField]()
    out.append(ModelField(String("img"), image_of(node.field(String("img"))) + String("@") + String(V1_IMAGE_PLATFORM)))
    for i in range(len(node.desired)):
        if node.desired[i].key == "cmd":
            out.append(ModelField(String("cmd"), node.desired[i].value.copy()))
    for i in range(len(node.desired)):
        if node.desired[i].key == "arg":
            out.append(ModelField(String("arg"), node.desired[i].value.copy()))
    var env = List[ModelField]()
    for i in range(len(node.desired)):
        ref k = node.desired[i].key
        var at = k.find(ENV_MARK)
        if at > 0 and k.find(".secret_env.") < 0:
            env.append(
                ModelField(String("env.") + String(k[byte = at + 5 : k.byte_length()]), node.desired[i].value.copy())
            )
    for i in range(len(node.inputs)):
        ref f = node.inputs[i].field
        var at = f.find(ENV_MARK)
        if at > 0 and i < len(bound):
            env.append(ModelField(String("env.") + String(f[byte = at + 5 : f.byte_length()]), bound[i].copy()))
    out.extend(_sorted_pairs(env^))
    out.append(ModelField(String("size"), node.field(String("size"))))
    out.append(ModelField(String("retries"), node.field(String("retries"))))
    out.append(ModelField(String("timeout"), node.field(String("timeout"))))
    out.append(ModelField(String("sa"), sa_email.copy()))
    var labels = List[ModelField]()
    for i in range(len(node.desired)):
        ref k = node.desired[i].key
        if k.startswith(LABEL_FIELD):
            labels.append(ModelField(k.copy(), node.desired[i].value.copy()))
    out.extend(_sorted_pairs(labels^))
    out.append(ModelField(String("retention"), retention_label_value(retention)))
    out.append(ModelField(String("ready"), String("true")))
    return out^


def model_digest(kind: String, model: List[ModelField]) raises -> String:
    var d = ModelledDigest(kind)
    for i in range(len(model)):
        d.field(model[i].key, model[i].value)
    return d.text()


def _strings(arr: JsonValue) raises -> List[String]:
    var out = List[String]()
    for i in range(arr.array_len()):
        out.append(arr.element_at(i).as_string())
    return out^


def _member(obj: JsonValue, key: String) raises -> JsonValue:
    if obj.is_object() and obj.has(key):
        return obj.get(key)
    return JsonValue.null()


def _text(v: JsonValue) raises -> String:
    if v.is_string():
        return v.as_string()
    if v.is_number():
        return v.text.copy()
    return String("")


def job_labels(doc: JsonValue) raises -> List[Label]:
    """The labels a job's JSON carries, in its order."""
    var out = List[Label]()
    var labels = _member(doc, String("labels"))
    if not labels.is_object():
        return out^
    for i in range(labels.num_members()):
        out.append(Label(labels.key_at(i), _text(labels.value_at(i))))
    return out^


def live_model(doc: JsonValue, desired: List[ModelField]) raises -> List[ModelField]:
    """The model of a job's JSON (`doc`), in the order of the file header;
    `desired` says which author labels to read."""
    var out = List[ModelField]()
    var task = _member(_member(doc, String("template")), String("template"))
    var containers = _member(task, String("containers"))
    var c = JsonValue.empty_object()
    if containers.array_len() > 0:
        c = containers.element_at(0)
    out.append(ModelField(String("img"), _text(_member(c, String("image"))) + String("@") + String(V1_IMAGE_PLATFORM)))
    var cmds = _member(c, String("command"))
    if cmds.is_array():
        var l = _strings(cmds)
        for i in range(len(l)):
            out.append(ModelField(String("cmd"), l[i].copy()))
    var args = _member(c, String("args"))
    if args.is_array():
        var l = _strings(args)
        for i in range(len(l)):
            out.append(ModelField(String("arg"), l[i].copy()))
    var env = List[ModelField]()
    var envs = _member(c, String("env"))
    for i in range(envs.array_len()):
        var e = envs.element_at(i)
        env.append(ModelField(String("env.") + _text(_member(e, String("name"))), _text(_member(e, String("value")))))
    out.extend(_sorted_pairs(env^))
    var limits = _member(_member(c, String("resources")), String("limits"))
    out.append(ModelField(String("size"), lowered_size(_text(_member(limits, String("cpu"))), _text(_member(limits, String("memory"))))))
    var retries = _text(_member(task, String("maxRetries")))
    if retries.byte_length() == 0:
        retries = String("0")
    out.append(ModelField(String("retries"), retries^))
    out.append(ModelField(String("timeout"), lowered_timeout(_text(_member(task, String("timeout"))))))
    out.append(ModelField(String("sa"), _text(_member(task, String("serviceAccount")))))
    var have = job_labels(doc)
    for i in range(len(desired)):
        if not desired[i].key.startswith(LABEL_FIELD):
            continue
        var key = String(desired[i].key[byte = String(LABEL_FIELD).byte_length() : desired[i].key.byte_length()])
        for k in range(len(have)):
            if have[k].key == key:
                out.append(ModelField(desired[i].key.copy(), have[k].value.copy()))
    var mark = String("(none)")
    var mark_key = retention_label_key()
    for k in range(len(have)):
        if have[k].key == mark_key:
            mark = have[k].value.copy()
    out.append(ModelField(String("retention"), mark^))
    var state = _text(_member(_member(doc, String("terminalCondition")), String("state")))
    out.append(ModelField(String("ready"), String("false") if state == "CONDITION_FAILED" else String("true")))
    return out^


def author_labels(model: List[ModelField]) -> List[Label]:
    """The author's labels of a model (`label.<k>` keys)."""
    var out = List[Label]()
    for i in range(len(model)):
        if model[i].key.startswith(LABEL_FIELD):
            out.append(
                Label(String(model[i].key[byte = String(LABEL_FIELD).byte_length() : model[i].key.byte_length()]), model[i].value.copy())
            )
    return out^


def _labels_object(labels: List[Label]) -> String:
    var out = String("{")
    for i in range(len(labels)):
        if i > 0:
            out += String(",")
        out += json_text(labels[i].key) + String(":") + json_text(labels[i].value)
    return out + String("}")


def _has_key(labels: List[Label], key: String) -> Bool:
    for i in range(len(labels)):
        if labels[i].key == key:
            return True
    return False


def job_json(model: List[ModelField], labels: List[Label], name: String = String("")) raises -> String:
    """A job's JSON from `model` (the file header), carrying `labels`, and
    named `name` when it is given (an update names the job it replaces)."""
    var cpu_mem = size_limits(model_value(model, String("size")))
    var out = String("{")
    if name.byte_length() > 0:
        out += String("\"name\":") + json_text(name) + String(",")
    out += String("\"labels\":") + _labels_object(labels)
    # The execution template carries kci's labels and the author's (not a
    # label the job holds that kci was not handed).
    var carried = List[Label]()
    var authors = author_labels(model)
    for i in range(len(labels)):
        if is_kci_label_key(labels[i].key) or _has_key(authors, labels[i].key):
            carried.append(labels[i].copy())
    out += String(",\"template\":{\"labels\":") + _labels_object(carried)
    out += String(",\"template\":{\"containers\":[{\"image\":")
    out += json_text(image_of(model_value(model, String("img"))))
    out += String(",\"command\":[")
    var cmds = model_values(model, String("cmd"))
    for i in range(len(cmds)):
        if i > 0:
            out += String(",")
        out += json_text(cmds[i])
    out += String("],\"args\":[")
    var args = model_values(model, String("arg"))
    for i in range(len(args)):
        if i > 0:
            out += String(",")
        out += json_text(args[i])
    out += String("],\"env\":[")
    var first = True
    for i in range(len(model)):
        if not model[i].key.startswith("env."):
            continue
        if not first:
            out += String(",")
        first = False
        out += String("{\"name\":") + json_text(String(model[i].key[byte = 4 : model[i].key.byte_length()]))
        out += String(",\"value\":") + json_text(model[i].value) + String("}")
    out += String("],\"resources\":{\"limits\":{\"cpu\":") + json_text(cpu_mem[0])
    out += String(",\"memory\":") + json_text(cpu_mem[1]) + String("}}}]")
    out += String(",\"maxRetries\":") + model_value(model, String("retries"))
    out += String(",\"timeout\":") + json_text(timeout_duration(model_value(model, String("timeout"))))
    out += String(",\"serviceAccount\":") + json_text(model_value(model, String("sa")))
    out += String("}}}")
    return out^


def parse_job(text: String) raises -> JsonValue:
    return parse_json_value(text)


def _with(obj: JsonValue, key: String, var value: JsonValue) raises -> JsonValue:
    """`obj` (an object, or anything else read as `{}`) with member `key`
    set to `value`, in place where it was, else appended."""
    var out = JsonValue.empty_object()
    var done = False
    if obj.is_object():
        for i in range(obj.num_members()):
            var k = obj.key_at(i)
            if k == key:
                if not done:
                    out.set_member(k^, value.copy())
                    done = True
                continue
            out.set_member(k^, obj.value_at(i))
    if not done:
        out.set_member(key.copy(), value^)
    return out^


def _container_fields() -> List[String]:
    return [String("image"), String("command"), String("args"), String("env")]


def _task_fields() -> List[String]:
    return [String("maxRetries"), String("timeout"), String("serviceAccount")]


def overlay_job(live_json: String, desired_json: String) raises -> String:
    """The job `live_json` holds with only kci's modelled places replaced by
    `desired_json`'s (the file header); every other field is kept."""
    var live = parse_json_value(live_json)
    var want = parse_json_value(desired_json)
    var out = _with(live, String("labels"), _member(want, String("labels")))
    if want.has("name"):
        out = _with(out, String("name"), want.get("name"))
    var want_task = _member(_member(want, String("template")), String("template"))
    var want_c = _member(want_task, String("containers")).element_at(0)
    var lt = _member(out, String("template"))
    # The template's labels: every live one kci was not handed, then kci's
    # and the author's as the desired job writes them.
    var want_labels = _member(_member(want, String("template")), String("labels"))
    var kept = JsonValue.empty_object()
    var live_labels = _member(lt, String("labels"))
    if live_labels.is_object():
        for i in range(live_labels.num_members()):
            var k = live_labels.key_at(i)
            if is_kci_label_key(k) or (want_labels.is_object() and want_labels.has(k)):
                continue
            kept.set_member(k^, live_labels.value_at(i))
    if want_labels.is_object():
        for i in range(want_labels.num_members()):
            kept.set_member(want_labels.key_at(i), want_labels.value_at(i))
    lt = _with(lt, String("labels"), kept^)
    var task = _member(lt, String("template"))
    var containers = _member(task, String("containers"))
    var first = JsonValue.empty_object()
    if containers.array_len() > 0:
        first = containers.element_at(0)
    var cfields = _container_fields()
    for i in range(len(cfields)):
        ref k = cfields[i]
        if want_c.has(k):
            first = _with(first, k, want_c.get(k))
    var resources = _with(_member(first, String("resources")), String("limits"), _member(_member(want_c, String("resources")), String("limits")))
    first = _with(first, String("resources"), resources^)
    var arr = JsonValue.empty_array()
    arr.push(first^)
    for i in range(1, containers.array_len()):
        arr.push(containers.element_at(i))
    task = _with(task, String("containers"), arr^)
    var tfields = _task_fields()
    for i in range(len(tfields)):
        ref k = tfields[i]
        if want_task.has(k):
            task = _with(task, k, want_task.get(k))
    lt = _with(lt, String("template"), task^)
    out = _with(out, String("template"), lt^)
    return out.serialize()


def _kci_free(labels: JsonValue, var kci: List[Label]) raises -> JsonValue:
    """`labels` (an object, or anything else read as none) without kci's
    labels, then with `kci`."""
    var out = JsonValue.empty_object()
    if labels.is_object():
        for i in range(labels.num_members()):
            var k = labels.key_at(i)
            if not is_kci_label_key(k):
                out.set_member(k^, labels.value_at(i))
    for i in range(len(kci)):
        out.set_member(kci[i].key.copy(), JsonValue.from_string(kci[i].value.copy()))
    return out^


def with_kci_labels(job_json_text: String, kci: List[Label]) raises -> String:
    """The job with kci's labels replaced by `kci` (empty: dropped) in its
    `labels` and its execution template's, every other label and field
    kept: an adoption's and a release's one write."""
    var doc = parse_json_value(job_json_text)
    var out = _with(doc, String("labels"), _kci_free(_member(doc, String("labels")), kci.copy()))
    var t = _member(out, String("template"))
    t = _with(t, String("labels"), _kci_free(_member(t, String("labels")), kci.copy()))
    out = _with(out, String("template"), t^)
    return out.serialize()
