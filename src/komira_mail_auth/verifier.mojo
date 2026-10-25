# The credential-verification seam and an in-memory implementation.

from komira_crypto import constant_time_eq_32, sha256_string


trait MailAuthVerifier(Movable):
    """Verifies a (username, password) pair for SMTP AUTH or IMAP LOGIN. A
    server calls `verify` only on a connection that is already on TLS.

    An implementation must not log the password or put it in an error: the
    Bool is the only value derived from the credential that may leave
    `verify`. It should take the same path for an unknown user as for a wrong
    password."""

    def verify(self, username: String, password: String) -> Bool:
        """True iff `password` is the correct password for `username`."""
        ...


struct InMemoryAuthVerifier(MailAuthVerifier, Copyable, Movable):
    """A user to password table held in memory, for tests and for small
    deployments that configure their users at start.

    The table keeps the SHA-256 digest of each password, not the password. A
    check hashes the presented password and compares the two 32-byte digests
    with `constant_time_eq_32`, so the comparison takes the same time whatever
    the bytes are and wherever they first differ, and a presented password
    that is a prefix of, or longer than, the stored one is refused by the same
    comparison as any other wrong password. An unknown user is compared
    against a fixed decoy digest and refused after the same work.

    What this does not hide: the SHA-256 pass takes time per 64-byte block of
    the presented password, so the length of what the caller sent is visible
    to the caller (it is their own input); the stored password's length and
    bytes take no part in the timing. The username comparison is not constant
    time: a username is not a secret here. A digest of one SHA-256 pass is not
    a password-hashing function, so this table is not a place to keep users
    whose digests could leak."""

    var _users: List[String]
    var _digests: List[Array[UInt8, 32]]
    var _decoy: Array[UInt8, 32]

    def __init__(out self):
        self._users = List[String]()
        self._digests = List[Array[UInt8, 32]]()
        self._decoy = sha256_string(String("komira_mail_auth: unknown user"))

    def add_user(mut self, username: String, password: String):
        """Register `username`. A second call for the same name replaces the
        password."""
        var digest = sha256_string(password)
        for i in range(len(self._users)):
            if self._users[i] == username:
                self._digests[i] = digest^
                return
        self._users.append(username)
        self._digests.append(digest^)

    def verify(self, username: String, password: String) -> Bool:
        var presented = sha256_string(password)
        var found = False
        var index = 0
        for i in range(len(self._users)):
            if self._users[i] == username:
                found = True
                index = i
        var same: Bool
        if found:
            same = constant_time_eq_32(presented, self._digests[index])
        else:
            same = constant_time_eq_32(presented, self._decoy)
        return found and same
