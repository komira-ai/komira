# The values of the corpus: one query, and a suite of queries.

from .sha256 import sha256_hex


struct Query(Copyable, Movable):
    """One benchmark query.

    `suite` and `id` name it (`key()` is `suite/id`, such as `tpch/q1`).
    `dataset` names the `Dataset` whose tables it reads. `text` is one SQL
    statement with no terminating semicolon and no trailing newline, with every
    parameter already substituted; `sha256()` is the digest of exactly those
    bytes."""

    var suite: String
    var id: String
    var dataset: String
    var text: String

    def __init__(
        out self,
        var suite: String,
        var id: String,
        var dataset: String,
        var text: String,
    ):
        self.suite = suite^
        self.id = id^
        self.dataset = dataset^
        self.text = text^

    def key(self) -> String:
        """`suite/id`, the name a result file and a report use."""
        return self.suite + "/" + self.id

    def sha256(self) -> String:
        """The SHA-256 of `text`, as 64 lowercase hex digits."""
        return sha256_hex(self.text)


struct Suite(Copyable, Movable):
    """An ordered list of queries that are reported together.

    `notice` is the sentence a report of this suite must carry (empty when the
    suite needs none)."""

    var id: String
    var title: String
    var notice: String
    var queries: List[Query]

    def __init__(
        out self,
        var id: String,
        var title: String,
        var notice: String,
        var queries: List[Query],
    ):
        self.id = id^
        self.title = title^
        self.notice = notice^
        self.queries = queries^

    def query(self, query_id: String) raises -> Query:
        """The query of this suite with that id; raises when there is none."""
        for i in range(len(self.queries)):
            if self.queries[i].id == query_id:
                return self.queries[i].copy()
        raise Error(
            "komira_bench_corpus: suite " + self.id + " has no query " + query_id
        )

    def sha256(self) -> String:
        """The digest of the suite: SHA-256 of one line per query, in order,
        `<suite>/<id> <query sha256>` and a newline. An edit to a query, a
        reordering, an added or a removed query changes it."""
        var listing = String("")
        for i in range(len(self.queries)):
            listing += self.queries[i].key()
            listing += " "
            listing += self.queries[i].sha256()
            listing += "\n"
        return sha256_hex(listing)
