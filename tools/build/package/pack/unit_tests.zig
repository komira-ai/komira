// The root of the packer's unit tests (//tools/build/package:komira_pack_unit):
// `zig test` runs the test blocks of the files referenced here.
test {
    _ = @import("deflate_test.zig");
    _ = @import("conda_dlopen.zig");
    _ = @import("conda_lib.zig");
    _ = @import("readme_link.zig");
}
