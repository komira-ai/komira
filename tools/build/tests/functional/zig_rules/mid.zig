// A module that imports another module by name: zr_mid declares
// deps = [":zr_leaf"]. Whatever imports zr_mid is given zr_leaf too, and
// sees only zr_mid (it does not declare zr_leaf).
const leaf = @import("zr_leaf");

pub fn answer() u32 {
    return leaf.base() + 2;
}
