// Imports zr_leaf, which it does not declare: only zr_mid is in its deps, and
// a module sees the modules of its own deps, not theirs.
const leaf = @import("zr_leaf");
pub fn main() void {
    _ = leaf.base();
}
