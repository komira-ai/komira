# =============================================================================
# komira_git_protocol_conformance/graph.mojo -- a scenario's server repository
# as a komira_git CommitGraph, from what git listed (objects.txt, parents.txt,
# tags.txt).
# =============================================================================

from std.collections import Dict

from komira_git import CommitGraph, ObjectFormat, ObjectId


struct TranscriptGraph(CommitGraph, Movable):
    """Objects by hex id: their type, a commit's parents, a tag's target."""

    var types: Dict[String, String]
    var parent_lists: Dict[String, List[String]]
    var targets: Dict[String, String]

    def __init__(
        out self, objects: List[String], parents: List[String], tags: List[String]
    ) raises:
        self.types = Dict[String, String]()
        self.parent_lists = Dict[String, List[String]]()
        self.targets = Dict[String, String]()
        for i in range(len(objects)):
            var f = objects[i].split(" ")
            self.types[String(f[0])] = String(f[1])
        for i in range(len(parents)):
            var f = parents[i].split(" ")
            var ps = List[String]()
            for j in range(1, len(f)):
                ps.append(String(f[j]))
            self.parent_lists[String(f[0])] = ps^
        for i in range(len(tags)):
            var f = tags[i].split(" ")
            self.targets[String(f[0])] = String(f[1])

    def has_object(self, id: ObjectId) -> Bool:
        return id.to_hex() in self.types

    def is_commit(self, id: ObjectId) -> Bool:
        try:
            return self.types[id.to_hex()] == "commit"
        except e:
            return False

    def parents(self, id: ObjectId) raises -> List[ObjectId]:
        var out = List[ObjectId]()
        var hex = id.to_hex()
        if hex not in self.parent_lists:
            return out^
        ref ps = self.parent_lists[hex]
        for i in range(len(ps)):
            out.append(ObjectId.parse_hex(ObjectFormat.sha1(), ps[i]))
        return out^

    def peel(self, id: ObjectId) raises -> ObjectId:
        var hex = id.to_hex()
        while hex in self.targets:
            hex = self.targets[hex]
        return ObjectId.parse_hex(ObjectFormat.sha1(), hex)

    def descends_from(self, child: ObjectId, ancestor: ObjectId) raises -> Bool:
        """True when `ancestor` is `child` or reachable from it by parents."""
        var want = ancestor.to_hex()
        var stack = List[String]()
        stack.append(child.to_hex())
        var seen = Dict[String, Bool]()
        while len(stack) > 0:
            var c = stack.pop()
            if c == want:
                return True
            if c in seen or c not in self.parent_lists:
                continue
            seen[c] = True
            ref ps = self.parent_lists[c]
            for i in range(len(ps)):
                stack.append(ps[i])
        return False
