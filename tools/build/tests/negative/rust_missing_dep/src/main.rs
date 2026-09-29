use prost::Message;

#[derive(Clone, PartialEq, Message)]
struct Empty {}

fn main() {
    println!("{}", Empty {}.encoded_len());
}
