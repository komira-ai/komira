//! Encodes a message with prost, decodes it again, and prints both.

use prost::Message;

#[derive(Clone, PartialEq, Message)]
struct Greeting {
    #[prost(string, tag = "1")]
    text: String,
    #[prost(uint32, tag = "2")]
    count: u32,
}

fn main() {
    let msg = Greeting { text: "hi".to_string(), count: 300 };
    let bytes = msg.encode_to_vec();
    let hex: Vec<String> = bytes.iter().map(|b| format!("{:02x}", b)).collect();
    println!("{}", hex.join(" "));
    let back = Greeting::decode(bytes.as_slice()).expect("decode");
    println!("{} {}", back.text, back.count);
}
