require './kyubei.rb'

sm = SteamClient.new
unless sm.logged_in?
  puts "Username"
  username = STDIN.gets.chomp
  puts "Password"
  password = STDIN.gets.chomp
end

if sm.login(username, password)
  sm.fetch_wallet_balance
  puts "Logged in"
  puts "Your wallet has: $#{sm.wallet_balance/100.0}"
end


puts "Done"
