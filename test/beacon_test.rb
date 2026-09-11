require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../bin/agent-beacon'

class BeaconTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('agent-beacon-test-')
    @previous = ENV['AGENT_BEACON_HOME']
    ENV['AGENT_BEACON_HOME'] = @directory
  end

  def teardown
    ENV['AGENT_BEACON_HOME'] = @previous
    FileUtils.remove_entry(@directory)
  end

  def snapshot
    Beacon.transaction { |state| state.dup }
  end

  def test_sessions_are_independent
    Beacon.event('codex', 'a', 'working')
    Beacon.event('claude', 'b', 'done')
    assert_equal 'working', Beacon.mode(snapshot)
    Beacon.event('claude', 'b', 'attention')
    assert_equal 'attention', Beacon.mode(snapshot)
    Beacon.event('claude', 'b', 'idle')
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_done_expires_and_stale_is_not_success
    Beacon.event('codex', 'a', 'done')
    assert_equal 'done', Beacon.mode(snapshot)
    assert_equal 'idle', Beacon.mode(snapshot, Time.now.to_f + 7)
    Beacon.event('codex', 'a', 'working')
    assert_equal 'idle', Beacon.mode(snapshot, Time.now.to_f + 43_201)
  end

  def test_old_turn_cannot_finish_new_turn
    Beacon.event('codex', 'a', 'working', 'new')
    refute Beacon.event('codex', 'a', 'done', 'old')
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_hooks_do_not_store_prompts
    Beacon.hook('codex', JSON.generate({hook_event_name: 'UserPromptSubmit', session_id: 'a', prompt: 'private words'}))
    refute_includes File.read(File.join(@directory, 'state.json')), 'private words'
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PermissionRequest', session_id: 'a'}))
    assert_equal 'attention', Beacon.mode(snapshot)
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PostToolUse', session_id: 'a'}))
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_bad_input_is_rejected
    assert_raises(ArgumentError) { Beacon.event('a', '', 'working') }
    assert_raises(ArgumentError) { Beacon.event('a', 'b', 'bogus') }
    assert_raises(ArgumentError) { Beacon.hook('a', '[]') }
  end

  def test_codex_terminal_failure_and_recovery
    observer = Beacon::CodexStatus.new('/unused')
    row = {'thread_id' => 'quota-test', 'turn_id' => 'one', 'status' => 'inProgress', 'started_at' => Time.now.to_f}
    observer.apply(row)
    assert_equal 'working', Beacon.mode(snapshot)
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PermissionRequest', session_id: 'quota-test', turn_id: 'one'}))
    observer.apply(row)
    assert_equal 'attention', Beacon.mode(snapshot)
    observer.apply(row.merge('status' => 'failed', 'error_json' => '{"codexErrorInfo":"usageLimitExceeded","message":"private error"}'))
    assert_equal 'usage_limit', snapshot.values.first['reason']
    Beacon.event('codex', 'quota-test', 'done', 'one')
    assert_equal 'attention', Beacon.mode(snapshot)
    refute_includes File.read(File.join(@directory, 'state.json')), 'private error'
    observer.apply(row.merge('turn_id' => 'two', 'started_at' => Time.now.to_f + 1))
    assert_equal 'working', Beacon.mode(snapshot)
    observer.apply(row.merge('turn_id' => 'two', 'status' => 'completed'))
    assert_equal 'done', Beacon.mode(snapshot)
    observer.apply(row.merge('turn_id' => 'two', 'status' => 'interrupted'))
    assert_equal 'idle', Beacon.mode(snapshot)
  end

  def test_codex_database_poll_ignores_history_and_reads_latest
    database = File.join(@directory, 'history.sqlite')
    sql = "CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, error_json TEXT, rollout_ordinal INTEGER); " \
          "INSERT INTO thread_turns VALUES('a','old','failed',1,2,NULL,1);"
    _, _, result = Open3.capture3('/usr/bin/sqlite3', database, sql)
    assert result.success?
    observer = Beacon::CodexStatus.new(database, since: 10)
    observer.poll
    assert_empty snapshot
    Open3.capture3('/usr/bin/sqlite3', database, "INSERT INTO thread_turns VALUES('a','new','failed',11,12,'{\"codexErrorInfo\":\"usageLimitExceeded\"}',2);")
    observer.poll
    assert_equal 'attention', Beacon.mode(snapshot)
    assert_equal 'usage_limit', snapshot.values.first['reason']
    Open3.capture3('/usr/bin/sqlite3', database, "INSERT INTO thread_turns VALUES('a','next','inProgress',#{Time.now.to_i + 2},NULL,NULL,3);")
    observer.poll
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_concurrent_event_writers
    pids = 8.times.map { |i| fork { Beacon.event('test', i.to_s, 'working'); exit! 0 } }
    pids.each { |pid| Process.wait(pid) }
    assert_equal 8, snapshot.size
  end

  def test_install_idempotent_and_uninstall_preserves_others
    path = File.join(@directory, 'settings.json')
    original = {'other' => true, 'hooks' => {'Stop' => [{'hooks' => [{'type' => 'command', 'command' => 'existing-tool'}]}]}}
    File.write(path, JSON.generate(original))
    Beacon.configure('claude', path)
    first = JSON.parse(File.read(path))
    Beacon.configure('claude', path)
    assert_equal first, JSON.parse(File.read(path))
    Beacon.configure('claude', path, remove: true)
    assert_equal original, JSON.parse(File.read(path))
  end

  def test_malformed_config_not_overwritten
    path = File.join(@directory, 'settings.json')
    File.write(path, '{invalid')
    assert_raises(JSON::ParserError) { Beacon.configure('codex', path) }
    assert_equal '{invalid', File.read(path)
  end

  def test_cli_and_simulated_controller
    environment = {'AGENT_BEACON_HOME' => @directory, 'AGENT_BEACON_SIMULATE' => '1'}
    _, _, status = Open3.capture3(environment, RbConfig.ruby, Beacon::SCRIPT, '--help')
    assert status.success?
    _, _, status = Open3.capture3(environment, RbConfig.ruby, Beacon::SCRIPT, 'bogus')
    refute status.success?
    stdout, _, status = Open3.capture3(environment, RbConfig.ruby, Beacon::SCRIPT, 'hook', 'codex', stdin_data: 'bad json')
    assert status.success?
    assert_equal '', stdout
    begin
      _, _, status = Open3.capture3(environment, RbConfig.ruby, Beacon::SCRIPT, 'event', 'test', 'one', 'working')
      assert status.success?
      path = File.join(@directory, 'output.json')
      40.times { break if File.exist?(path); sleep 0.05 }
      assert File.exist?(path)
      assert_equal 'working', JSON.parse(File.read(path))['mode']
      Beacon.event('test', 'one', 'attention')
      40.times { break if JSON.parse(File.read(path))['mode'] == 'attention'; sleep 0.05 }
      assert_equal 'attention', JSON.parse(File.read(path))['mode']
    ensure
      Open3.capture3(environment, RbConfig.ruby, Beacon::SCRIPT, 'stop')
      40.times { break unless File.exist?(File.join(@directory, 'ready')); sleep 0.05 }
    end
  end
end
