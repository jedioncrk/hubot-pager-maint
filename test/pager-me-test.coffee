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

  it 'trigger handles users with dots', ->
    msg = @triggerRegex.exec('pager trigger foo.bar baz')
    expect(msg[8]).to.equal('foo.bar')
    expect(msg[9]).to.equal('baz')

  it 'trigger handles users with spaces', ->
    msg = @triggerRegex.exec('pager trigger "foo bar" baz')
    expect(msg[5]).to.equal('foo bar')
    expect(msg[9]).to.equal('baz')

  it 'trigger handles users with spaces and single quotes', ->
    msg = @triggerRegex.exec("pager trigger 'foo bar' baz")
    expect(msg[5]).to.equal('foo bar')
    expect(msg[9]).to.equal('baz')

  it 'trigger handles users without spaces', ->
    msg = @triggerRegex.exec('pager trigger foo bar baz')
    expect(msg[8]).to.equal('foo')
    expect(msg[9]).to.equal('bar baz')

  it 'schedules handles names with quotes', ->
    msg = @schedulesRegex.exec('pager schedules "foo bar"')
    expect(msg[6]).to.equal('foo bar')

  it 'schedules handles names without quotes', ->
    msg = @schedulesRegex.exec('pager schedules foo bar')
    expect(msg[7]).to.equal('foo bar')

  it 'schedules handles names without spaces', ->
    msg = @schedulesRegex.exec('pager schedules foobar')
    expect(msg[7]).to.equal('foobar')

  it 'whos on call handles bad input', ->
    msg = @whosOnCallRegex.exec('whos on callllllll')
    expect(msg).to.be.null

  it 'whos on call handles no schedule', ->
    msg = @whosOnCallRegex.exec('whos on call')
    expect(msg).to.not.be.null

  it 'whos on call handles schedules with quotes', ->
    msg = @whosOnCallRegex.exec('whos on call for "foo bar"')
    expect(msg[3]).to.equal('foo bar')

  it 'whos on call handles schedules with quotes and quesiton mark', ->
    msg = @whosOnCallRegex.exec('whos on call for "foo bar"?')
    expect(msg[3]).to.equal('foo bar')

  it 'whos on call handles schedules without quotes', ->
    msg = @whosOnCallRegex.exec('whos on call for foo bar')
    expect(msg[4]).to.equal('foo bar')

  it 'whos on call handles schedules without quotes and question mark', ->
    msg = @whosOnCallRegex.exec('whos on call for foo bar?')
    expect(msg[4]).to.equal('foo bar')
