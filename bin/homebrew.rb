require_relative 'agent-beacon'

module BeaconHomebrew
  FORMULA = 'rynzh/tap/agent-beacon'.freeze

  def self.main(action, home: Dir.home, runner: ->(*args) { system(*args) })
    brew = ENV.fetch('AGENT_BEACON_BREW') { raise 'Install with Homebrew before using this command.' }
    raise 'Run as your normal user, without sudo.' if Process.uid.zero?
    config = File.join(home, '.codex', 'hooks.json')
    raise 'Refusing symlinked hook configuration.' if File.symlink?(config)
    case action
    when 'setup'
      raise 'Codex configuration not found. Start Codex once before setup.' unless File.directory?(File.dirname(config))
      legacy = File.join(home, 'Library', 'LaunchAgents', 'local.agent-beacon.controller.plist')
      raise 'Legacy service detected. Use its original uninstaller before Homebrew setup; keyboard mappings must be preserved.' if File.exist?(legacy) || File.symlink?(legacy)
      FileUtils.mkdir_p(Beacon.runtime, mode: 0700)
      File.open(File.join(Beacon.runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        if !File.file?(File.join(Beacon.runtime, 'homebrew.json')) && !lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise 'Another controller is running. Stop the previous installation first.'
        end
      end
      Beacon.configure('codex', config)
      FileUtils.rm_f(File.join(Beacon.runtime, 'stop'))
      raise 'Hooks installed, but service failed. Retry agent-beacon setup.' unless runner.call(brew, 'services', 'restart', FORMULA)
      File.write(File.join(Beacon.runtime, 'homebrew.json'), JSON.generate({'command' => ENV.fetch('AGENT_BEACON_COMMAND')}), perm: 0600)
      puts "Setup complete. Keyboard mappings unchanged.\n1. Input Monitoring: add #{Beacon::HELPER}\n2. Codex /hooks: review and trust Agent Beacon hooks.\nThen start a new task. Check with agent-beacon status."
    when 'uninstall'
      raise 'Could not stop Homebrew service; hooks retained.' unless runner.call(brew, 'services', 'stop', FORMULA)
      Beacon.configure('codex', config, remove: true) if File.exist?(config)
      FileUtils.rm_f(File.join(Beacon.runtime, 'homebrew.json'))
      puts 'Integration removed. Logs retained. Now run: brew uninstall agent-beacon'
    else
      raise 'Usage: agent-beacon setup|uninstall'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise 'Unexpected arguments' unless ARGV.length == 1
    BeaconHomebrew.main(ARGV.first)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
