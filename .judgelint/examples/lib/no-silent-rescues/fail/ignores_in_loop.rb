def sync_all(accounts)
  accounts.each do |account|
    begin
      account.sync!
    rescue => error
      next
    end
  end
end
