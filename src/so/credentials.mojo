"""`SessionCredentials`: the credentials a session holds, by name.

A host defines a credential in three steps, the three C calls
`komira_credential_add`, `komira_credential_set` and `komira_credential_seal`:

1. `add(kind, name)` opens a definition of `name` with a `KOMIRA_CRED_*` kind
   and returns its id;
2. `set(id, field, value)` sets one `KOMIRA_FIELD_*` field of it, once per
   field (setting a field again replaces it);
3. `seal(id, KOMIRA_BIND_SESSION)` checks the definition has every field its
   kind needs and makes it the session's value of `name`. The id is closed.

A sealed credential's values live in the session's `SessionSecretStore`, one
`secret_ref` per field, bound by node id in a `SecretBindings` table. Nothing
here hands a value back: a consumer reads one through
`SecretCapability(node_id_of(name, field)).open_connection_for(
secret_bindings(), secret_store(), consumer)`, or a `SecretRegistry` reveal
over the same bindings and store, which mint a zeroizing `SecretValue` for the
call. Values are wiped when they are replaced, when a definition is
discarded, and when the session is dropped.

Generations. Each seal of a name gets a generation from one counter of the
session, unless the name already holds a byte-equal value of the same kind,
which keeps its generation. Whatever is cached under a credential is keyed by
`(name, generation)`.

Refusals. Every refusal raises `CREDENTIALS_INVALID: <operation>: <reason>`,
except a lookup of a name with no sealed value, `CREDENTIAL_UNBOUND`. A
message names the credential (`credential=<name>`, a name is not a secret) and
the setting (`secret=`), never a value. A name that is refused is not quoted
either, since it may be a value pasted in the wrong place. A refused `set` or
`seal` discards the whole definition, wiping what it held: its id is no
longer open.

The names `ambient` and `anonymous` are built in (the process's own identity
and no credential); defining either, in any case, is refused. A name is 1 to
128 bytes of ASCII letters, digits, `_`, `.` and `-`.
"""

from crypto import zeroize_list
from secret_registry.secret_bindings import SecretBindings

from .credential_store import SessionSecretStore
from .status import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_CRED_AWS_PROFILE,
    KOMIRA_CRED_AZURE_KEY,
    KOMIRA_CRED_AZURE_SAS,
    KOMIRA_CRED_BEARER,
    KOMIRA_CRED_GCP_SERVICE_ACCOUNT,
    KOMIRA_CRED_GCP_TOKEN,
    KOMIRA_CRED_OAUTH2_CLIENT,
    KOMIRA_FIELD_ACCOUNT,
    KOMIRA_FIELD_CLIENT_ID,
    KOMIRA_FIELD_CLIENT_SECRET,
    KOMIRA_FIELD_FILE,
    KOMIRA_FIELD_KEY,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_PROFILE,
    KOMIRA_FIELD_SAS,
    KOMIRA_FIELD_SCOPE,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_SESSION_TOKEN,
    KOMIRA_FIELD_TOKEN,
    KOMIRA_FIELD_TOKEN_URL,
)

from secret_store import MAX_SECRET_LEN

comptime CREDENTIAL_NAME_MAX_BYTES = 128
"""The longest credential name, in bytes."""
comptime CREDENTIALS_INVALID = "CREDENTIALS_INVALID"
"""The code of every refusal of a definition."""
comptime CREDENTIAL_UNBOUND = "CREDENTIAL_UNBOUND"
"""The code of a lookup of a name with no sealed value."""


def kind_label(kind: Int32) -> String:
    """The name a message gives a `KOMIRA_CRED_*` kind: the Python class
    that defines it (`AwsKeys`); empty for a number that is not a kind."""
    if kind == KOMIRA_CRED_AWS_KEYS:
        return "AwsKeys"
    if kind == KOMIRA_CRED_AWS_PROFILE:
        return "AwsProfile"
    if kind == KOMIRA_CRED_GCP_SERVICE_ACCOUNT:
        return "GcpServiceAccount"
    if kind == KOMIRA_CRED_GCP_TOKEN:
        return "GcpToken"
    if kind == KOMIRA_CRED_AZURE_KEY:
        return "AzureKey"
    if kind == KOMIRA_CRED_AZURE_SAS:
        return "AzureSas"
    if kind == KOMIRA_CRED_BEARER:
        return "BearerToken"
    if kind == KOMIRA_CRED_OAUTH2_CLIENT:
        return "OAuth2ClientCredentials"
    return ""


def field_label(field: Int32) -> String:
    """The name a message gives a `KOMIRA_FIELD_*` field, as the setting is
    spelled (`secret=`); empty for a number that is not a field."""
    if field == KOMIRA_FIELD_KEY_ID:
        return "key_id="
    if field == KOMIRA_FIELD_SECRET:
        return "secret="
    if field == KOMIRA_FIELD_SESSION_TOKEN:
        return "session_token="
    if field == KOMIRA_FIELD_PROFILE:
        return "profile="
    if field == KOMIRA_FIELD_FILE:
        return "file="
    if field == KOMIRA_FIELD_TOKEN:
        return "token="
    if field == KOMIRA_FIELD_ACCOUNT:
        return "account="
    if field == KOMIRA_FIELD_KEY:
        return "key="
    if field == KOMIRA_FIELD_SAS:
        return "sas="
    if field == KOMIRA_FIELD_CLIENT_ID:
        return "client_id="
    if field == KOMIRA_FIELD_CLIENT_SECRET:
        return "client_secret="
    if field == KOMIRA_FIELD_SCOPE:
        return "scope="
    if field == KOMIRA_FIELD_TOKEN_URL:
        return "token_url="
    return ""


def required_fields(kind: Int32) -> List[Int32]:
    """The fields a definition of `kind` must set before it is sealed."""
    if kind == KOMIRA_CRED_AWS_KEYS:
        return [KOMIRA_FIELD_KEY_ID, KOMIRA_FIELD_SECRET]
    if kind == KOMIRA_CRED_AWS_PROFILE:
        return [KOMIRA_FIELD_PROFILE]
    if kind == KOMIRA_CRED_GCP_SERVICE_ACCOUNT:
        return [KOMIRA_FIELD_FILE]
    if kind == KOMIRA_CRED_GCP_TOKEN or kind == KOMIRA_CRED_BEARER:
        return [KOMIRA_FIELD_TOKEN]
    if kind == KOMIRA_CRED_AZURE_KEY:
        return [KOMIRA_FIELD_ACCOUNT, KOMIRA_FIELD_KEY]
    if kind == KOMIRA_CRED_AZURE_SAS:
        return [KOMIRA_FIELD_ACCOUNT, KOMIRA_FIELD_SAS]
    if kind == KOMIRA_CRED_OAUTH2_CLIENT:
        return [KOMIRA_FIELD_CLIENT_ID, KOMIRA_FIELD_CLIENT_SECRET]
    return List[Int32]()


def optional_fields(kind: Int32) -> List[Int32]:
    """The fields a definition of `kind` may set but need not."""
    if kind == KOMIRA_CRED_AWS_KEYS:
        return [KOMIRA_FIELD_SESSION_TOKEN]
    if kind == KOMIRA_CRED_OAUTH2_CLIENT:
        return [KOMIRA_FIELD_SCOPE, KOMIRA_FIELD_TOKEN_URL]
    return List[Int32]()


def _has(fields: List[Int32], field: Int32) -> Bool:
    for i in range(len(fields)):
        if fields[i] == field:
            return True
    return False


def _valid_name(name: String) -> Bool:
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > CREDENTIAL_NAME_MAX_BYTES:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
        )
        if not ok:
            return False
    return True


def _refuse(operation: String, reason: String) -> Error:
    return Error(String(CREDENTIALS_INVALID) + ": " + operation + ": " + reason)


def _secret_ref(name: String, field: Int32) -> String:
    """Where the value of one field of a sealed credential is held."""
    return name + "/" + String(field)


struct _Definition(Movable, Deinitable):
    """An open definition: its id, kind and name, and the fields set so far.
    Its values are wiped when it is dropped."""

    var id: Int32
    var kind: Int32
    var name: String
    var fields: List[Int32]
    var values: List[List[UInt8]]

    def __init__(out self, id: Int32, kind: Int32, var name: String):
        self.id = id
        self.kind = kind
        self.name = name^
        self.fields = List[Int32]()
        self.values = List[List[UInt8]]()

    def find(self, field: Int32) -> Int:
        for i in range(len(self.fields)):
            if self.fields[i] == field:
                return i
        return -1

    def __deinit__(deinit self):
        for i in range(len(self.values)):
            zeroize_list(self.values[i])


struct _Sealed(Copyable, Movable):
    """A sealed credential: its name, kind, generation and the fields it
    holds. The values are in the store."""

    var name: String
    var kind: Int32
    var generation: Int
    var fields: List[Int32]

    def __init__(
        out self, var name: String, kind: Int32, generation: Int, var fields: List[Int32]
    ):
        self.name = name^
        self.kind = kind
        self.generation = generation
        self.fields = fields^


struct SessionCredentials(Movable):
    """The credentials of one session: open definitions, sealed values by
    name, and the store and bindings a consumer reads them through."""

    var _store: SessionSecretStore
    var _bindings: SecretBindings
    # The node id bound to each `secret_ref` (`name/field`), given the first
    # time that field of that name is sealed and kept after.
    var _node_refs: List[String]
    var _node_ids: List[Int]
    var _open: List[_Definition]
    var _sealed: List[_Sealed]
    var _next_id: Int32
    var _next_node: Int
    var _next_generation: Int

    def __init__(out self):
        """No credential and no open definition."""
        self._store = SessionSecretStore()
        self._bindings = SecretBindings()
        self._node_refs = List[String]()
        self._node_ids = List[Int]()
        self._open = List[_Definition]()
        self._sealed = List[_Sealed]()
        self._next_id = 1
        self._next_node = 1
        self._next_generation = 1

    # ---- the three steps ---------------------------------------------------

    def add(mut self, kind: Int32, name: String) raises -> Int32:
        """Open a definition of `name` with `kind` and return its id (ids
        count up from 1 on each session, and an id is an `Int32`: a session
        opens fewer than 2^31 definitions).

        Raises:
            `CREDENTIALS_INVALID` when `kind` is not a `KOMIRA_CRED_*` kind,
            `name` is not 1 to 128 bytes of letters, digits, `_`, `.` and `-`,
            or `name` is `ambient` or `anonymous` in any case.
        """
        var op = String("add credential")
        if kind_label(kind) == "":
            raise _refuse(op, "kind " + String(kind) + " is not a KOMIRA_CRED_* kind")
        if not _valid_name(name):
            raise _refuse(
                op,
                "the name is not 1 to 128 bytes of letters, digits, '_', '.'"
                " and '-'",
            )
        var lower = name.lower()
        if lower == "ambient" or lower == "anonymous":
            raise _refuse(op, "ambient and anonymous are built in and are not defined")
        var id = self._next_id
        self._next_id += 1
        self._open.append(_Definition(id, kind, name.copy()))
        return id

    def set(mut self, id: Int32, field: Int32, value: Span[UInt8, _]) raises:
        """Set `field` of the open definition `id` to a copy of `value`,
        made only once `value` is admitted (the caller's bytes are read in
        place and never copied when the call refuses). Setting a field again
        replaces its value, wiping the one it replaces.

        Raises:
            `CREDENTIALS_INVALID` when `id` is not open, `field` is not a
            `KOMIRA_FIELD_*` field of the definition's kind, or `value` is
            empty, longer than `MAX_SECRET_LEN` (4096) bytes or not UTF-8.
            A refusal of an open id discards that definition.
        """
        var at = self._find_open(id)
        if at < 0:
            raise _refuse("set credential", "id " + String(id) + " is not an open definition")
        var op = "set credential=" + self._open[at].name
        var kind = self._open[at].kind
        var label = field_label(field)
        var reason = String("")
        if label == "":
            reason = "field " + String(field) + " is not a KOMIRA_FIELD_* field"
        elif not _has(required_fields(kind), field) and not _has(optional_fields(kind), field):
            reason = kind_label(kind) + " has no " + label
        elif len(value) == 0:
            reason = label + " is empty"
        elif len(value) > MAX_SECRET_LEN:
            reason = label + " is longer than " + String(MAX_SECRET_LEN) + " bytes"
        else:
            try:
                _ = StringSlice(from_utf8=value)
            except:
                reason = label + " is not UTF-8"
        if reason != "":
            _ = self._open.pop(at)
            raise _refuse(op, reason)
        var copy = List[UInt8](capacity=len(value))
        copy.extend(value)
        var slot = self._open[at].find(field)
        if slot >= 0:
            zeroize_list(self._open[at].values[slot])
            self._open[at].values[slot] = copy^
        else:
            self._open[at].fields.append(field)
            self._open[at].values.append(copy^)

    def seal(mut self, id: Int32, scope: Int32) raises:
        """Make the open definition `id` the session's value of its name and
        close `id`. A name that already holds a byte-equal value of the same
        kind keeps its generation; any other value takes the next one and
        replaces the old value, whose fields are wiped.

        Raises:
            `CREDENTIALS_INVALID` when `id` is not open, `scope` is not
            `KOMIRA_BIND_SESSION`, or a field the kind needs is not set (the
            message names the first such field). The definition is discarded.
        """
        var at = self._find_open(id)
        if at < 0:
            raise _refuse("seal credential", "id " + String(id) + " is not an open definition")
        var d = self._open.pop(at)
        var op = "seal credential=" + d.name
        if scope != KOMIRA_BIND_SESSION:
            raise _refuse(op, "scope " + String(scope) + " is not KOMIRA_BIND_SESSION")
        var needed = required_fields(d.kind)
        for i in range(len(needed)):
            if d.find(needed[i]) < 0:
                raise _refuse(op, kind_label(d.kind) + " needs " + field_label(needed[i]))
        var s = self._find_sealed(d.name)
        if s >= 0 and self._same_value(self._sealed[s], d):
            return
        var generation = self._next_generation
        self._next_generation += 1
        if s >= 0:
            var old = self._sealed.pop(s)
            for i in range(len(old.fields)):
                self._store.remove(_secret_ref(old.name, old.fields[i]))
        var fields = List[Int32]()
        for i in range(len(d.fields)):
            var secret_ref = _secret_ref(d.name, d.fields[i])
            var value = List[UInt8]()
            value.extend(Span(d.values[i]))
            self._store.put(secret_ref, value^)
            if self._node_for(secret_ref) < 0:
                var node = self._next_node
                self._next_node += 1
                self._node_refs.append(secret_ref.copy())
                self._node_ids.append(node)
                self._bindings.bind(node, d.name.copy(), secret_ref^)
            fields.append(d.fields[i])
        self._sealed.append(_Sealed(d.name.copy(), d.kind, generation, fields^))

    # ---- what a consumer reads ---------------------------------------------

    def is_sealed(self, name: String) -> Bool:
        """Whether `name` holds a sealed value on this session."""
        return self._find_sealed(name) >= 0

    def kind_of(self, name: String) raises -> Int32:
        """The `KOMIRA_CRED_*` kind of the value sealed under `name`.

        Raises:
            `CREDENTIAL_UNBOUND` when `name` holds no sealed value.
        """
        return self._sealed[self._sealed_or_raise(name)].kind

    def generation_of(self, name: String) raises -> Int:
        """The generation of the value sealed under `name`.

        Raises:
            `CREDENTIAL_UNBOUND` when `name` holds no sealed value.
        """
        return self._sealed[self._sealed_or_raise(name)].generation

    def has_field(self, name: String, field: Int32) raises -> Bool:
        """Whether the value sealed under `name` sets `field` (an optional
        field may be absent).

        Raises:
            `CREDENTIAL_UNBOUND` when `name` holds no sealed value.
        """
        return _has(self._sealed[self._sealed_or_raise(name)].fields, field)

    def node_id_of(self, name: String, field: Int32) raises -> Int:
        """The node id `secret_bindings` binds `field` of the value sealed
        under `name` to: the id of the `SecretCapability` that reveals it.

        Raises:
            `CREDENTIAL_UNBOUND` when `name` holds no sealed value, and
            `CREDENTIALS_INVALID` when that value does not set `field`.
        """
        var s = self._sealed_or_raise(name)
        if not _has(self._sealed[s].fields, field):
            raise _refuse(
                "read credential=" + name,
                kind_label(self._sealed[s].kind) + " has no " + field_label(field),
            )
        return self._node_for(_secret_ref(name, field))

    def secret_bindings(self) -> SecretBindings:
        """A copy of the `(node id, credential name, secret_ref)` bindings of
        every field sealed on this session."""
        return self._bindings.clone()

    def secret_store(self) -> SessionSecretStore:
        """A handle over the session's store, for a reveal to consume."""
        return self._store.share()

    def open_definitions(self) -> Int:
        """How many definitions are open (added, not yet sealed or
        discarded)."""
        return len(self._open)

    # ---- helpers -------------------------------------------------------------

    def _find_open(self, id: Int32) -> Int:
        for i in range(len(self._open)):
            if self._open[i].id == id:
                return i
        return -1

    def _find_sealed(self, name: String) -> Int:
        for i in range(len(self._sealed)):
            if self._sealed[i].name == name:
                return i
        return -1

    def _sealed_or_raise(self, name: String) raises -> Int:
        var s = self._find_sealed(name)
        if s < 0:
            raise Error(
                String(CREDENTIAL_UNBOUND)
                + ": credential="
                + name
                + " has no sealed value on this session"
            )
        return s

    def _node_for(self, secret_ref: String) -> Int:
        for i in range(len(self._node_refs)):
            if self._node_refs[i] == secret_ref:
                return self._node_ids[i]
        return -1

    def _same_value(self, sealed: _Sealed, d: _Definition) -> Bool:
        """Whether `d` is byte for byte the value `sealed` holds: the same
        kind, the same fields, and each field's bytes equal."""
        if sealed.kind != d.kind or len(sealed.fields) != len(d.fields):
            return False
        for i in range(len(d.fields)):
            if not _has(sealed.fields, d.fields[i]):
                return False
            if not self._store.equals(_secret_ref(d.name, d.fields[i]), Span(d.values[i])):
                return False
        return True
