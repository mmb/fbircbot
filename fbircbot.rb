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
# Example session:
#
# @facebook add mmb facebook_id_number api_key infinite_session_key infinite_session_secret
# @facebook list
# @facebook update
#
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
      CGI::unescapeHTML(
        s.gsub(/<\s*\/?(br|div).*?>/, ' ').
        gsub(/<\s*\/?(a|b|small).*?>/, '').
        gsub('&nbsp;', ' '))
    end

    attr_reader :who
    attr_reader :whenn
    attr_reader :what
  end

  class Post
    include Said

    def initialize(d)
      @who, @whenn = d['actor_id'], Time.at(d['created_time'])
      @app_id = d['app_id']
      attachment = d.fetch('attachment', {})
      # Facebook Mobile photo urls
      @photo_url = attachment['href'] if app_id == 1
      @what = "#{d['message']} #{strip_html(attachment['description'] || '')} #{@photo_url}".
        gsub(/\s+/, ' ').strip

      @comments = d['comments']['comment_list'].to_a.collect { |c| Comment.new(c) }
      @updated = Time.at(d['updated_time'])
    end

    attr_reader :app_id
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
    @users = @registry[:users] ||= {}
  end

  def help(plugin, topic="")
    case topic
      when 'update' then
        "facebook update => show updates to Facebook users' news feeds"
      when 'add' then
        'facebook add nick user_id api_key session_key session_secret => add a Facebook user'
      when 'delete' then
        'facebook delete nick => delete a Facebook user'
      when 'list' then
        'facebook list => list known Facebook users'
      when 'url' then
        "facebook url nick => get a Facebook user's news stream url"
      else
        "show updates to Facebook users' news feeds: facebook update|add|delete|list|url"
    end
  end

  def add(m, params)
    @users[params[:nick]] = params.merge({ :last_update => Time.at(0) })
    m.reply("added Facebook user #{params[:user_id]} as #{params[:nick]}")
  end

  def delete(m, params)
    user = @users.delete(params[:nick])
    m.reply(
      if user
        "deleted Facebook user #{user[:nick]}"
      else
        "Facebook user '#{params[:nick]}' not found"
      end)
  end

  def list(m, params)
    m.reply("#{@users.size} known Facebook users")
    @users.sort.each { |nick,u| m.reply "#{nick}: user_id = #{u[:user_id]}, api_key = #{u[:api_key]}, session_key = #{u[:session_key]}, session_secret = #{u[:session_secret]}, last_update #{u[:last_update]}" }
  end

  def save
    @registry[:users] = @users
  end

  def poll_start
    @timer = @bot.timer.add(600) { update }
  end

  def poll_stop
    @bot.timer.remove(@timer) unless @timer.nil?
  end

  def make_url(u)
    FbIrcBot::FbRestUrl.new(u[:session_secret],
      'api_key' => u[:api_key],
      'format' => 'JSON',
      'method' => 'stream.get',
      'session_key' => u[:session_key],
      'viewer_id' => u[:user_id])
  end

  def url(m, params)
    nick = params[:nick]
    m.reply(
      if @users.include?(nick)
        "#{nick}: #{make_url(@users[nick])}"
      else
        "Facebook user '#{nick}' not found"
      end)
  end

  def update(m, params)
    @users.each_value do |u|
      data = @bot.httputil.get(make_url(u), :cache => false)
      # looked into sending if modified since header but seems to be ignored
      stream = JSON.parse(data)
      profiles = Hash[*stream['profiles'].collect { |x| [x['id'], x['name']] }.flatten]

      stream['posts'].
        collect { |p| FbIrcBot::Post.new(p) }.
        select { |p| p.updated > u[:last_update] }.each do |post|
        app = post.app_id ? " (app #{post.app_id})" : ''
        m.reply("#{u[:nick]} facebook: #{profiles[post.who]} (#{post.when_s})#{app}: #{post.what}")
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

plugin.map(
  'facebook add :nick :user_id :api_key :session_key :session_secret',
  :action => 'add')
plugin.map('facebook delete :nick', :action => 'delete')
plugin.map('facebook list', :action => 'list')

plugin.map('facebook url :nick', :action => 'url')
