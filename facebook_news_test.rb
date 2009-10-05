#!/usr/bin/ruby

# fetch a user's facebook news feed

require 'rubygems'
require 'httparty'

require 'digest/md5'
require 'pp'

API_KEY = ''

# infinite session, must previously exist
SESSION_SECRET = ''
SESSION_KEY = ''

USER_ID = ''

class Facebook
  include HTTParty
  base_uri 'http://api.facebook.com/restserver.php'
  format :json

  def self.stream_get(api_key, session_secret, session_key, user_id)
    get('', :query => sign(session_secret,
      'api_key' => api_key,
      'format' => 'JSON',
      'method' => 'stream.get',
      'session_key' => session_key,
      'viewer_id' => user_id
      ))
  end

  def self.sign(secret, q)
    q.merge('sig' => sig(secret, q))
  end

  def self.sig(secret, q)
    Digest::MD5.hexdigest(
      q.sort.collect { |k,v| "#{k}=#{v}" }.join('') + secret)
  end

end

stream = Facebook.stream_get(API_KEY, SESSION_SECRET, SESSION_KEY, USER_ID)

users = Hash[*stream['profiles'].collect { |x| [x['id'], x['name']] }.flatten]

# pp stream['posts']

def render(who, what, level=0)
  "#{'   ' * level}#{who}: #{what}"
end

def strip_html(s)
  (s ? s.gsub(/<\/?.*?>/, ' ').gsub(/\s+/, ' ') : '')
end

stream['posts'].each do |post|
  # pp post
  puts render(users[post['actor_id']], post['message'] + \
    strip_html(post['attachment']['description']))

  post['media'].to_a.each do |media|
    puts render(users[post['actor_id']], media['description'], 1)
  end

  post['comments']['comment_list'].to_a.each do |comment|
    puts render(users[comment['fromid']], comment['text'], 1)
  end

  puts
end
