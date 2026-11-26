const std = @import("std");

test "this test hangs past the step's bound" {
    std.Thread.sleep(240 * std.time.ns_per_s);
}
