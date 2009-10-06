#++
#
# :title: Facebook news feed plugin for rbot
#
# Author:: Matthew M. Boedicker <matthewm@boedicker.org>
#
# Copyright:: (C) 2009 Matthew M. Boedicker
#
# License:: GPL v3
#
# Version:: 0.1
#
# Puts updates to your Facebook news feed in a channel.
# 
# Intended for use on a private personal IRC server, otherwise it is a
# violation of your Facebook friends' privacy.
#
# Currently requires setup process including creating a Facebook app,
# giving it some permissions for your Facebook user, and creating an
# infinite session. This will be documented soon.
#
# See: http://blog.jylin.com/2009/10/01/loading-wall-posts-using-facebookstream_get/
#
# Parameters must be hardcoded in @users but will soon be settable through the bot.
# Does not do any automatic updating until it's better tested. Must be
# manually updated with "@facebook update".

require 'rubygems'
require 'json'

require 'cgi'
require 'digest/md5'
require 'uri'

module FbIrcBot

  module Said

    def when_s
      whenn.strftime('%a %b %e %I:%M%p')
    end

    def strip_html(s)
      (s ? CGI::unescapeHTML(s.gsub(/\s*<\/?.*?>\s*/, ' ')).strip : '')
    end

    attr_reader :who
    attr_reader :whenn
    attr_reader :what
  end

  class Post
    include Said

    def initialize(d)
      @who, @whenn = d['actor_id'], Time.at(d['created_time'])
      @what = d['message'] + strip_html(d['attachment']['description'])

      @comments = d['comments']['comment_list'].to_a.collect { |c| Comment.new(c) }
      @updated = Time.at(d['updated_time'])
    end

    attr_reader :comments
    attr_reader :updated
  end

  class Comment
    include Said

    def initialize(d)
      @who, @whenn, @what = d['fromid'], Time.at(d['time']), d['text']
    end
  end

  class FbRestUrl

    def initialize(secret, query)
      @secret = secret
      @query = query
    end

    def sig
      Digest::MD5.hexdigest(
        @query.sort.collect { |k,v| "#{k}=#{v}" }.join + @secret)
    end

    def to_s
      q = @query.merge('sig' => sig).collect { |k,v| "#{URI.escape(k)}=#{URI.escape(v)}" }.join('&')
      "http://api.facebook.com/restserver.php?#{q}"
    end

  end

end

class FbIrcPlugin < Plugin

  def initialize
    super
    @users = [{
      :api_key => '',
      :session_secret => '',
      :session_key => '', # must be an infinite session
      :user_id => '', # numeric id of the Facebook user whose stream to view

      :nick => '', # nickname of the user whose Facebook news it is
      :last_update => Time.at(0),
      }]
  end

  def poll_start
    @timer = @bot.timer.add(600) { update }
  end

  def poll_stop
    @bot.timer.remove(@timer) unless @timer.nil?
  end

  def update(m, params)
    @users.each do |u|
      url = FbIrcBot::FbRestUrl.new(u[:session_secret],
        'api_key' => u[:api_key],
        'format' => 'JSON',
        'method' => 'stream.get',
        'session_key' => u[:session_key],
        'viewer_id' => u[:user_id])
      data = @bot.httputil.get(url, :cache => false)
      # looked into sending if modified since header but seems to be ignored
      stream = JSON.parse(data)
      profiles = Hash[*stream['profiles'].collect { |x| [x['id'], x['name']] }.flatten]

      stream['posts'].
        collect { |p| FbIrcBot::Post.new(p) }.
        select { |p| p.updated > u[:last_update] }.each do |post|
        m.reply("#{u[:nick]} facebook: #{profiles[post.who]} (#{post.when_s}): #{post.what}")
        post.comments.each do |comment|
          m.reply("#{u[:nick]} facebook:   \\--> #{profiles[comment.who]} (#{comment.when_s}): #{comment.what}")
        end
      end
      u[:last_update] = Time.now
    end
    true
  end

  def cleanup
    poll_stop
    super
  end

end

plugin = FbIrcPlugin.new

# plugin.map('facebook poll start', :action => 'poll_start')
# plugin.map('facebook poll stop', :action => 'poll_stop')
plugin.map('facebook update', :action => 'update')
