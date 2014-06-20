require 'httpclient'
require 'json'
require 'base64'
require 'nokogiri'
require 'open-uri'
require 'v8'

class HTTPClient
  # This is the default_redirect_uri_callback with the https check commented out
  def weak_redirect_uri_callback(uri, res)
    newuri = urify(res.header['location'][0])
    if !http?(newuri) && !https?(newuri)
      newuri = uri + newuri
      warn("could be a relative URI in location header which is not recommended")
      warn("'The field value consists of a single absolute URI' in HTTP spec")
    end
    #if https?(uri) && !https?(newuri)
    #  raise BadResponseError.new("redirecting to non-https resource")
    #end
    puts "redirect to: #{newuri}" if $DEBUG
    newuri
  end
end

class SteamClient
  attr_reader :wallet_balance
  def initialize
    @c = HTTPClient.new({agent_name: "kyubeiclient/1.0 (X11; Linux x86_64)"})
    @c.set_cookie_store('./cookie.jar')
    @c.redirect_uri_callback=@c.method(:weak_redirect_uri_callback)
    @wallet_balance = nil
  end

  def fetch_wallet_balance
    page = Nokogiri::HTML(@c.get_content("https://steamcommunity.com/market/"))
    begin
      @wallet_balance = (page.css("#marketWalletBalanceAmount").text.gsub(/[^\.\d]/,'').to_f * 100).to_i
    rescue
      raise "Must login before getting balance"
    end
  end

  def logged_in?
    loginpage = @c.get("https://steamcommunity.com/login/checkstoredlogin?redirectURL=%2F")
    loginpage.headers["Set-Cookie"] =~ /^steamLogin=(?!deleted)/
  end

  def login(username, password)
    # Check if we need to login. might already have the cookie
    return true if logged_in?

    count = 0
    resp = {
      "success" => false,
      "captcha_needed" => false,
      "emailauth_needed" => false
    }
    begin
      count+=1
      rsaresp = @c.post("https://steamcommunity.com/login/getrsakey/", {
        username: username, 
        donotcache: Time.new.to_i
      })
      rsainfo = JSON.parse(rsaresp.body)
      raise "Invalid login response" unless rsainfo["success"]

      # So, for some reason using normal rsa via ruby fails.
      # rather than figure out exactly why, we use therubyracer to use their rsa
      ctx = V8::Context.new
      ctx["navigator"] = {appname: "Netscape"}
      ctx["mod"] = rsainfo["publickey_mod"]
      ctx["exp"] = rsainfo["publickey_exp"]
      ctx["password"] = password
      open("https://steamcommunity.com/public/javascript/crypto/jsbn.js") do |jsf|
        ctx.eval(jsf.read)
      end
      open("https://steamcommunity.com/public/javascript/crypto/rsa.js") do |jsf|
        ctx.eval(jsf.read)
      end
      encrypted_pass = ctx.eval("RSA.encrypt(password, RSA.getPublicKey(mod, exp))")

      body = {
        password: encrypted_pass,
        username: username,
        emailauth: '',
        loginfriendlyname: '',
        captchagid: -1,
        captcha_text: '',
        emailsteamid: '',
        rsatimestamp: rsainfo["timestamp"],
        remember_login: true,
        donotcache: Time.new.to_i
      }

      if resp["captcha_needed"]
        puts "Please enter the captcha found here: https://steamcommunity.com/public/captcha.php?gid=#{resp["captcha_gid"]}"
        body[:captchagid] = resp["captcha_gid"]
        body[:captcha_text] = STDIN.gets.chomp
      end

      if resp["emailauth_needed"]
        puts "Please enter your steamguard code"
        body[:emailsteamid] = resp["emailsteamid"]
        body[:emailauth] = STDIN.gets.chomp
        puts "Please enter a name to remember this by (required, sorry)"
        body[:loginfriendlyname] = STDIN.gets.chomp
      end

      resp = @c.post("https://steamcommunity.com/login/dologin/", body)
      resp = JSON.parse(resp.body)
      if resp["message"]
        puts "Response message: #{resp["message"]}"
      end
    end until resp["success"] || count == 3
    @c.save_cookie_store
    resp["success"]
  end

  # Url should look like:
  # http://steamcommunity.com/market/listings/xxx/yyyy-item-name
  def market_listings_for(item_url)
    render_url = item_url.sub(/\/$/,'') + '/render/?query=&start=0&count=10'
    begin
      listings = JSON.parse(@c.get_content(render_url))
    rescue
      puts "Error getting listing info"
      return []
    end
    begin
      return listings["listinginfo"].map(&:last).map do |listing|
        {
          id: listing["listingid"],
          price: listing["converted_price"] + listing["converted_fee"],
          base_amount: listing["converted_price"],
          fee_amount: listing["converted_fee"],
          page_url: item_url
        }
      end
    rescue
      puts "Converted price not there. try again"
      return []
    end
  end

  def market_buy(listing)
    id = listing[:id]
    sessionid = URI.decode(@c.cookie_manager.cookies.select{|i| i.match?(URI("https://steamcommunity.com")) && i.name == "sessionid"}.first.value)
    body = {
      sessionid: sessionid,
      currency: 1,
      subtotal: listing[:base_amount],
      fee: listing[:fee_amount],
      total: listing[:price]
    }
    res = @c.post("https://steamcommunity.com/market/buylisting/" + id, body, {Referer: listing[:page_url], Origin: "http://steamcommunity.com"}) rescue nil
    if res.nil?
      puts "Timed out buying"
      return false
    end
    if res.code == 200
      jsres = JSON.parse(res.body)
      if jsres["wallet_info"]["success"] == 1
        @wallet_balance = jsres["wallet_info"]["wallet_balance"]
        return true
      end
    end
    puts JSON.parse(res.body)["message"] rescue
    # See if we need to relog. Any unrecoverable mistakes pretty-much
    exit if JSON.parse(res.body)["message"] =~ "^Cookies" rescue
    false
  end

  # Price in cents
  def market_buy_if_less_than(item_url, price)
    listings = market_listings_for item_url
    listings = listings.sort{|i,j| i[:price] - j[:price]}
    # Pick random cheapest to reduce contention
    cheapest = listings.reject{|i| i[:price] > listings.first[:price]}.sample
    return false if cheapest.nil? || cheapest.length == 0
    if cheapest[:price] < price
      market_buy cheapest
    else
      false
    end
  end

  # url MUST be in a form very close to:
  # http://steamcommunity.com/id/USERID/gamecards/BADGEID
  def craft_badge(badge_page_url)
    appid = badge_page_url.split('/').last
    uid = badge_page_url.split('/')[4]
    # TODO, figure out what the series and border_color parameters mean.
    # for now set them to the observed values of 1,0
    sessionid = URI.decode(@c.cookie_manager.cookies.select{|i| i.match?(URI("https://steamcommunity.com")) && i.name == "sessionid"}.first.value)
    body = {
      appid: appid,
      series: 1,
      border_color: 0,
      sessionid: sessionid
    }
    res = @c.post("http://steamcommunity.com/id/#{uid}/ajaxcraftbadge/", body, {Referer: badge_page_url, Origin: "http://steamcommunity.com"}) rescue nil
    res && res.code == 200
  end

end
