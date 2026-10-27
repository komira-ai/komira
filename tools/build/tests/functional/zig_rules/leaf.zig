// The innermost module of the chain app -> zr_mid -> zr_leaf: it imports no
// module of its own.
pub fn base() u32 {
    return 40;
}

test "leaf" {
    if (base() != 40) return error.WrongBase;
}
