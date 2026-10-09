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
# written.
# =============================================================================

from kci_cloud import LoweredNode, V1_IMAGE_PLATFORM, retention_label_key, retention_label_value
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


def job_json(model: List[ModelField], labels: List[Label], name: String = String("")) raises -> String:
    """A job's JSON from `model` (the file header), carrying `labels`, and
    named `name` when it is given (an update names the job it replaces)."""
    var cpu_mem = size_limits(model_value(model, String("size")))
    var out = String("{")
    if name.byte_length() > 0:
        out += String("\"name\":") + json_text(name) + String(",")
    out += String("\"labels\":{")
    for i in range(len(labels)):
        if i > 0:
            out += String(",")
        out += json_text(labels[i].key) + String(":") + json_text(labels[i].value)
    out += String("},\"template\":{\"template\":{\"containers\":[{\"image\":")
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
