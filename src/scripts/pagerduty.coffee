# Description:
#   Interact with PagerDuty services, schedules, and incidents with Hubot.
#
# Commands:
#   hubot pager maint <date> <time> <minutes> - schedule a maintenance window for <date> <time> <minutes>
#   hubot who's on call - return a list of services and who is on call for them
#
# Authors:
#   Jesse Newland, Josh Nicols, Jacob Bednarz, Chris Lundquist, Chris Streeter, Joseph Pierri, Greg Hoin, Michael Warkentin

pagerduty = require('../pagerduty')
async = require('async')
inspect = require('util').inspect
moment = require('moment-timezone')

pagerDutyUserId        = process.env.HUBOT_PAGERDUTY_USER_ID
pagerDutyServiceApiKey = process.env.HUBOT_PAGERDUTY_SERVICE_API_KEY
pagerDutyServices      = process.env.HUBOT_PAGERDUTY_SERVICES

module.exports = (robot) ->
  # who is on call?
  robot.respond /who(?:’s|'s|s| is|se)? (?:on call|oncall|on-call)(?:\?)?(?: (?:for )?((["'])([^]*?)\2|(.*?))(?:\?|$))?$/i, (msg) ->
    if pagerduty.missingEnvironmentForApi(msg)
      return

    scheduleName = msg.match[3] or msg.match[4]

    messages = []
    allowed_schedules = []
    if pagerDutySchedules?
      allowed_schedules = pagerDutySchedules.split(",")

    renderSchedule = (s, cb) ->
      withCurrentOncall msg, s, (username, schedule) ->
        # If there is an allowed schedules array, skip returned schedule not in it
        if allowed_schedules.length and schedule.id not in allowed_schedules
          robot.logger.debug "Schedule #{schedule.id} (#{schedule.name}) not in HUBOT_PAGERDUTY_SCHEDULES"
          return cb null

        # Ignore schedule if no user assigned to it 
        if (username)
          messages.push("* #{username} is on call for #{schedule.name} - #{schedule.html_url}")
        else
          robot.logger.debug "No user for schedule #{schedule.name}"

        # Return callback
        cb null

    if scheduleName?
      SchedulesMatching msg, scheduleName, (s) ->
        async.map s, renderSchedule, (err) ->
          if err?
            robot.emit 'error', err, msg
            return
          msg.send messages.join("\n")
    else
      pagerduty.getSchedules (err, schedules) ->
        if err?
          robot.emit 'error', err, msg
          return
        if schedules.length > 0
          async.map schedules, renderSchedule, (err) ->
            if err?
              robot.emit 'error', err, msg
              return
            msg.send messages.join("\n")
        else
          msg.send 'No schedules found!'
          
  robot.respond /(pager|major)( me)? maint (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}) (\d+)?$/i, (msg) ->
    if pagerduty.missingEnvironmentForApi(msg)
      return

    service_ids = pagerDutyServices.split(',')

    year = msg.match[3]
    month = msg.match[4]
    day = msg.match[5]
    hour = msg.match[6]
    minute = msg.match[7]
    minutes = msg.match[8]
    description = "generic window"

    datetime = new Date year + "-" + month + "-" + day + " " + hour + ":" + minute
    start_time = moment(datetime).format()
    end_time = moment(datetime).add(minutes, 'minutes').format()

    services = []
    for service_id in service_ids
      services.push id: service_id, type: 'service_reference'
    
    maintenance_window = { start_time, end_time, description, services }
    data = { maintenance_window, services }

    #jdata = JSON.stringify(maintenance_window)
    #msg.send "#{jdata}"
    msg.send "Opening maintenance window"
    pagerduty.post '/maintenance_windows', data, (err, json) ->
      if err?
        robot.emit 'error', err, msg
        return

      if json && json.maintenance_window
        msg.send "Maintenance window created! ID: #{json.maintenance_window.id} Ends: #{json.maintenance_window.end_time}"
      else
        msg.send "That didn't work. Check Hubot's logs for an error!"

  pagerDutyIntegrationAPI = (msg, cmd, description, cb) ->
    unless pagerDutyServiceApiKey?
      msg.send "PagerDuty API service key is missing."
      msg.send "Ensure that HUBOT_PAGERDUTY_SERVICE_API_KEY is set."
      return

    data = null
    switch cmd
      when "trigger"
        data = JSON.stringify { service_key: pagerDutyServiceApiKey, event_type: "trigger", description: description }
        pagerDutyIntegrationPost msg, data, (json) ->
          cb(json)

  formatIncident = (inc) ->
    summary = inc.title
    assignee = inc.assignments?[0]?['assignee']?['summary']
    if assignee
      assigned_to = "- assigned to #{assignee}"
    else
      ''
    "#{inc.incident_number}: #{inc.created_at} #{summary} #{assigned_to}\n"

  pagerDutyIntegrationPost = (msg, json, cb) ->
    msg.http('https://events.pagerduty.com/generic/2010-04-15/create_event.json')
      .header('content-type', 'application/json')
      .post(json) (err, res, body) ->
        switch res.statusCode
          when 200
            json = JSON.parse(body)
            cb(json)
          else
            console.log res.statusCode
            console.log body

  incidentsByUserId = (incidents, userId) ->
    incidents.filter (incident) ->
      assignments = incident.assignments.map (item) -> item.assignee.id
      assignments.some (assignment) ->
        assignment is userId

  withCurrentOncall = (msg, schedule, cb) ->
    withCurrentOncallUser msg, schedule, (user, s) ->
      if (user)
        cb(user.name, s)
      else
        cb(null, s)

  withCurrentOncallId = (msg, schedule, cb) ->
    withCurrentOncallUser msg, schedule, (user, s) ->
      if (user)
        cb(user.id, user.name, s)
      else
        cb(null, null, s)

  withCurrentOncallUser = (msg, schedule, cb) ->
    oneHour = moment().add(1, 'hours').format()
    now = moment().format()

    scheduleId = schedule.id
    if (schedule instanceof Array && schedule[0])
      scheduleId = schedule[0].id
    unless scheduleId
      msg.send "Unable to retrieve the schedule. Use 'pager schedules' to list all schedules."
      return

    query = {
      since: now,
      until: oneHour,
    }
    pagerduty.get "/schedules/#{scheduleId}/users", query, (err, json) ->
      if err?
        robot.emit 'error', err, msg
        return
      if json.users and json.users.length > 0
        cb(json.users[0], schedule)
      else
        cb(null, schedule)

  SchedulesMatching = (msg, q, cb) ->
    query = {
      query: q
    }
    pagerduty.getSchedules query, (err, schedules) ->
      if err?
        robot.emit 'error', err, msg
        return

      cb(schedules)

  withScheduleMatching = (msg, q, cb) ->
    SchedulesMatching msg, q, (schedules) ->
      if schedules?.length < 1
        msg.send "I couldn't find any schedules matching #{q}"
      else
        cb(schedule) for schedule in schedules
      return

  userEmail = (user) ->
    user.pagerdutyEmail || user.email_address || user.profile?.email || process.env.HUBOT_PAGERDUTY_TEST_EMAIL

  campfireUserToPagerDutyUser = (msg, user, required, cb) ->

    if typeof required is 'function'
      cb = required
      required = true

    ## Determine the email based on the adapter type (v4.0.0+ of the Slack adapter stores it in `profile.email`)
    email = userEmail(user)
    speakerEmail = userEmail(msg.message.user)

    if not email
      if not required
        cb null
        return
      else
        possessive = if email is speakerEmail
                      "your"
                     else
                      "#{user.name}'s"
        addressee = if email is speakerEmail
                      "you"
                    else
                      "#{user.name}"

        msg.send "Sorry, I can't figure out #{possessive} email address :( Can #{addressee} tell me with `#{robot.name} pager me as you@yourdomain.com`?"
        return

    pagerduty.get "/users", { query: email }, (err, json) ->
      if err?
        robot.emit 'error', err, msg
        return

      if json.users.length isnt 1
        if json.users.length is 0 and not required
          cb null
          return
        else
          msg.send "Sorry, I expected to get 1 user back for #{email}, but got #{json.users.length} :sweat:. If your PagerDuty email is not #{email} use `/pager me as #{email}`"
          return

      cb(json.users[0])
