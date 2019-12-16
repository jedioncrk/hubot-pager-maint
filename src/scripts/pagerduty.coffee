# Description:
#   Interact with PagerDuty services, schedules, and incidents with Hubot.
#
# Commands:
#   hubot pager maint <minutes> - schedule a maintenance window for <minutes>
#
# Authors:
#   Jesse Newland, Josh Nicols, Jacob Bednarz, Chris Lundquist, Chris Streeter, Joseph Pierri, Greg Hoin, Michael Warkentin

pagerduty = require('../pagerduty')
async = require('async')
inspect = require('util').inspect
moment = require('moment-timezone')

pagerDutyUserId        = process.env.HUBOT_PAGERDUTY_USER_ID
pagerDutyServiceApiKey = process.env.HUBOT_PAGERDUTY_SERVICE_API_KEY
pagerDutySchedules     = process.env.HUBOT_PAGERDUTY_SCHEDULES

module.exports = (robot) ->

  robot.respond /(pager|major)( me)? maint (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}) (\d+)?$/i, (msg) ->
    if pagerduty.missingEnvironmentForApi(msg)
      return

    campfireUserToPagerDutyUser msg, msg.message.user, (user) ->
      requester_id = user.id
      return unless requester_id

      if msg.match[8]
        minutes = msg.match[8]
      else
        minutes = 180

      service_ids = { 'PIWHL71', 'P8SIPJV', 'P08MRH4',
      'P3SB873', 'PSANKLW', 'P0UWFCF', 'P2MSHZ8', 'PSMIGCW', 
      'PLCHVRZ', 'PP40HJJ', 'PHUT3P1' }

      year = msg.match[3]
      month = msg.match[4]
      day = msg.match[5]
      hour = msg.match[6]
      minute = msg.match[7]

      datetime = new Date year + "-" + month + "-" + day + " " + hour + ":" + minute
      start_time = moment(datetime).format()
      end_time = moment(datetime).add('minutes', minutes).format()

      services = []
      for service_id in service_ids
        services.push id: service_id, type: 'service_reference'

      maintenance_window = { start_time, end_time, services }
      data = { maintenance_window, services }

      msg.send "Opening maintenance window for: #{service_ids}"
      pagerduty.post '/maintenance_windows', data, (err, json) ->
        if err?
          robot.emit 'error', err, msg
          return

        if json && json.maintenance_window
          msg.send "Maintenance window created! ID: #{json.maintenance_window.id} Ends: #{json.maintenance_window.end_time}"
        else
          msg.send "That didn't work. Check Hubot's logs for an error!"

  parseIncidentNumbers = (match) ->
    match.split(/[ ,]+/).map (incidentNumber) ->
      parseInt(incidentNumber)

  reassignmentParametersForUserOrScheduleOrEscalationPolicy = (msg, string, cb) ->
    if campfireUser = robot.brain.userForName(string)
      campfireUserToPagerDutyUser msg, campfireUser, (user) ->
        cb(assigned_to_user: user.id,  name: user.name)
    else
      pagerduty.get "/escalation_policies", query: string, (err, json) ->
        if err?
          robot.emit 'error', err, msg
          return

        escalationPolicy = null

        if json?.escalation_policies?.length == 1
          escalationPolicy = json.escalation_policies[0]
        # Multiple results returned and one is exact (case-insensitive)
        else if json?.escalation_policies?.length > 1
          matchingExactly = json.escalation_policies.filter (es) ->
            es.name.toLowerCase() == string.toLowerCase()
          if matchingExactly.length == 1
            escalationPolicy = matchingExactly[0]

        if escalationPolicy?
          cb(escalation_policy: escalationPolicy.id, name: escalationPolicy.name)
        else
          SchedulesMatching msg, string, (schedule) ->
            if schedule
              withCurrentOncallUser msg, schedule, (user, schedule) ->
                cb(assigned_to_user: user.id,  name: user.name)
            else
              cb()

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

  updateIncidents = (msg, incidentNumbers, statusFilter, updatedStatus) ->
    campfireUserToPagerDutyUser msg, msg.message.user, (user) ->

      requesterId = user.id
      return unless requesterId

      pagerduty.getIncidents statusFilter, (err, incidents) ->
        if err?
          robot.emit 'error', err, msg
          return

        foundIncidents = []
        for incident in incidents
          # FIXME this isn't working very consistently
          if incidentNumbers.indexOf(incident.incident_number) > -1
            foundIncidents.push(incident)

        if foundIncidents.length == 0
          msg.reply "Couldn't find incident(s) #{incidentNumbers.join(', ')}. Use `#{robot.name} pager incidents` for listing."
        else
          data = {
            incidents: foundIncidents.map (incident) ->
              {
                id: incident.id,
                type: 'incident_reference',
                status: updatedStatus
              }
          }

          pagerduty.put "/incidents", data , (err, json) ->
            if err?
              robot.emit 'error', err, msg
              return

            if json?.incidents
              buffer = "Incident"
              buffer += "s" if json.incidents.length > 1
              buffer += " "
              buffer += (incident.incident_number for incident in json.incidents).join(", ")
              buffer += " #{updatedStatus}"
              msg.reply buffer
            else
              msg.reply "Problem updating incidents #{incidentNumbers.join(',')}"


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
