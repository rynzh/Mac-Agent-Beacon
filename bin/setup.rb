require 'fileutils'
require 'optparse'
require 'tmpdir'
require_relative 'service'

module BeaconSetup
  def self.install(source:, root:, home: Dir.home, hooks: true, claude: false, service: true)
    root = File.expand_path(root)
    raise 'Choose a dedicated installation directory, not home or a filesystem root' if [File.expand_path(home), '/', '/Users', '/tmp', '/private/tmp'].include?(root)
    raise 'Installation directory must not be a symlink' if File.symlink?(root)
    application = File.join(root, 'app')
    raise "Already installed: #{application}. Existing files were not changed; see README for upgrade guidance." if File.exist?(application) || File.symlink?(application)
    raise 'An existing controller service would be overwritten; remove or migrate it first' if service && (File.exist?(BeaconService.path(home)) || File.symlink?(BeaconService.path(home)))
    FileUtils.mkdir_p(root, mode: 0700)
    permissions = File.stat(root)
    raise 'Installation directory must be private and owned by the current user' unless permissions.uid == Process.uid && permissions.mode & 0022 == 0
    before = {}
    written = {}
    installed = false
    begin
      Dir.mktmpdir('.install-', root) do |stage|
        staged_app = File.join(stage, 'app')
        FileUtils.mkdir_p(staged_app)
        %w[Makefile LICENSE THIRD_PARTY_NOTICES.md README.md bin native test docs].each do |item|
          FileUtils.cp_r(File.join(source, item), staged_app)
        end
        FileUtils.chmod(0755, File.join(staged_app, 'bin/beacon'))
        raise 'Build or tests failed; no hooks or service were installed' unless system('make', 'test', chdir: staged_app)
        File.rename(staged_app, application)
        installed = true
      end
      if hooks
        agents = ['codex'] + (claude ? ['claude'] : [])
        agents.each do |agent|
          config = File.join(home, agent == 'codex' ? '.codex/hooks.json' : '.claude/settings.json')
          raise "Refusing symlinked configuration: #{config}" if File.symlink?(config)
          before[config] = File.exist?(config) ? File.binread(config) : nil
          raise "Could not install #{agent} hooks" unless system(RbConfig.ruby, File.join(application, 'bin/agent-beacon.rb'), 'install-hooks', agent, config)
          written[config] = File.binread(config)
        end
      end
      BeaconService.install(root, home: home) if service
    rescue StandardError
      written.each do |config, content|
        next unless File.file?(config) && File.binread(config) == content
        if before[config]
          File.binwrite(config, before[config])
        else
          File.delete(config)
        end
      end
      # Keep a failed installation recoverable; never recursively erase a user-selected root.
      File.rename(application, File.join(root, "failed-install-#{Process.pid}")) if installed && File.directory?(application)
      raise
    end
    puts "\nInstalled: #{application}"
    puts "Background service: #{service ? 'registered; retries after missing permission every 30 seconds' : 'not installed (--no-service)'}"
    puts "Keyboard mappings: unchanged"
    puts "\nManual permissions (never granted by this installer):"
    puts "1. Input Monitoring: add #{application}/build/beacon-led"
    puts '2. Codex /hooks: review and trust Agent Beacon hooks.' if hooks
    puts "Then start a new Codex task. If macOS requests an app restart, save work first."
    puts "Status: \"#{application}/bin/beacon\" status"
    puts "Restart after permission: \"#{application}/bin/beacon\" service restart" if service
    puts 'Existing Karabiner device ownership can still block the LED; see README.'
  end

  def self.main(args)
    options = {source: File.expand_path('..', __dir__), root: Beacon.runtime}
    parser = OptionParser.new do |o|
      o.banner = 'Usage: install.sh [--with-claude] [--prefix PATH] [--no-hooks] [--no-service]'
      o.on('--with-claude') { options[:claude] = true }
      o.on('--prefix PATH') { |value| options[:root] = value }
      o.on('--no-hooks') { options[:hooks] = false }
      o.on('--no-service') { options[:service] = false }
      o.on('--help') { puts o; return }
    end
    parser.parse!(args)
    raise "Unexpected arguments: #{args.join(' ')}" unless args.empty?
    raise 'Run as your normal macOS user, not sudo/root' if Process.uid.zero?
    install(**options)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BeaconSetup.main(ARGV)
  rescue StandardError => error
    warn "Agent Beacon installation: #{error.message}"
    exit 1
  end
end
