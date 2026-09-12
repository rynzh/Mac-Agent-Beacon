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
    assert_equal 'working', Beacon.mode(snapshot)
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PostToolUse', session_id: 'a'}))
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_bad_input_is_rejected
    assert_raises(ArgumentError) { Beacon.event('a', '', 'working') }
    assert_raises(ArgumentError) { Beacon.event('a', 'b', 'bogus') }
    assert_raises(ArgumentError) { Beacon.hook('a', '[]') }
  end

  def test_installed_hooks_start_the_managed_service_instead_of_a_detached_controller
    File.write(File.join(@directory, 'service-receipt.json'), '{}')
    File.write(File.join(@directory, 'ready'), 'test')
    calls = []
    Beacon.stub(:system, ->(*args) { calls << args; true }) { Beacon.start }
    assert_equal '/bin/launchctl', calls.first.first
    assert_includes calls.first, 'kickstart'
    assert_equal 1, calls.size
  end

  def live_snapshot(requests = [], flags = [], status = 'active', revision = 1)
    {'type' => 'snapshot', 'revision' => revision, 'conversationState' => {
      'requests' => requests, 'threadRuntimeStatus' => {'type' => status, 'activeFlags' => flags},
      'turns' => [{'prompt' => 'private text'}]}}
  end

  def approval(id)
    {'id' => id, 'method' => 'item/commandExecution/requestApproval', 'params' => {'command' => 'private command'}}
  end

  def test_live_approval_wait_flashes_and_resolution_restores_before_tool_finishes
    Beacon.event('codex', 'a', 'working', 'turn')
    observer = Beacon::CodexLiveState.new
    assert observer.apply('a', live_snapshot)
    assert_equal 'working', Beacon.mode(snapshot)
    assert observer.apply('a', live_snapshot([approval(1), approval(2)], ['waitingOnApproval'], 'active', 2))
    assert_equal 'attention', Beacon.mode(snapshot)
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PostToolUse', session_id: 'a', turn_id: 'turn'}))
    assert_equal 'attention', Beacon.mode(snapshot), 'another tool must not clear a pending approval'
    assert observer.apply('a', {'type' => 'patches', 'baseRevision' => 2, 'revision' => 3,
      'patches' => [{'op' => 'remove', 'path' => ['requests', 0]}]})
    assert_equal 'attention', Beacon.mode(snapshot)
    assert observer.apply('a', {'type' => 'patches', 'baseRevision' => 3, 'revision' => 4,
      'patches' => [{'op' => 'replace', 'path' => ['requests'], 'value' => []}]})
    assert_equal 'working', Beacon.mode(snapshot), 'resolved approval must not wait for PostToolUse'
    refute_includes File.read(File.join(@directory, 'state.json')), 'private'
  end

  def test_live_automatic_review_does_not_flash_and_revision_gap_requires_snapshot
    Beacon.event('codex', 'a', 'working')
    observer = Beacon::CodexLiveState.new
    assert observer.apply('a', live_snapshot([], ['waitingOnApproval']))
    assert_equal 'working', Beacon.mode(snapshot)
    refute observer.apply('a', {'type' => 'patches', 'baseRevision' => 3, 'revision' => 4,
      'patches' => [{'op' => 'add', 'path' => ['requests', 0], 'value' => approval(1)}]})
    assert_equal 'working', Beacon.mode(snapshot)
    assert observer.apply('a', live_snapshot([approval(1)], ['waitingOnApproval'], 'active', 5))
    assert_equal 'attention', Beacon.mode(snapshot)
    observer.remove('a')
    assert_equal 'working', Beacon.mode(snapshot)
  end

  def test_live_connection_loss_alert_and_recovery_do_not_clear_terminal_failure
    Beacon.event('codex', 'a', 'working')
    observer = Beacon::CodexLiveState.new
    observer.apply('a', live_snapshot)
    observer.disconnected
    assert_equal 'attention', Beacon.mode(snapshot)
    observer.apply('a', live_snapshot)
    assert_equal 'working', Beacon.mode(snapshot)
    Beacon.event('codex', 'a', 'error')
    observer.apply('a', live_snapshot)
    assert_equal 'attention', Beacon.mode(snapshot)
  end

  def test_network_and_quota_failures_flash_until_new_turn
    %w[usageLimitExceeded responseStreamDisconnected responseStreamConnectionFailed httpConnectionFailed unauthorized].each do |code|
      observer = Beacon::CodexStatus.new('/unused')
      row = {'thread_id' => code, 'turn_id' => 'one', 'status' => 'failed', 'started_at' => Time.now.to_f,
             'error_json' => JSON.generate({'codexErrorInfo' => {code => {'httpStatusCode' => 503}}})}
      observer.apply(row)
      assert_equal 'attention', Beacon.mode(snapshot)
      Beacon.hook('codex', JSON.generate({hook_event_name: 'Stop', session_id: code, turn_id: 'one'}))
      assert_equal 'done', Beacon.mode(snapshot)
      observer.apply(row.merge('turn_id' => 'two', 'status' => 'inProgress'))
      assert_equal 'working', Beacon.mode(snapshot)
      Beacon.event('codex', code, 'idle', 'two')
    end
    assert_equal 'network_failure', Beacon::CodexStatus.failure_reason({'responseStreamDisconnected' => {}})
    assert_equal 'usage_limit', Beacon::CodexStatus.failure_reason('usageLimitExceeded')
  end

  def test_live_orphan_alert_is_removed_after_restart
    Beacon.event('codex-live', 'finished', 'attention')
    Beacon.event('codex', 'running', 'working')
    Beacon.event('codex-live', 'running', 'attention')
    observer = Beacon::CodexLive.new('/missing')
    observer.poll
    assert_equal ['running'], snapshot.values.select { |s| s['agent'] == 'codex-live' }.map { |s| s['session'] }
  end

  def test_live_initialization_timeout_closes_socket
    client, server = UNIXSocket.pair
    observer = Beacon::CodexLive.new('/missing')
    observer.instance_variable_set(:@socket, client)
    observer.instance_variable_set(:@initialize_deadline, 0)
    capture_io { observer.poll }
    assert client.closed?, 'an unanswered handshake must reconnect, not silently stop monitoring'
  ensure
    observer.close if observer
    server.close if server
  end

  def test_live_socket_frames_deliver_approval_and_resolution_without_control_commands
    path = File.join(@directory, 'observer.sock')
    server = UNIXServer.new(path)
    observer = Beacon::CodexLive.new(path)
    Beacon.event('codex', 'a', 'working')
    observer.poll
    peer = server.accept
    read_message = lambda do
      Timeout.timeout(1) { JSON.parse(peer.read(peer.read(4).unpack1('V'))) }
    end
    send_message = lambda do |message|
      json = JSON.generate(message)
      peer.write([json.bytesize].pack('V') + json)
    end
    request = read_message.call
    assert_equal 'initialize', request['method']
    send_message.call({'type' => 'response', 'method' => 'initialize', 'requestId' => request['requestId'],
                       'resultType' => 'success', 'result' => {'clientId' => 'observer'}})
    observer.poll
    follow = read_message.call
    assert_equal 'thread-stream-following-changed', follow['method']
    assert_equal true, follow.dig('params', 'following')
    broadcast = {'type' => 'broadcast', 'method' => 'thread-stream-state-changed', 'version' => 11,
                 'sourceClientId' => 'desktop', 'params' => {'hostId' => 'local', 'conversationId' => 'a',
                 'change' => live_snapshot([approval(42)], ['waitingOnApproval'])}}
    json = JSON.generate(broadcast)
    frame = [json.bytesize].pack('V') + json
    peer.write(frame.byteslice(0, 7))
    observer.poll
    assert_equal 'working', Beacon.mode(snapshot)
    peer.write(frame.byteslice(7, frame.bytesize))
    observer.poll
    assert_equal 'attention', Beacon.mode(snapshot)
    broadcast['params']['change'] = {'type' => 'patches', 'baseRevision' => 1, 'revision' => 2,
      'patches' => [{'op' => 'replace', 'path' => ['requests'], 'value' => []}]}
    send_message.call(broadcast)
    observer.poll
    assert_equal 'working', Beacon.mode(snapshot)
    refute IO.select([peer], nil, nil, 0), 'observer must never answer the approval'
    peer.close
    capture_io { observer.poll }
    assert_equal 'attention', Beacon.mode(snapshot)
  ensure
    observer.close if observer
    peer.close if peer && !peer.closed?
    server.close if server
  end

  def test_codex_permission_request_is_not_evidence_of_user_waiting
    payload = JSON.generate({hook_event_name: 'PermissionRequest', session_id: 'a', turn_id: 'one'})
    refute Beacon.hook('codex', payload)
    assert_empty snapshot
    Beacon.event('codex', 'a', 'working', 'one')
    before = snapshot
    3.times { refute Beacon.hook('codex', payload) }
    assert_equal before, snapshot
    assert_equal 'working', Beacon.mode(snapshot, Time.now.to_f + 60)
    Beacon.event('codex', 'a', 'error', 'one')
    refute Beacon.hook('codex', payload)
    assert_equal 'attention', Beacon.mode(snapshot)
    Beacon.event('codex', 'a', 'idle', 'one')
    assert Beacon.hook('claude', payload)
    assert_equal 'attention', Beacon.mode(snapshot)
  end

  def test_codex_terminal_failure_and_recovery
    observer = Beacon::CodexStatus.new('/unused')
    row = {'thread_id' => 'quota-test', 'turn_id' => 'one', 'status' => 'inProgress', 'started_at' => Time.now.to_f}
    observer.apply(row)
    assert_equal 'working', Beacon.mode(snapshot)
    Beacon.hook('codex', JSON.generate({hook_event_name: 'PermissionRequest', session_id: 'quota-test', turn_id: 'one'}))
    observer.apply(row)
    assert_equal 'working', Beacon.mode(snapshot)
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
