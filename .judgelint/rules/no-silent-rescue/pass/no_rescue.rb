class Invoice
  def total
    line_items.sum(&:amount) - discount
  end
end
