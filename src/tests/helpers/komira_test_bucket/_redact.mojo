# =============================================================================
# komira_test_bucket/_redact.mojo -- the second line of defence that keeps a
# configured value out of every message this package reports. Package-private.
# =============================================================================
#
# The first line is the client contract (messages name the operation and the
# HTTP status only). This one does not trust it: every client error that
# reaches a verdict or a raised message passes through `_Redactor.scrub`,
# which replaces the configured endpoint (whole, without its scheme, as
# host:port and as the bare host), the bucket and the credentials-file path
# with the NAME of the field that holds them.
#
# Very short values (under 4 bytes) are left alone: replacing every "s3" in a
# message would garble it, and a value that short identifies nothing.
# =============================================================================


struct _Redactor(Copyable, Movable):
    var needles: List[String]
    var names: List[String]

    def __init__(out self, endpoint: String, bucket: String, credentials_file: String):
        self.needles = List[String]()
        self.names = List[String]()
        var ep = String("<object_store.endpoint>")
        self._add(endpoint, ep)
        var rest = endpoint
        if rest.startswith("https://"):
            var cut = String(rest[byte=8:])
            rest = cut^
        elif rest.startswith("http://"):
            var cut = String(rest[byte=7:])
            rest = cut^
        while rest.endswith("/"):
            var cut = String(rest[byte = 0 : rest.byte_length() - 1])
            rest = cut^
        self._add(rest, ep)
        var slash = rest.find("/")
        var hostport = rest if slash < 0 else String(rest[byte=0:slash])
        self._add(hostport, ep)
        var colon = hostport.find(":")
        if colon > 0:
            self._add(String(hostport[byte=0:colon]), ep)
        self._add(credentials_file, String("<object_store.credentials_file>"))
        self._add(bucket, String("<object_store.bucket>"))

    def _add(mut self, needle: String, name: String):
        if needle.byte_length() < 4:
            return
        for n in self.needles:
            if n == needle:
                return
        self.needles.append(needle)
        self.names.append(name)

    def scrub(self, message: String) -> String:
        var out = message
        for i in range(len(self.needles)):
            out = out.replace(self.needles[i], self.names[i])
        return out^
