def deliver(message, attempts: 3)
  attempts.times do |attempt|
    return transport.send(message)
  rescue Transport::Busy
    sleep(2**attempt)
  end
  raise DeliveryFailed, "gave up on #{message.id} after #{attempts} attempts"
end
