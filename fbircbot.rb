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
      whenn.strftime(
        if whenn.day == Time.now.day
          '%l:%M%P'
        elsif whenn.year == Time.now.year
          '%a %b %e %l:%M%P'
        else
          '%a %b %e %Y %l:%M%P'
        end).strip.gsub(/\s+/, ' ')
    end

    def strip_html(s)
      CGI::unescapeHTML(
        s.gsub(/<\s*\/?(br|div).*?>/, ' ').
        gsub(/<\s*\/?(a|b|small).*?>/, '').
        gsub('&nbsp;', ' '))
    end

    module_function :strip_html

    attr_reader :who
    attr_reader :whenn
    attr_reader :what
  end

  class Post
    include Said

    include Comparable

    def initialize(d)
      @attribution, @comment_count, @permalink, @post_id, @who, @whenn =
        d['attribution'], d['comments']['count'].to_i, d['permalink'],
        d['post_id'], d['actor_id'], Time.at(d['created_time'])
      @what = "#{d['message']} #{Post.format_attachment(d['attachment'])}".gsub(/\s+/, ' ').strip

      load_comments_from_parsed_json(d['comments']['comment_list'])
      @updated = Time.at(d['updated_time'])
    end

    def all_comments_loaded?; comment_count == comments.size; end

    def load_comments_from_parsed_json(d, options={})
      @comments = d.to_a.collect { |c| Comment.new(c) }
      @comment_count = comments.size if options[:is_all]
    end

    def <=>(other); updated <=> other.updated; end

    def self.format_attachment(attachment)
      parts = []

      if attachment
        parts.push(attachment['name'], attachment['caption'],
          attachment['description'])
        attachment_href = FbIrcBot.strip_fb_tracking(attachment['href'])
        parts << attachment_href if attachment_href != 'http://www.facebook.com/'
        attachment.fetch('media', []).each do |media|
          href = FbIrcBot.strip_fb_tracking(media['href'])
          if href and href != attachment_href
            parts.push(media['type'], media['alt'], href)
          end
        end
      end
      parts.join(' ')
    end

    attr_reader :attribution
    attr_reader :comment_count
    attr_reader :comments
    attr_reader :permalink
    attr_reader :post_id
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

  class User

    include Comparable

    def initialize(d)
      @api_key = d[:api_key]
      @ignore_friends = d[:ignore_friends] || {}
      @ignore_apps = d[:ignore_apps] || {}
      @last_update = d[:last_update] || Time.now - 86400
      @nick = d[:nick]
      @session_key = d[:session_key]
      @session_secret = d[:session_secret]
      @user_id = d[:user_id]
    end

    def posts_url
      FbIrcBot::FbRestUrl.new(session_secret, url_base.merge(
        'method' => 'stream.get',       
        'viewer_id' => user_id))
    end

    def comments_url(post_id)
      FbIrcBot::FbRestUrl.new(session_secret,
        url_base.merge(
        'method' => 'stream.getComments',
        'post_id' => post_id))
    end

    def profiles_url(uids, fields=%w{name})
      FbIrcBot::FbRestUrl.new(session_secret,
        url_base.merge(
        'method' => 'Users.getInfo',
        'uids' => uids.to_a.join(','),
        'fields' => fields.to_a.join(',')))
    end

    def ignore_app(app); @ignore_apps[app.strip] = true; end

    def unignore_app(app); @ignore_apps.delete(app); end

    def ignore_app_list; @ignore_apps.keys.sort; end

    def ignoring_app?(app)
      app and !app.empty? and @ignore_apps.keys.collect { |f| f.downcase }.include?(app.downcase)
    end

    def ignore_friend(friend); @ignore_friends[friend.strip] = true; end

    def unignore_friend(friend); @ignore_friends.delete(friend); end

    def ignore_friend_list; @ignore_friends.keys.sort; end

    def ignoring_friend?(friend)
      @ignore_friends.keys.collect { |f| f.downcase }.include?(friend.downcase)
    end

    def dump
      {
        :api_key => api_key,
        :ignore_friends => @ignore_friends,
        :ignore_apps => @ignore_apps,
        :last_update => last_update,
        :nick => nick,
        :session_key => session_key,
        :session_secret => session_secret,
        :user_id => user_id,
      }
    end

    def inspect
      "#{nick}: user_id = #{user_id}, api_key = #{api_key}, session_key = #{session_key}, session_secret = #{session_secret}, last_update #{last_update}"
    end

    def url_base
      {
        'api_key' => api_key,
        'format' => 'JSON',
        'session_key' => session_key,
      }
    end

    def <=>(other); nick <=> other.nick; end

    attr_accessor :last_update

    attr_reader :api_key
    attr_reader :nick
    attr_reader :user_id
    attr_reader :session_key
    attr_reader :session_secret
  end

  module_function

  # strip Facebook click tracking
  def strip_fb_tracking(url)
    begin
      URI::decode(CGI::parse(URI(url).query)['u'].first)
    rescue Exception
      url
    end
  end

end

class FbIrcPlugin < Plugin

  MaxCommentsShown = 50

  def initialize
    super
    @users = {}
    (@registry[:users] ||= {}).each { |k,v| @users[k] = FbIrcBot::User.new(v) }
    @profiles = {}
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
      when 'ignore' then
        'facebook ignore (app|friend) (add nick (app_name|friend_name)|delete nick (app_name|friend_name)|list nick) => ignore updates from some apps or friends for a Facebook user'
      when 'url' then
        "facebook url nick => get a Facebook user's news stream url"
      else
        "show updates to Facebook users' news feeds: facebook update|add|delete|ignore|list|url"
    end
  end

  def add(m, params)
    @users[params[:nick]] = FbIrcBot::User.new(params)
    m.reply("added Facebook user #{params[:user_id]} as #{params[:nick]}")
  end

  def delete(m, params)
    if (user = get_user(m, params[:nick]))
      @users.delete(user.nick)
      m.reply("deleted Facebook user #{user.nick}")
    end
  end

  def list(m, params)
    m.reply("#{@users.size} known Facebook users")
    @users.values.sort.each { |u| m.reply(u.inspect) }
  end

  def save
    dumped = {}
    @users.each { |k,v| dumped[k] = v.dump  }
    @registry[:users] = dumped
  end

  def poll_start
    @timer = @bot.timer.add(600) { update }
  end

  def poll_stop
    @bot.timer.remove(@timer) unless @timer.nil?
  end

  def get_user(m, nick)
    if @users.include?(nick)
      @users[nick]
    else
      m.reply("Facebook user '#{nick}' not found")
      nil
    end
  end

  def url(m, params)
    if (user = get_user(m, params[:nick]))
      m.reply("#{user.nick}: #{user.posts_url}")
    end
  end

  def ignore_add(m, params)
    if (user = get_user(m, params[:nick]))
      what, name = params[:what].downcase, params[:name].join(' ')
      case what
        when 'app' then user.ignore_app(name)
        when 'friend' then user.ignore_friend(name)
      end
      m.reply("Ignored #{what} #{name} for Facebook user #{user.nick}")
    end
  end

  def ignore_delete(m, params)
    if (user = get_user(m, params[:nick]))
      what, name = params[:what].downcase, params[:name].join(' ')
      case what
        when 'app' then user.unignore_app(name)
        when 'friend' then user.unignore_friend(name)
      end
      m.reply("Unignored #{what} #{name} for Facebook user #{user.nick}")
    end
  end

  def ignore_list(m, params)
    if (user = get_user(m, params[:nick]))
      what = params[:what].downcase
      list = case what
        when 'app' then user.ignore_app_list
        when 'friend' then user.ignore_friend_list
        else []
      end
      m.reply("#{user.nick} is ignoring #{what}s: #{list.join(', ')}")
    end
  end

  def update(m, params)
    @users.each_value do |u|
      data = @bot.httputil.get(u.posts_url, :cache => false)
      last_update = Time.now
      # looked into sending if modified since header but seems to be ignored
      stream = JSON.parse(data)

      profiles.merge!(Hash[*stream['profiles'].
        collect { |x| [x['id'], { :name => x['name'], :type => x['type'] }] }.
        flatten])

      stream['posts'].collect { |p| FbIrcBot::Post.new(p) }.
        select { |p| p.updated >= u.last_update }.
        reject { |p| u.ignoring_app?(p.attribution) or u.ignoring_friend?(profiles[p.who][:name]) }.
        sort.
        each do |post|
        if post.attribution
          attribution = FbIrcBot::Said::strip_html(post.attribution)
          attribution = " (#{attribution})" unless attribution.empty?
        else
          attribution = ''
        end

        m.reply("#{u.nick} Facebook: #{profiles[post.who][:name]} (#{post.when_s})#{attribution}: #{post.what}")
        unless post.all_comments_loaded?
          post.load_comments_from_parsed_json(JSON.parse(@bot.httputil.get(
            u.comments_url(post.post_id), :cache => false)), :is_all => true)
        end

        comments_to_show = []
        comment_indices = []
        post.comments.each_with_index do |comment, i|
          if comments_to_show.size >= MaxCommentsShown
            m.reply("#{comments_to_show.size} comments will be shown, see the rest at #{post.permalink}")
            break
          elsif comment.whenn >= u.last_update
            comments_to_show.push(comment)
            comment_indices.push(i + 1)
          end
        end

        profiles_needed = comments_to_show.collect { |c| c.who }.
          reject { |w| profiles.key?(w) }

        unless profiles_needed.empty?
          begin
            profile_resp = JSON.parse(@bot.httputil.get(u.profiles_url(
              profiles_needed), :cache => false))
            profiles.merge!(Hash[*profile_resp.
              collect { |x| [x['uid'], { :name => x['name'],
              :type => profiles.fetch(x['uid'], {})[:type] }] }.flatten])
          rescue Exception
          end
        end

        comments_to_show.each_with_index do |comment, i|
          who = profiles.fetch(comment.who, { :name => comment.who })[:name]

          m.reply("#{u.nick} Facebook:   \\-(#{comment_indices[i]}/#{post.comment_count})-> #{who} (#{comment.when_s}): #{comment.what}")
        end
      end
      u.last_update = last_update
    end
    true
  end

  def cleanup
    poll_stop
    super
  end

  attr_reader :profiles
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

plugin.map('facebook ignore :what add :nick *name', :action => 'ignore_add')
plugin.map('facebook ignore :what delete :nick *name', :action => 'ignore_delete')
plugin.map('facebook ignore :what list :nick', :action => 'ignore_list')

plugin.map('facebook url :nick', :action => 'url')
