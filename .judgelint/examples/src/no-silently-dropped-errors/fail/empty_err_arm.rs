pub fn notify(client: &Client, message: &Message) {
    match client.send(message) {
        Ok(receipt) => log_receipt(&receipt),
        Err(_) => {}
    }
}
