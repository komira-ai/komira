# One query of a run: what the runner is told about it and what it records.
# The shape follows `komira_bench_corpus.Query` (suite, id, dataset, text), so
# a corpus query maps field for field; the corpus is not a dependency, because
# the runner has to build without it. The sha256 is computed here from the
# bytes of the text, the same digest the corpus states.

from komira_bench_duckdb import OrderKey
from komira_crypto import hex_lower_array_32, sha256


struct QuerySpec(Copyable, Movable):
    """One benchmark query: `suite` and `id` name it (`key()` is `suite/id`),
    `dataset` names the dataset whose tables it reads, `text` is one SQL
    statement exactly as both engines receive it, and `order_keys` are the
    keys of a top-level ORDER BY (empty when the result has no defined order),
    zero-based over the result columns."""

    var suite: String
    var id: String
    var dataset: String
    var text: String
    var order_keys: List[OrderKey]

    def __init__(
        out self,
        var suite: String,
        var id: String,
        var dataset: String,
        var text: String,
        var order_keys: List[OrderKey] = List[OrderKey](),
    ):
        self.suite = suite^
        self.id = id^
        self.dataset = dataset^
        self.text = text^
        self.order_keys = order_keys^

    def key(self) -> String:
        """`suite/id`, the cell id of the result."""
        return self.suite + String("/") + self.id

    def sha256(self) -> String:
        """The SHA-256 of the bytes of `text` as 64 lowercase hex digits."""
        return hex_lower_array_32(sha256(self.text.as_bytes()))

    def validate(self) raises:
        """Raise unless the query can be a cell: a suite, an id and a
        dataset with no `/` or whitespace, and a non-empty text."""
        _require_word(self.suite, String("suite"))
        _require_word(self.id, String("id"))
        _require_word(self.dataset, String("dataset"))
        if self.text.byte_length() == 0:
            raise Error("query " + self.key() + " has no text")


def _require_word(text: String, what: String) raises:
    var b = text.as_bytes()
    if len(b) == 0:
        raise Error("a query's " + what + " is empty")
    for i in range(len(b)):
        var c = b[i]
        if c <= 0x20 or c == 0x2F or c == 0x5C or c >= 0x7F:
            raise Error("a query's " + what + " '" + text + "' holds a slash, a space or a control character")
