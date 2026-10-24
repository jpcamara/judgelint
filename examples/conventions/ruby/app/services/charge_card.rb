class ChargeCard
  def call(order)
    charge = gateway.charge(order.total_cents, order.card_token)
    order.update!(charge_id: charge.id)
    Result.success(charge)
  rescue Gateway::CardDeclined
    Result.failure(:declined)
  rescue Gateway::Error => e
    Rails.logger.error("charge failed for order #{order.id}: #{e.message}")
    false
  end
end
