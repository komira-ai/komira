# =============================================================================
# gcp_store.mojo -- the state of the fake GCP Secret Manager, and its forms
# =============================================================================
#
# Secrets and their versions as Secret Manager v1 keeps them:
#
#   * a secret is global (`projects/*/secrets/*`, replicated, created with
#     a `replication` policy) or regional (`projects/*/locations/*/secrets/*`,
#     created without one); the two are different resources even when their
#     ids are equal;
#   * a version is numbered from 1 within its secret, holds the payload's
#     bytes and their CRC32C (computed here when the client sent none), and
#     `latest` names the highest-numbered one;
#   * every name the fake answers spells the project by its number, as the
#     service does, and a request may name the project by id or number.
#
# Times come from a counter that starts at a fixed instant, so every answer
# is deterministic. JSON forms follow the proto3 JSON mapping: int64 as a
# string, bytes as standard base64, Timestamps in RFC 3339.
# =============================================================================

from komira_encoding import base64_encode
from komira_json import JsonValue

# The project every test addresses, its number, and the one location whose
# regional endpoint the fake serves.
comptime GCP_PROJECT_ID = "demo-project"
comptime GCP_PROJECT_NUMBER = "000000000000"
comptime GCP_REGION = "us-central1"


def crc32c(data: Span[UInt8, _]) -> UInt32:
    """CRC-32C (Castagnoli, reflected polynomial 0x82F63B78), bit by bit:
    the checksum Secret Manager keeps as `dataCrc32c`. The generated client
    has no CRC32C code: it only carries the value its caller sets, so this
    function is checked against published values (test_gcp_secret_lifecycle),
    not against the client."""
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(data)):
        crc ^= UInt32(data[i])
        for _ in range(8):
            if (crc & 1) == 1:
                crc = (crc >> 1) ^ UInt32(0x82F63B78)
            else:
                crc = crc >> 1
    return crc ^ UInt32(0xFFFFFFFF)


def _two(v: Int) -> String:
    return (String("0") if v < 10 else String("")) + String(v)


def rfc3339(tick: Int) -> String:
    """2026-10-01T00:00:00Z plus `tick` seconds (under a day)."""
    var h = tick // 3600
    var m = (tick // 60) % 60
    var s = tick % 60
    return String("2026-10-01T") + _two(h) + ":" + _two(m) + ":" + _two(s) + "Z"


struct GcpVersion(Copyable, Movable):
    var number: Int
    var data: List[UInt8]
    var crc: UInt32
    # Whether the AddSecretVersion that made it carried a dataCrc32c.
    var client_checksum: Bool
    var created: Int

    def __init__(
        out self, number: Int, var data: List[UInt8], client_checksum: Bool, created: Int
    ):
        self.number = number
        self.crc = crc32c(Span(data))
        self.data = data^
        self.client_checksum = client_checksum
        self.created = created


struct GcpSecret(Copyable, Movable):
    var secret_id: String
    # "" for a global secret.
    var location: String
    var created: Int
    var versions: List[GcpVersion]

    def __init__(out self, var secret_id: String, var location: String, created: Int):
        self.secret_id = secret_id^
        self.location = location^
        self.created = created
        self.versions = List[GcpVersion]()

    def name(self) -> String:
        return secret_name(self.location, self.secret_id)

    def version_index(self, version: String) -> Int:
        """The index of the version `version` names (a number or `latest`),
        -1 when there is none."""
        if version == "latest":
            return len(self.versions) - 1
        for i in range(len(self.versions)):
            if String(self.versions[i].number) == version:
                return i
        return -1


def collection_name(location: String) -> String:
    """`projects/<number>`, or `projects/<number>/locations/<location>`."""
    var out = String("projects/") + GCP_PROJECT_NUMBER
    if location.byte_length() > 0:
        out += String("/locations/") + location
    return out^


def secret_name(location: String, secret_id: String) -> String:
    return collection_name(location) + "/secrets/" + secret_id


def _etag(tick: Int) -> String:
    return String('"e2e-') + String(tick) + '"'


def secret_json(s: GcpSecret) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("name"), JsonValue.from_string(s.name()))
    if s.location.byte_length() == 0:
        var rep = JsonValue.empty_object()
        rep.set_member(String("automatic"), JsonValue.empty_object())
        o.set_member(String("replication"), rep^)
    o.set_member(String("createTime"), JsonValue.from_string(rfc3339(s.created)))
    o.set_member(String("etag"), JsonValue.from_string(_etag(s.created)))
    return o^


def version_json(s: GcpSecret, v: GcpVersion) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(
        String("name"),
        JsonValue.from_string(s.name() + "/versions/" + String(v.number)),
    )
    o.set_member(String("createTime"), JsonValue.from_string(rfc3339(v.created)))
    o.set_member(String("state"), JsonValue.from_string(String("ENABLED")))
    if s.location.byte_length() == 0:
        var st = JsonValue.empty_object()
        st.set_member(String("automatic"), JsonValue.empty_object())
        o.set_member(String("replicationStatus"), st^)
    o.set_member(String("etag"), JsonValue.from_string(_etag(v.created)))
    if v.client_checksum:
        o.set_member(String("clientSpecifiedPayloadChecksum"), JsonValue.from_bool(True))
    return o^


def access_json(s: GcpSecret, v: GcpVersion) raises -> JsonValue:
    var payload = JsonValue.empty_object()
    payload.set_member(String("data"), JsonValue.from_string(base64_encode(Span(v.data))))
    payload.set_member(String("dataCrc32c"), JsonValue.from_string(String(Int(v.crc))))
    var o = JsonValue.empty_object()
    o.set_member(
        String("name"),
        JsonValue.from_string(s.name() + "/versions/" + String(v.number)),
    )
    o.set_member(String("payload"), payload^)
    return o^


struct GcpStore(Movable):
    """Every secret, global and regional, in creation order, and the
    clock."""

    var secrets: List[GcpSecret]
    var ticks: Int

    def __init__(out self):
        self.secrets = List[GcpSecret]()
        self.ticks = 0

    def now(mut self) -> Int:
        self.ticks += 1
        return self.ticks

    def find(self, location: String, secret_id: String) -> Int:
        for i in range(len(self.secrets)):
            if (
                self.secrets[i].location == location
                and self.secrets[i].secret_id == secret_id
            ):
                return i
        return -1

    def remove(mut self, index: Int):
        var kept = List[GcpSecret]()
        for i in range(len(self.secrets)):
            if i != index:
                kept.append(self.secrets[i].copy())
        self.secrets = kept^
