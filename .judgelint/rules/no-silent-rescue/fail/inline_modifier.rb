class Webhook
  def notify(event)
    http.post(url, event.to_json) rescue nil
    event.mark_sent!
  end
end
