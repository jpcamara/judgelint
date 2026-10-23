class ImportRow
  def call(row)
    record = Customer.create!(row.to_h)
    Result.success(record)
  rescue ActiveRecord::RecordInvalid => e
    Result.failure(row: row.number, errors: e.record.errors.full_messages)
  end
end
