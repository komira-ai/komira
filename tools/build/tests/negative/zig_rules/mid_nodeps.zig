// A module that imports zr_leaf without declaring it in its deps.
const leaf = @import("zr_leaf");
pub fn answer() u32 {
    return leaf.base() + 2;
}
