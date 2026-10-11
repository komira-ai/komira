# =============================================================================
# komira_push/wake.mojo -- the content-blind wake and the payload-shape guard.
# =============================================================================
#
# A device is woken with exactly three strings: which item (`id`), what kind
# of event (`kind`) and which service holds it (`source`). The woken client
# fetches the item from `source` over its own authenticated channel, so the
# push service, and anyone who reads the push, learns only that something of
# that kind happened.
#
# Two checks hold that shape:
#   * `check_wake_fields[T]()` reads a struct's field names by reflection and
#     refuses any name outside {id, kind, source}. `WakeTrigger` is checked
#     with it by `check_wake_trigger_shape()`, so a field added to
#     `WakeTrigger` is refused before any plaintext is built.
#   * `check_wake_payload(text)` parses the plaintext a sender is about to
#     hand to a push service and refuses anything but one JSON object whose
#     members are a subset of {id, kind, source}, each a string, each at most
#     once. A sender runs it on the bytes it actually sends.
#
# Encapsulation: owned Strings only; no pointer in any signature.
# =============================================================================

from komira_json import JsonValue, parse_json_value


comptime WAKE_FIELD_ID: String = "id"
comptime WAKE_FIELD_KIND: String = "kind"
comptime WAKE_FIELD_SOURCE: String = "source"


def _is_wake_field(name: String) -> Bool:
    return (
        name == WAKE_FIELD_ID
        or name == WAKE_FIELD_KIND
        or name == WAKE_FIELD_SOURCE
    )


@fieldwise_init
struct WakeTrigger(Copyable, Movable, Deinitable):
    """What a woken device is told: the item (`id`), the kind of event
    (`kind`) and the service that holds it (`source`). There is no field for
    content, and `check_wake_trigger_shape()` refuses one if it is added."""

    var id: String
    var kind: String
    var source: String

    def payload_json(self) raises -> String:
        """The plaintext a push service carries:
        `{"id":"<id>","kind":"<kind>","source":"<source>"}`, each value a
        JSON string escaped by komira_json. Refused when any field is empty
        (a device cannot act on a wake missing one) or when the struct has a
        field outside {id, kind, source}."""
        check_wake_trigger_shape()
        if self.id.byte_length() == 0:
            raise Error("komira_push: the wake id is empty")
        if self.kind.byte_length() == 0:
            raise Error("komira_push: the wake kind is empty")
        if self.source.byte_length() == 0:
            raise Error("komira_push: the wake source is empty")
        var obj = JsonValue.empty_object()
        obj.set_member(String(WAKE_FIELD_ID), JsonValue.from_string(self.id.copy()))
        obj.set_member(
            String(WAKE_FIELD_KIND), JsonValue.from_string(self.kind.copy())
        )
        obj.set_member(
            String(WAKE_FIELD_SOURCE), JsonValue.from_string(self.source.copy())
        )
        return obj.serialize()


def check_wake_fields[T: AnyType]() raises:
    """Refuse a struct `T` that has a field named other than `id`, `kind` or
    `source`. The message names the first such field."""
    comptime count = reflect[T].field_count()
    var names = reflect[T].field_names()
    for i in range(count):
        var name = String(names[i])
        if not _is_wake_field(name):
            raise Error(
                String("komira_push: a wake carries only id, kind and source;")
                + String(" the type has a field named ")
                + name
            )


def check_wake_trigger_shape() raises:
    """`check_wake_fields` on `WakeTrigger`."""
    check_wake_fields[WakeTrigger]()


def check_wake_payload(text: String) raises:
    """Refuse a wake plaintext that is not one JSON object whose members are
    a subset of {id, kind, source}, each a JSON string and each at most once.
    The message names the offending member; it never quotes a value."""
    var v = parse_json_value(text)
    if not v.is_object():
        raise Error("komira_push: a wake payload is a JSON object")
    var seen_id = False
    var seen_kind = False
    var seen_source = False
    for i in range(v.num_members()):
        var key = v.key_at(i)
        if not _is_wake_field(key):
            raise Error(
                String("komira_push: a wake payload carries only id, kind and")
                + String(" source; it has a member named ")
                + key
            )
        if not v.value_at(i).is_string():
            raise Error(
                String("komira_push: the wake payload member ")
                + key
                + String(" is not a string")
            )
        var dup = False
        if key == WAKE_FIELD_ID:
            dup = seen_id
            seen_id = True
        elif key == WAKE_FIELD_KIND:
            dup = seen_kind
            seen_kind = True
        else:
            dup = seen_source
            seen_source = True
        if dup:
            raise Error(
                String("komira_push: the wake payload member ")
                + key
                + String(" appears twice")
            )
