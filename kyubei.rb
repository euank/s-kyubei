require 'httpclient'
require 'json'
require 'rsa'
require 'openssl'
require 'base64'

class SteamClient
  def initialize
    @c = HTTPClient.new
    @c.set_cookie_store('./cookie.jar')
  end

  def login(username, password)
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

      exponent = OpenSSL::BN.new rsainfo["publickey_exp"].to_i(16).to_s
      modulus = OpenSSL::BN.new rsainfo["publickey_mod"].to_i(16).to_s
      key = OpenSSL::PKey::RSA.new
      key.e = exponent
      key.n = modulus
      encrypted_pass = key.public_encrypt(password,OpenSSL::PKey::RSA::PKCS1_PADDING).chomp

      body = {
        password: Base64.encode64(encrypted_pass),
        username: username,
        emailauth: '',
        loginfriendlyname: '',
        captchagid: -1,
        captcha_text: '',
        emailsteamid: '',
        rsatimestamp: rsainfo["timestamp"],
        remember_login: false,
        donotcache: Time.new.to_i
      }

      puts resp.to_s
      if resp["captcha_needed"]
        puts "Please enter the captcha found here: https://steamcommunity.com/public/captcha.php?gid=#{resp["captcha_gid"]}"
        body[:captchagid] = resp["captcha_gid"]
        body[:captcha_text] = STDIN.gets.chomp
      end
      # TODO ensure captcha is handled correctly.

      if resp["emailauth_needed"]
        puts "Please enter your steamguard code"
        body[:emailsteamid] = resp["emailsteamid"]
        body[:emailauth] = STDIN.gets.chomp
        puts "Please enter a name to remember this by (required, sorry)"
        body[:loginfriendlyname] = STDIN.get.chomps
      end

      puts body.to_s

      resp = @c.post("https://steamcommunity.com/login/dologin/", body)
      resp = JSON.parse(resp.body)
      if resp["message"]
        puts "Response message: #{resp["message"]}"
      end
    end until resp["success"] || count == 3
  end
end

sm = SteamClient.new 
puts "Enter username:"
username = STDIN.gets.chomp
puts "Enter password:"
password = STDIN.gets.chomp
sm.login(username, password)
puts "Done"
