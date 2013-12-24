require 'httpclient'
require 'json'
require 'base64'
require 'open-uri'
require 'v8'

class SteamClient
  def initialize
    @c = HTTPClient.new
    @c.set_cookie_store('./cookie.jar')
  end

  def login(username, password)

    # Check if we need to login. might already have the cookie
    loginpage = @c.get("https://steamcommunity.com/login/home/")
    return true if loginpage.headers["Location"] # attempting to redirect us home

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
      # TODO ensure captcha is handled correctly.

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
end

sm = SteamClient.new 
puts "Enter username:"
username = STDIN.gets.chomp
puts "Enter password:"
password = STDIN.gets.chomp
if sm.login(username, password)
  puts "Logged in"
else
  puts "Failure"
end
puts "Done"
