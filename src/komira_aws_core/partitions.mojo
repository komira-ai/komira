# =============================================================================
# komira_aws_core/partitions.mojo -- the AWS partitions, as data
# =============================================================================
#
# `AwsPartitionSet` holds botocore's `botocore/data/partitions.json` (the
# document every AWS SDK ships as its partition table) and answers the
# endpoint ruleset function `aws.partition`. Nothing here names a partition:
# the ids, region lists, region patterns and outputs all come from the
# document the caller passes in, so a new partition is a new document.
#
# The lookup is botocore's `RuleSetStandardLibrary.aws_partition`
# (botocore/endpoint_provider.py): the first partition, in document order,
# that lists the region or whose `regionRegex` matches it; failing both (or
# for an unset region), the first partition. The result is that partition's
# `outputs` object with `name` set to its `id`.
#
# This is a separate table from endpoint.mojo's `aws_partition_for_region`,
# which serves the fixed-shape awsJson endpoints of the generated clients.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue
from komira_json import parse_json_value

from ._regex import Regex


struct _Partition(Copyable, Movable):
    var id: String
    var regions: List[String]
    var region_regex: Regex
    var outputs: JsonValue

    def __init__(
        out self,
        var id: String,
        var regions: List[String],
        var region_regex: Regex,
        var outputs: JsonValue,
    ):
        self.id = id^
        self.regions = regions^
        self.region_regex = region_regex^
        self.outputs = outputs^


def _member(v: JsonValue, key: String, kind: Int, where: String) raises -> Int:
    """The index of member `key` of object `v`, which must be of `kind`."""
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            if v.children[i].kind != kind:
                raise Error(where + ": '" + key + "' has the wrong JSON kind")
            return i
    raise Error(where + ": no '" + key + "'")


struct AwsPartitionSet(Copyable, Movable):
    """The partition table of one partitions.json document."""

    var _partitions: List[_Partition]

    def __init__(out self, partitions_json: String) raises:
        """Parses a partitions.json document (`version` "1.1": a
        `partitions` array of objects with `id`, `regionRegex`, `regions`
        and `outputs`). Raises on any other shape, and on a `regionRegex`
        the matcher does not support."""
        self._partitions = List[_Partition]()
        var doc = parse_json_value(partitions_json)
        if doc.kind != JSON_OBJECT:
            raise Error("partitions.json: the document is not an object")
        var vi = _member(doc, "version", JSON_STRING, "partitions.json")
        if doc.children[vi].text != "1.1":
            raise Error(
                "partitions.json: version '"
                + doc.children[vi].text
                + "' is not 1.1"
            )
        var pi = _member(doc, "partitions", JSON_ARRAY, "partitions.json")
        ref parts = doc.children[pi]
        for k in range(len(parts.children)):
            ref p = parts.children[k]
            var where = "partitions.json: partitions[" + String(k) + "]"
            if p.kind != JSON_OBJECT:
                raise Error(where + " is not an object")
            var id = p.children[_member(p, "id", JSON_STRING, where)].text
            var rx = p.children[
                _member(p, "regionRegex", JSON_STRING, where)
            ].text
            ref regions_obj = p.children[
                _member(p, "regions", JSON_OBJECT, where)
            ]
            var outputs = p.children[
                _member(p, "outputs", JSON_OBJECT, where)
            ].copy()
            var regions = List[String]()
            for r in range(len(regions_obj.obj_keys)):
                regions.append(regions_obj.obj_keys[r])
            # `name` is the partition id, whatever `outputs` says.
            var named = JsonValue.empty_object()
            for o in range(len(outputs.obj_keys)):
                if outputs.obj_keys[o] != "name":
                    named.set_member(
                        outputs.obj_keys[o], outputs.children[o].copy()
                    )
            named.set_member("name", JsonValue.from_string(id))
            self._partitions.append(
                _Partition(id, regions^, Regex(rx), named^)
            )
        if len(self._partitions) == 0:
            raise Error("partitions.json: no partitions")

    def __len__(self) -> Int:
        return len(self._partitions)

    def partition_ids(self) -> List[String]:
        """The partition ids, in document order."""
        var out = List[String]()
        for i in range(len(self._partitions)):
            out.append(self._partitions[i].id)
        return out^

    def _index_for(self, region: String) -> Int:
        for i in range(len(self._partitions)):
            ref p = self._partitions[i]
            for r in range(len(p.regions)):
                if p.regions[r] == region:
                    return i
            if p.region_regex.matches(region):
                return i
        return 0

    def lookup(self, region: String) -> JsonValue:
        """`aws.partition(region)`: the outputs of the region's partition
        (the first partition when none claims it), with `name`."""
        return self._partitions[self._index_for(region)].outputs.copy()

    def default_outputs(self) -> JsonValue:
        """`aws.partition` of an unset region: the first partition's."""
        return self._partitions[0].outputs.copy()
