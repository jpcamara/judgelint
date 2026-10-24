class SyncInvoicesJob < ApplicationJob
  def perform(account)
    account.invoices.unsynced.each do |invoice|
      begin
        Ledger.push(invoice)
      rescue Ledger::Error
        next
      end
    end
    ReportJob.perform_later(account)
  end
end
