require 'minitest/autorun'
require 'tmpdir'
require_relative '../bin/agent-beacon'

class BacklightTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('beacon-backlight-test-')
    @trace = File.join(@directory, 'trace')
    @helper = File.join(@directory, 'helper')
    File.write(@helper, <<~RUBY)
      #!#{RbConfig.ruby}
      STDOUT.sync = true
      File.open(#{@trace.inspect}, 'a') do |trace|
        trace.sync = true
        trace.puts('start')
        puts 'ready'
        while (phase = STDIN.read(1))
          trace.puts(phase)
          puts 'ok'
        end
        trace.puts('restore')
      end
    RUBY
    File.chmod(0755, @helper)
    @light = Beacon::Backlight.new(helper: @helper)
  end

  def teardown
    @light.close
    FileUtils.remove_entry(@directory)
  end

  def test_default_and_invalid_configuration_are_disabled
    refute Beacon::Backlight.enabled?(@directory)
    %w[null [] broken].each do |value|
      File.write(File.join(@directory, 'backlight.json'), value)
      refute Beacon::Backlight.enabled?(@directory)
    end
    File.write(File.join(@directory, 'backlight.json'), '{"enabled":true}')
    assert Beacon::Backlight.enabled?(@directory)
  end

  def test_only_opted_in_attention_starts_helper_and_follows_the_same_phase
    @light.update('attention', '1', enabled: false)
    %w[working idle].each { |mode| @light.update(mode, '1', enabled: true) }
    refute File.exist?(@trace)
    %w[1 1 0 0 1].each { |phase| @light.update('attention', phase, enabled: true) }
    assert @light.status['active']
    @light.update('working', '1', enabled: true)
    assert_equal %w[start 1 0 1 restore], File.readlines(@trace, chomp: true)
    refute @light.status['active']
  end

  def test_disabling_during_attention_restores_and_reenable_takes_new_snapshot
    @light.update('attention', '0', enabled: true)
    @light.update('attention', '0', enabled: false)
    @light.update('attention', '1', enabled: true)
    @light.close
    assert_equal %w[start 0 restore start 1 restore], File.readlines(@trace, chomp: true)
  end

  def test_shutdown_restores_during_attention
    @light.update('attention', '1', enabled: true)
    @light.close
    assert_equal %w[start 1 restore], File.readlines(@trace, chomp: true)
  end

  def test_completion_flashes_then_restores_when_idle
    %w[1 0 1 0].each { |phase| @light.update('done', phase, enabled: true) }
    assert @light.status['active']
    @light.update('idle', '0', enabled: true)
    assert_equal %w[start 1 0 1 0 restore], File.readlines(@trace, chomp: true)
    refute @light.status['active']
  end

  def test_attention_to_completion_keeps_original_brightness_snapshot
    @light.update('attention', '0', enabled: true)
    @light.update('done', '1', enabled: true)
    @light.update('working', '1', enabled: true)
    assert_equal %w[start 0 1 restore], File.readlines(@trace, chomp: true)
  end

  def test_unavailable_backlight_is_contained_and_not_retried_every_phase
    File.write(@helper, "#!#{RbConfig.ruby}\nFile.open(#{@trace.inspect}, 'a') { |f| f.puts('failed') }; exit 1\n")
    capture_io do
      @light.update('attention', '1', enabled: true)
      @light.update('attention', '0', enabled: true)
    end
    assert @light.status['error']
    refute @light.status['active']
    assert_equal ['failed'], File.readlines(@trace, chomp: true)
    @light.update('working', '1', enabled: true)
    assert_nil @light.status['error']
  end

  def test_a_hung_helper_has_bounded_startup_and_shutdown
    File.write(@helper, "#!#{RbConfig.ruby}\ntrap('TERM') {}; sleep 60\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    capture_io { @light.update('attention', '1', enabled: true) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert @light.status['error']
    refute @light.status['active']
  end

  def test_simulation_never_starts_real_backlight_even_when_enabled
    File.write(File.join(@directory, 'backlight.json'), '{"enabled":true}')
    env = {'AGENT_BEACON_HOME' => @directory, 'AGENT_BEACON_SIMULATE' => '1'}
    begin
      _, error, result = Open3.capture3(env, RbConfig.ruby, Beacon::SCRIPT, 'event', 'test', 'one', 'attention')
      assert result.success?, error
      path = File.join(@directory, 'output.json')
      40.times { break if File.exist?(path); sleep 0.05 }
      status = JSON.parse(File.read(path)).fetch('backlight')
      assert_equal({'enabled' => true, 'active' => false, 'error' => nil, 'simulated' => true}, status)
    ensure
      Open3.capture3(env, RbConfig.ruby, Beacon::SCRIPT, 'stop')
      40.times { break unless File.exist?(File.join(@directory, 'ready')); sleep 0.05 }
    end
  end
end
