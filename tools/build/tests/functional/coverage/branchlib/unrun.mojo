"""A function no run can reach (test 47): `Tag.write_to` is called only when
assert_equal fails, and test_unrun compares two known equal tags, a branch
the compiler folds to never taken. The instrumented link drops the
function (with its profile counters), so the run's profile holds no record
of it, and its `if` is a decision that never ran, both arms unhit."""


struct Tag(Copyable, Equatable, ImplicitlyCopyable, Movable, TrivialRegisterPassable, Writable):
    var value: UInt8

    @always_inline
    def __init__(out self, value: UInt8):
        self.value = value

    @always_inline
    def __eq__(self, other: Tag) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Tag) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self.value < 8:
            writer.write("low")
        else:
            writer.write("high")
