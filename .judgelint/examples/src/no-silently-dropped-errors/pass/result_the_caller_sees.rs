pub enum Outcome {
    Sent(Receipt),
    Failed(String),
}

pub fn notify(client: &Client, message: &Message) -> Outcome {
    match client.send(message) {
        Ok(receipt) => Outcome::Sent(receipt),
        Err(error) => Outcome::Failed(error.to_string()),
    }
}
