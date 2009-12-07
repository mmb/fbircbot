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

    attr_reader :who
    attr_reader :whenn
    attr_reader :what
  end

  class Post
    include Said

    def initialize(d)
      @app_id, @comment_count, @permalink, @post_id, @who, @whenn =
        d['app_id'], d['comments']['count'].to_i, d['permalink'], d['post_id'],
        d['actor_id'], Time.at(d['created_time'])
      attachment = d.fetch('attachment', {})

      description = strip_html(attachment['description']) if attachment['description']

      attachment_href = FbIrcBot.strip_fb_tracking(attachment['href'])
      @what = "#{d['message']} #{attachment['name']} #{description} #{attachment_href}".gsub(/\s+/, ' ').strip

      load_comments_from_parsed_json(d['comments']['comment_list'])
      @updated = Time.at(d['updated_time'])
    end

    # to look up app id http://www.facebook.com/apps/application.php?id=
    APPS = {
      2254487659 => 'Facebook for BlackBerry',
      2309869772 => 'Links',
      2915120374 => 'Mobile Web',
      6628568379 => 'Facebook for iPhone',
      10732101402 => 'Ping.fm',
      1394457661837 => 'Facebook Text Message',
    }

    def all_comments_loaded?; comment_count == comments.size; end

    def app
      APPS.fetch(app_id) { |a| "app #{a}" if a }
    end

    def load_comments_from_parsed_json(d, options={})
      @comments = d.to_a.collect { |c| Comment.new(c) }
      @comment_count = comments.size if options[:is_all]
    end

    attr_reader :app_id
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

  MaxCommentsShown = 20

  def initialize
    super
    @users = @registry[:users] ||= {}
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

  def url_base(u)
    {
      'api_key' => u[:api_key],
      'format' => 'JSON',
      'session_key' => u[:session_key],
    }
  end

  def make_profile_url(u, uids, fields=%w{name})
    FbIrcBot::FbRestUrl.new(u[:session_secret],
      url_base(u).merge(
      'method' => 'Users.getInfo',
      'uids' => uids.to_a.join(','),
      'fields' => fields.to_a.join(',')))
  end

  def make_posts_url(u)
    FbIrcBot::FbRestUrl.new(u[:session_secret],
      url_base(u).merge(
      'limit' => '100',
      'method' => 'stream.get',
      'start_time' => u[:last_update].to_i.to_s,
      'viewer_id' => u[:user_id]))
  end

  def make_comments_url(u, post_id)
    FbIrcBot::FbRestUrl.new(u[:session_secret],
      url_base(u).merge(
      'method' => 'stream.getComments',
      'post_id' => post_id))
  end

  def url(m, params)
    nick = params[:nick]
    m.reply(
      if @users.include?(nick)
        "#{nick}: #{make_posts_url(@users[nick])}"
      else
        "Facebook user '#{nick}' not found"
      end)
  end

  def update(m, params)
    @users.each_value do |u|
      data = @bot.httputil.get(make_posts_url(u), :cache => false)
      last_update = Time.now
      # looked into sending if modified since header but seems to be ignored
      stream = JSON.parse(data)

      profiles.merge!(Hash[*stream['profiles'].
        collect { |x| [x['id'], { :name => x['name'], :type => x['type'] }] }.
        flatten])

      stream['posts'].collect { |p| FbIrcBot::Post.new(p) }.each do |post|
        app = post.app ? " (#{post.app})" : ''
        m.reply("#{u[:nick]} facebook: #{profiles[post.who][:name]} (#{post.when_s})#{app}: #{post.what}")
        unless post.all_comments_loaded?
          post.load_comments_from_parsed_json(JSON.parse(@bot.httputil.get(
            make_comments_url(u, post.post_id), :cache => false)),
            :is_all => true)
        end
        comments_shown = 0
        post.comments.each_with_index do |comment, i|
          if comments_shown >= MaxCommentsShown
            m.reply("#{comments_shown} comments shown, see the rest at #{post.permalink}")
            break
          end
          if comment.whenn >= u[:last_update]
            # look up profile name from user id unless already known
            unless profiles.has_key?(comment.who)
              profile_resp = begin
                JSON.parse(@bot.httputil.get(make_profile_url(u, comment.who),
                  :cache => false))
              rescue Exception
                [ { 'name' => comment.who, 'uid' => comment.who  } ]
              end
              profiles.merge!(Hash[*profile_resp.
                collect { |x| [x['uid'], { :name => x['name'],
                  :type => profiles.fetch(x['uid'], {})[:type] }] }.flatten])
            end

            m.reply("#{u[:nick]} facebook:   \\-(#{i + 1}/#{post.comment_count})-> #{profiles[comment.who][:name]} (#{comment.when_s}): #{comment.what}")
            comments_shown += 1
          end
        end
      end
      u[:last_update] = last_update
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

plugin.map('facebook url :nick', :action => 'url')
