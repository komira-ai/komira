// A node --test file that registers no test and exits 0: node_binding_test
// `binding_no_test` must still fail, since nothing was checked.
const nothing = 1 + 1;
if (nothing !== 2) throw new Error('arithmetic');
