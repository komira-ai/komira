// No `extern crate proc_macro;`: the crate is reached through --extern.
use proc_macro::TokenStream;

#[proc_macro]
pub fn answer(_input: TokenStream) -> TokenStream {
    "42u32".parse().unwrap()
}
