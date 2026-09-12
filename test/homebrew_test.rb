require 'minitest/autorun'
require 'tmpdir'
require_relative '../bin/homebrew'

class HomebrewTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('beacon-brew-')
    @saved = ENV.to_h
    ENV['AGENT_BEACON_HOME'] = File.join(@tmp, 'data')
    ENV['AGENT_BEACON_BREW'] = '/example/bin/brew'
    ENV['AGENT_BEACON_COMMAND'] = '/example/opt/agent-beacon/bin/agent-beacon'
    FileUtils.mkdir_p(File.join(@tmp, '.codex'))
    @config = File.join(@tmp, '.codex/hooks.json')
    @calls = []
    @runner = ->(*args) { @calls << args; true }
  end

  def teardown
    ENV.replace(@saved)
    FileUtils.remove_entry(@tmp)
  end

  def test_setup_is_repeatable_and_hooks_use_stable_entry
    File.write(@config, JSON.generate({'custom' => true, 'hooks' => {'Stop' => [{'hooks' => [{'type' => 'command', 'command' => 'other-tool'}]}]}}))
    2.times { capture_io { BeaconHomebrew.main('setup', home: @tmp, runner: @runner) } }
    config = JSON.parse(File.read(@config))
    assert config['custom']
    commands = config['hooks']['Stop'].flat_map { |g| g['hooks'].map { |h| h['command'] } }
    assert_equal ['other-tool', '/example/opt/agent-beacon/bin/agent-beacon hook codex'], commands
    assert_equal 2, @calls.size
    capture_io { BeaconHomebrew.main('uninstall', home: @tmp, runner: @runner) }
    assert_equal 'other-tool', JSON.parse(File.read(@config))['hooks']['Stop'][0]['hooks'][0]['command']
  end

  def test_legacy_service_rejected_before_hooks_change
    path = File.join(@tmp, 'Library/LaunchAgents/local.agent-beacon.controller.plist')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'existing')
    assert_raises(RuntimeError) { BeaconHomebrew.main('setup', home: @tmp, runner: @runner) }
    refute File.exist?(@config)
    assert_empty @calls
  end

  def test_service_failure_retains_hooks_for_retry_without_claiming_success
    assert_raises(RuntimeError) { BeaconHomebrew.main('setup', home: @tmp, runner: ->(*) { false }) }
    assert File.exist?(@config)
    refute File.exist?(File.join(Beacon.runtime, 'homebrew.json'))
  end
end
