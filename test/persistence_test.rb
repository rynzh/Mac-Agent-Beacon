require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative '../bin/persistence'

class PersistenceTest < Minitest::Test
  def test_deployed_runtime_contains_backlight_dependencies_and_starts
    Dir.mktmpdir('agent-beacon-persistence-test-') do |directory|
      application = File.join(directory, 'app')
      Persistence.copy_runtime(application)

      stdout, stderr, result = Open3.capture3(RbConfig.ruby, File.join(application, 'bin/agent-beacon.rb'), '--help')
      assert result.success?, stderr
      assert_includes stdout, 'Agent Beacon'
      assert File.executable?(File.join(application, 'build/beacon-backlight'))
    end
  end
end
