chai = require 'chai'
sinon = require 'sinon'
chai.use require 'sinon-chai'

expect = chai.expect

describe 'pagerduty', ->
  before ->
    @triggerRegex = /(pager|major)( me)? (?:trigger|page) ((["'])([^\4]*?)\4|“([^”]*?)”|‘([^’]*?)’|([\.\w\-]+)) (.+)$/i
    @schedulesRegex = /(pager|major)( me)? schedules( ((["'])([^]*?)\5|(.+)))?$/i
    @whosOnCallRegex = /who(?:’s|'s|s| is|se)? (?:on call|oncall|on-call)(?:\?)?(?: (?:for )?((["'])([^]*?)\2|(.*?))(?:\?|$))?$/i

  beforeEach ->
    @robot =
      respond: sinon.spy()
      hear: sinon.spy()

    require('../src/scripts/pagerduty')(@robot)

  it 'registers a pager maintenance listener', ->
    expect(@robot.respond).to.have.been.calledWith(/(pager|major)( me)? maint (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}) (\d+)?$/i)

