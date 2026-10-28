use std::thread::sleep;
use std::time::Duration;

pub fn send_with_retries(client: &Client, request: &Request) -> Result<Response, Error> {
    let mut attempt = 0;
    loop {
        match client.send(request) {
            Ok(response) => return Ok(response),
            Err(error) if attempt < 3 && error.is_transient() => {
                attempt += 1;
                sleep(Duration::from_millis(200 * attempt));
            }
            Err(error) => return Err(error),
        }
    }
}
