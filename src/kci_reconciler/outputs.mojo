# =============================================================================
# kci_reconciler/outputs.mojo — APPLY-TIME VALUE FLOW between nodes.
# =============================================================================
#
# A node may PRODUCE named values once it exists (a URL, a host, an address, a
# name) and may CONSUME values other nodes produce (an env var holding another
# node's address). This file holds the three neutral value types that carry
# them; the verbs are on `Resource` (`input_refs`, `bind_inputs`, `outputs`)
# and the ordering and binding are in `graph.topo_sort` and the engine.
#
#   * `Outputs`        — what one node produced: name -> value, as strings.
#   * `InputRef`       — one value a node consumes: WHICH node produces it, WHICH
#                        output, and the consumer's field it lands in (for the
#                        refusal text only).
#   * `ResolvedInputs` — the values the engine resolved for one node's refs,
#                        handed to `bind_inputs` before the node is read.
#
# THE ENGINE NAMES NO VOCABULARY. An output name is an opaque string to this
# package; which names a resource type exposes is the catalog's business, and a
# lowering turns a catalog reference into an `InputRef` with that name.
#
# ⛔ AN UNRESOLVED VALUE IS NEVER A PLACEHOLDER. A node whose desired state
# still holds an unresolved reference cannot have a desired digest: a digest
# over a placeholder can never equal a live digest, so every plan would read as
# drift, or worse, a placeholder would be deployed. `unbound_error` is the one
# spelling of that refusal; a conformer's `desired_digest` raises it rather
# than hash an unbound field.
# =============================================================================


comptime UNBOUND_TOKEN = "UNBOUND"
"""The first word of every unresolved-reference refusal, so a caller can tell
"this value was never resolved" from a backend fault without parsing prose."""


struct Outputs(Copyable, Movable, Deinitable):
    """The named values one node produced, in the order they were first set.

    Names are unique: `set` on an existing name replaces its value. Flat
    parallel lists, no pointer field."""

    var _names: List[String]
    var _values: List[String]

    def __init__(out self):
        self._names = List[String]()
        self._values = List[String]()

    def __init__(out self, *, copy: Self):
        # Explicit: a synthesized copy of a struct holding Lists of Strings is
        # not something a value carried in a List may rely on.
        self._names = copy._names.copy()
        self._values = copy._values.copy()

    def set(mut self, name: String, value: String):
        for i in range(len(self._names)):
            if self._names[i] == name:
                self._values[i] = value
                return
        self._names.append(name)
        self._values.append(value)

    def get(self, name: String) -> Optional[String]:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._values[i]
        return None

    def count(self) -> Int:
        return len(self._names)

    def name_at(self, i: Int) -> String:
        return self._names[i]

    def value_at(self, i: Int) -> String:
        return self._values[i]


struct InputRef(Copyable, Movable, Deinitable):
    """One value a node consumes.

      * `producer` — the logical id of the node that produces it. It is a graph
                     EDGE: `topo_sort` orders the producer first, and a producer
                     that is not in the graph is refused.
      * `output`   — the output name, as the producer's `outputs` reports it.
      * `field`    — where the value lands in the consumer (for example
                     `service.env.JOBS_ADDR`). Used only in refusal text, so an
                     operator is told which line of their file is unresolved."""

    var producer: String
    var output: String
    var field: String

    def __init__(out self, producer: String, output: String, field: String):
        self.producer = producer
        self.output = output
        self.field = field

    def __init__(out self, *, copy: Self):
        self.producer = copy.producer.copy()
        self.output = copy.output.copy()
        self.field = copy.field.copy()


struct ResolvedInputs(Copyable, Movable, Deinitable):
    """The values the engine resolved for ONE node's `input_refs`, one per ref,
    in the order the node declared them. Handed to `bind_inputs`."""

    var _refs: List[InputRef]
    var _values: List[String]

    def __init__(out self):
        self._refs = List[InputRef]()
        self._values = List[String]()

    def __init__(out self, *, copy: Self):
        self._refs = copy._refs.copy()
        self._values = copy._values.copy()

    def add(mut self, ref_: InputRef, value: String):
        self._refs.append(ref_.copy())
        self._values.append(value)

    def count(self) -> Int:
        return len(self._refs)

    def ref_at(self, i: Int) -> InputRef:
        return self._refs[i].copy()

    def value_at(self, i: Int) -> String:
        return self._values[i]

    def value_of(self, consumer: String, producer: String, output: String) raises -> String:
        """The resolved value of `producer`'s `output`; raises the UNBOUND
        refusal, naming `consumer`, when it was not resolved."""
        for i in range(len(self._refs)):
            if self._refs[i].producer == producer and self._refs[i].output == output:
                return self._values[i]
        raise unbound_error(consumer, InputRef(producer, output, String("")))


def unbound_error(consumer: String, ref_: InputRef) -> Error:
    """The one spelling of "this reference has no resolved value"."""
    var where = String("")
    if ref_.field.byte_length() > 0:
        where = String(" (field ") + ref_.field + String(")")
    return Error(
        String(UNBOUND_TOKEN)
        + String(": node '")
        + consumer
        + String("'")
        + where
        + String(" reads output '")
        + ref_.output
        + String("' of '")
        + ref_.producer
        + String(
            "', which has no resolved value. A desired state that holds an"
            " unresolved reference has no digest; it is refused rather than"
            " hashed or deployed with a placeholder."
        )
    )
