require 'minitest/autorun'
require 'tmpdir'
require_relative '../bin/setup'

class SetupTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('beacon-setup-test-')
    @root = File.join(@directory, 'Application Support & Test')
    FileUtils.mkdir_p(@root)
    @calls = []
    @runner = ->(*args) { @calls << args; true }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_service_is_registered_without_mapping_and_can_be_removed
    BeaconService.install(@root, home: @directory, runner: @runner)
    path = BeaconService.path(@directory)
    xml = File.read(path)
    assert_includes xml, 'Application Support &amp; Test'
    assert_includes xml, 'AGENT_BEACON_HOME'
    refute_includes xml, 'hidutil'
    assert system('/usr/bin/plutil', '-lint', path, out: File::NULL)
    assert_equal 2, @calls.size
    assert @calls.any? { |call| call.include?('bootstrap') }
    capture_io { BeaconService.remove(@root, home: @directory, runner: @runner) }
    refute File.exist?(path)
    assert File.directory?(@root)
  end

  def test_existing_or_modified_service_is_not_overwritten
    BeaconService.install(@root, home: @directory, runner: @runner)
    assert_raises(RuntimeError) { BeaconService.install(@root, home: @directory, runner: @runner) }
    path = BeaconService.path(@directory)
    File.write(path, 'user modified this')
    assert_raises(RuntimeError) { BeaconService.remove(@root, home: @directory, runner: @runner) }
    assert_equal 'user modified this', File.read(path)
  end

  def test_failed_registration_removes_only_the_new_service_file
    runner = ->(*args) { @calls << args; !args.include?('bootstrap') }
    assert_raises(RuntimeError) { BeaconService.install(@root, home: @directory, runner: runner) }
    refute File.exist?(BeaconService.path(@directory))
    refute File.exist?(File.join(@root, 'service-receipt.json'))
    refute @calls.any? { |call| call.include?('bootout') }, 'must not unload a service it did not register'
  end

  def test_failed_service_removal_preserves_configuration_and_receipt
    BeaconService.install(@root, home: @directory, runner: @runner)
    assert_raises(RuntimeError) { BeaconService.remove(@root, home: @directory, runner: ->(*) { false }) }
    assert File.exist?(BeaconService.path(@directory))
    assert File.exist?(File.join(@root, 'service-receipt.json'))
  end

  def test_existing_install_and_broad_root_are_rejected_before_build
    FileUtils.mkdir_p(File.join(@root, 'app'))
    assert_raises(RuntimeError) { BeaconSetup.install(source: '/unused', root: @root, home: @directory) }
    assert_raises(RuntimeError) { BeaconSetup.install(source: '/unused', root: @directory, home: @directory) }
    assert File.directory?(File.join(@root, 'app'))
  end

  def test_failed_build_leaves_no_app_hooks_or_service
    source = File.join(@directory, 'source')
    FileUtils.mkdir_p(source)
    %w[bin native test docs].each { |name| FileUtils.mkdir_p(File.join(source, name)) }
    %w[LICENSE THIRD_PARTY_NOTICES.md README.md bin/beacon].each { |name| File.write(File.join(source, name), '') }
    File.write(File.join(source, 'Makefile'), ".PHONY: test\ntest:\n\t@false\n")
    capture_subprocess_io do
      assert_raises(RuntimeError) { BeaconSetup.install(source: source, root: @root, home: @directory) }
    end
    refute File.exist?(File.join(@root, 'app'))
    refute File.exist?(File.join(@directory, '.codex/hooks.json'))
    refute File.exist?(BeaconService.path(@directory))
    assert_empty Dir[File.join(@root, '.install-*')]
  end

  def source_fixture
    source = File.join(@directory, 'source')
    FileUtils.mkdir_p(source)
    FileUtils.cp_r(File.expand_path('../bin', __dir__), source)
    %w[native test docs].each { |name| FileUtils.mkdir_p(File.join(source, name)) }
    %w[LICENSE THIRD_PARTY_NOTICES.md README.md].each { |name| File.write(File.join(source, name), '') }
    File.write(File.join(source, 'Makefile'), ".PHONY: test\ntest:\n\t@true\n")
    source
  end

  def test_hooks_use_final_install_path_and_preserve_other_configuration
    config = File.join(@directory, '.codex/hooks.json')
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, JSON.generate({'custom' => 'preserve', 'hooks' => {}}))
    capture_subprocess_io do
      BeaconSetup.install(source: source_fixture, root: @root, home: @directory, service: false)
    end
    result = JSON.parse(File.read(config))
    assert_equal 'preserve', result['custom']
    command = result['hooks']['PreToolUse'].first['hooks'].first['command']
    assert_equal File.realpath(File.join(@root, 'app/bin/agent-beacon.rb')), File.realpath(Shellwords.split(command)[1])
    refute_includes command, '.install-'
    assert File.executable?(File.join(@root, 'app/bin/beacon'))
    refute File.exist?(BeaconService.path(@directory))
  end

  def test_registration_failure_rolls_back_hooks_and_keeps_recoverable_files
    config = File.join(@directory, '.codex/hooks.json')
    FileUtils.mkdir_p(File.dirname(config))
    original = JSON.generate({'custom' => 'preserve', 'hooks' => {}})
    File.write(config, original)
    BeaconService.stub(:install, ->(*) { raise 'registration failed' }) do
      capture_subprocess_io do
        assert_raises(RuntimeError) { BeaconSetup.install(source: source_fixture, root: @root, home: @directory) }
      end
    end
    assert_equal original, File.read(config)
    refute File.exist?(File.join(@root, 'app'))
    assert_equal 1, Dir[File.join(@root, 'failed-install-*')].size
  end
end
