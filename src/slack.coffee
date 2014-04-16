{Robot, Adapter, TextMessage} = require 'hubot'
https       = require 'https'
querystring = require 'querystring'
URL         = require 'url'
irc         = require 'irc'

class Slack extends Adapter
  constructor: (robot) ->
    super robot
    @channelMapping = {}


  ###################################################################
  # Slightly abstract logging, primarily so that it can
  # be easily altered for unit tests.
  ###################################################################
  log: console.log.bind console
  logError: console.error.bind console


  ###################################################################
  # Communicating back to the chat rooms. These are exposed
  # as methods on the argument passed to callbacks from
  # robot.respond, robot.listen, etc.
  ###################################################################
  send: (envelope, strings...) ->
    channel = envelope.reply_to || @channelMapping[envelope.room] || envelope.room

    bot = @robot.brain.userForName(@options.name)
    @log "[API]: BOT #{JSON.stringify(bot)}"

    strings.forEach (str) =>
      str = @escapeHtml str
      args =
        username   : bot.name
        icon_url   : bot.profile.image_48
        channel    : channel
        text       : str
        link_names : @options.link_names if @options?.link_names?

      @log "[api]: POST #{JSON.stringify(args)}"
      @post "/api/chat.postMessage", args, (err, body) =>
        @logError err if err
        @log "[api]: REPLY: #{body}"

  reply: (envelope, strings...) ->
    @log "Sending reply"

    user_name = envelope.user?.name || envelope?.name

    strings.forEach (str) =>
      @send envelope, "#{user_name}: #{str}"

  topic: (params, strings...) ->
    # TODO: Set the topic


  custom: (message, data)->
    channel = message.reply_to || @channelMapping[message.room] || message.room

    bot = @robot.brain.userForName(@options.name)
    @log "[API]: BOT #{JSON.stringify(bot)}"

    attachment =
      text     : @escapeHtml data.text
      fallback : @escapeHtml data.fallback
      pretext  : @escapeHtml data.pretext
      color    : data.color
      fields   : data.fields
    args =
      username    : bot.name
      icon_url    : bot.profile.image_48
      channel     : channel
      attachments : JSON.stringify([attachment])
      link_names  : @options.link_names if @options?.link_names?

    @log "[api]: POST #{JSON.stringify(args)}"
    @post "/api/chat.postMessage", args, (err, body) =>
      @logError err if err
      @log "[api]: REPLY: #{body}"
  ###################################################################
  # HTML helpers.
  ###################################################################
  escapeHtml: (string) ->
    string
      # Escape entities
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')

      # Linkify. We assume that the bot is well-behaved and
      # consistently sending links with the protocol part
      .replace(/((\bhttp)\S+)/g, '<$1>')

  unescapeHtml: (string) ->
    string
      # Unescape entities
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')

      # Convert markup into plain url string.
      .replace(/<((\bhttps?)[^|]+)(\|(.*))+>/g, '$1')
      .replace(/<((\bhttps?)(.*))?>/g, '$1')


  ###################################################################
  # Parsing inputs.
  ###################################################################

  parseOptions: ->
    @options =
      token : process.env.HUBOT_SLACK_TOKEN
      team  : process.env.HUBOT_SLACK_TEAM
      name  : process.env.HUBOT_SLACK_BOTNAME or 'slackbot'
      mode  : process.env.HUBOT_SLACK_CHANNELMODE or 'blacklist'
      channels: process.env.HUBOT_SLACK_CHANNELS?.split(',') or []
      link_names: process.env.HUBOT_SLACK_LINK_NAMES or 0,

    @options.irc =
      host: "#{@options.team}.irc.slack.com"
      user: @options.name
      password: process.env.HUBOT_SLACK_IRC_PASS

  getMessageFromRequest: (req) ->
    # Parse the payload
    hubotMsg = req.param 'text'
    room = req.param 'channel_name'
    mode = @options.mode
    channels = @options.channels

    @unescapeHtml hubotMsg if hubotMsg and (mode is 'blacklist' and room not in channels or mode is 'whitelist' and room in channels)

  getAuthorFromRequest: (req) ->
    # Return an author object
    id       : req.param 'user_id'
    name     : req.param 'user_name'
    reply_to : req.param 'channel_id'
    room     : req.param 'channel_name'

  userFromParams: (params) ->
    # hubot < 2.4.2: params = user
    # hubot >= 2.4.2: params = {user: user, ...}
    user = {}
    if params.user
      user = params.user
    else
      user = params

    if user.room and not user.reply_to
      user.reply_to = user.room

    user
  ###################################################################
  # The star.
  ###################################################################
  run: ->
    self = @
    @parseOptions()

    @log "Slack adapter options:", @options

    return @logError "No services token provided to Hubot" unless @options.token
    return @logError "No team provided to Hubot" unless @options.team
    return @logError "No irc password provided to Hubot" unless @options.irc.password

    @joined = {}

    @robot.on 'slack-attachment', (payload)=>
      @custom(payload.message, payload.content)

    clientOptions=
      userName: @options.irc.user
      realName: @options.irc.user
      password: @options.irc.password
      sasl:     true
      secure:   true
      channels: ['#general']
    @irc = new irc.Client @options.irc.host, @options.irc.user, clientOptions

    @irc.addListener 'registered', () =>
      setInterval(@join_all_channels.bind(this), 20 * 1000)
      setInterval(@load_new_users.bind(this), 60 * 1000)
      @join_all_channels()
      @load_new_users()

    @irc.addListener 'names', (channel, data) =>
      @log "[irc:#{channel}] NAMES: #{JSON.stringify(data)}"

    @irc.addListener 'join', (channel, nick) =>
      @log "[irc:#{channel}] JOIN: #{nick}"

    @irc.addListener 'part', (channel, nick, reason) =>
      @log "[irc:#{channel}] PART: #{nick} (#{reason})"

    @irc.addListener 'notice', (nick, to, text) =>
      data = {nick: nick, to: to, text: text}
      @log "[irc] NOTICE: #{JSON.stringify(data)}"

    @irc.addListener 'invite', (channel, from) =>
      data = {channel: channel, from: from}
      @log "[irc] INVITE: #{JSON.stringify(data)}"

    @irc.addListener 'channellist', (list) =>
      for channel in list
        unless @joined[channel]
          @log "[irc] joining: #{channel.name}"
          @irc.join(channel.name)
          @joined[channel] = true

    @irc.addListener 'message#', (from, channel, message) =>
      return unless from and channel
      @log "[irc:#{channel}] #{from}: #{message}"
      author = self.robot.brain.userForName from
      author.room = channel
      if message and author
        self.receive new TextMessage(author, message)

    @irc.addListener 'pm', (from, message) =>
      return unless from
      @log "[irc] #{from}: #{message}"
      author = self.robot.brain.userForName from

      # @log "pm: #{JSON.stringify(author)}"
      if message and author
        @get "/api/im.list", (err, data) =>
          return @logError err if err
          data = JSON.parse(data)
          for im in data.ims
            if im.user == author.id
              author.private  = true
              author.reply_to = im.id
              author.room     = "@#{author.name}"
              self.receive new TextMessage(author, message)


    # Provide our name to Hubot
    self.robot.name = @options.name

    # Tell Hubot we're connected so it can load scripts
    @log "Successfully 'connected' as", self.robot.name
    self.emit "connected"


  join_all_channels: () ->
    @irc.list()

  load_new_users: () ->
    @get "/api/users.list", (err, data) =>
      return @logError err if err?
      data = JSON.parse(data)
      for user in data.members
        @robot.brain.userForId user.id, user

  ###################################################################
  # Convenience HTTP Methods for sending data back to slack.
  ###################################################################
  get: (path, callback) ->
    @request "GET", path, null, callback

  post: (path, params, callback) ->
    @request "POST", path, params, callback

  request: (method, path, params, callback) ->
    self = @

    path += "?token=#{@options.token}"

    host = "#{@options.team}.slack.com"
    headers =
      Host: host

    reqOptions =
      agent    : false
      hostname : host
      port     : 443
      path     : path
      method   : method
      headers  : headers

    post_data = null
    if method is "POST"
      post_data = querystring.stringify(params)
      reqOptions.headers["Content-Type"] = 'application/x-www-form-urlencoded'
      reqOptions.headers["Content-Length"] = post_data.length

    request = https.request reqOptions, (response) ->
      data = ""
      response.on "data", (chunk) ->
        data += chunk

      response.on "end", ->
        if response.statusCode >= 400
          self.logError "Slack services error: #{response.statusCode}"
          self.logError data

        #console.log "HTTPS response:", data
        callback? null, data

        response.on "error", (err) ->
          self.logError "HTTPS response error:", err
          callback? err, null


    request.write(post_data) if post_data
    request.end()

    request.on "error", (err) ->
      self.logError "HTTPS request error:", err
      self.logError err.stack
      callback? err


###################################################################
# Exports to handle actual usage and unit testing.
###################################################################
exports.use = (robot) ->
  new Slack robot

# Export class for unit tests
exports.Slack = Slack
