require 'json'
require 'fileutils'
require 'cgi'
require 'open3'
require_relative 'agent-beacon'

module Persistence
  MATCH = {'Product' => 'Apple Internal Keyboard / Trackpad', 'PrimaryUsagePage' => 1, 'PrimaryUsage' => 6}.freeze
  DEVICE = {'identifiers' => {'vendor_id' => 0, 'product_id' => 0, 'is_keyboard' => true, 'is_pointing_device' => false}, 'ignore' => true}.freeze
  MAPPING = [[0x39, 0xe3], [0xe7, 0xe0], [0xe6, 0x6e]].map { |src, dst| {'HIDKeyboardModifierMappingSrc' => 0x700000000 | src, 'HIDKeyboardModifierMappingDst' => 0x700000000 | dst} }.freeze
  LABELS = %w[local.agent-beacon.mapping local.agent-beacon.controller].freeze

  def self.atomic(path, text)
    FileUtils.mkdir_p(File.dirname(path), mode: 0700)
    temporary = "#{path}.agent-beacon.tmp"
    File.open(temporary, 'w', 0600) { |file| file.write(text) }
    File.rename(temporary, path)
  end

  def self.plist(label, args, interval: false)
    log = File.join(Beacon.runtime, "#{label}.log")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>Label</key><string>#{label}</string>
      <key>ProgramArguments</key><array>#{args.map { |arg| "<string>#{CGI.escapeHTML(arg)}</string>" }.join}</array>
      <key>RunAtLoad</key><true/>
      #{interval ? '<key>StartInterval</key><integer>30</integer>' : '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer>'}
      <key>StandardOutPath</key><string>#{CGI.escapeHTML(log)}</string>
      <key>StandardErrorPath</key><string>#{CGI.escapeHTML(log)}</string>
      </dict></plist>
    XML
  end

  def self.repair
    before, error, status = Open3.capture3('/usr/bin/hidutil', 'property', '--matching', JSON.generate(MATCH), '--get', 'UserKeyMapping')
    raise error unless status.success?
    return if before.strip.empty?
    pairs = before.scan(/HIDKeyboardModifierMappingDst\s*=\s*(\d+);\s*HIDKeyboardModifierMappingSrc\s*=\s*(\d+);/).map { |dst, src| [src.to_i, dst.to_i] }
    expected = MAPPING.map { |item| [item['HIDKeyboardModifierMappingSrc'], item['HIDKeyboardModifierMappingDst']] }
    return if pairs.sort == expected.sort
    unless before.include?('(null)') || before.match?(/UserKeyMapping\s+\(\s*\)\s*\z/)
      raise 'Unexpected system mapping; refusing to overwrite. Run uninstall before changing mappings.'
    end
    raise 'System mapping failed' unless system('/usr/bin/hidutil', 'property', '--matching', JSON.generate(MATCH), '--set', JSON.generate({'UserKeyMapping' => MAPPING}))
  end

  def self.main(action)
    return repair if action == 'repair'
    config_path = File.join(Dir.home, '.config/karabiner/karabiner.json')
    manifest_path = File.join(Beacon.runtime, 'persistence-backup.json')
    agent_dir = File.join(Dir.home, 'Library/LaunchAgents')
    domain = "gui/#{Process.uid}"
    if action == 'deploy'
      raise 'Install first' unless File.exist?(manifest_path)
      application = File.join(Beacon.runtime, 'app')
      %w[bin build].each { |directory| FileUtils.mkdir_p(File.join(application, directory), mode: 0700) }
      %w[bin/agent-beacon.rb bin/codex-status.rb bin/persistence.rb build/beacon-led THIRD_PARTY_NOTICES.md].each do |relative|
        source = File.join(Beacon::ROOT, relative)
        destination = File.join(application, relative)
        FileUtils.cp(source, destination) unless source == destination
      end
      commands = [[RbConfig.ruby, File.join(application, 'bin/persistence.rb'), 'repair'], [RbConfig.ruby, File.join(application, 'bin/agent-beacon.rb'), 'run']]
      LABELS.each_with_index do |label, index|
        system('/bin/launchctl', 'bootout', "#{domain}/#{label}", out: File::NULL, err: File::NULL)
        path = File.join(agent_dir, "#{label}.plist")
        atomic(path, plist(label, commands[index], interval: index == 0))
        raise "Could not load #{label}" unless system('/bin/launchctl', 'bootstrap', domain, path)
      end
      puts "Runtime installed: #{application}"
      return
    end
    if action == 'install'
      raise 'Already installed; inspect status or uninstall first' if File.exist?(manifest_path)
      LABELS.each { |label| raise "Existing LaunchAgent: #{label}" if File.exist?(File.join(agent_dir, "#{label}.plist")) }
      original = File.binread(config_path)
      config = JSON.parse(original)
      profile = config.fetch('profiles').find { |item| item['selected'] }
      raise 'Expected selected profile without device overrides' unless profile && profile.fetch('devices', []).empty?
      atomic(manifest_path, JSON.pretty_generate({'original' => original, 'profile_name' => profile['name']}))
      begin
        profile['devices'] = [DEVICE]
        atomic(config_path, JSON.pretty_generate(config) + "\n")
        sleep 2
        repair
        Beacon.main(['stop'])
        30.times do
          running = File.open(File.join(Beacon.runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) { |lock| !lock.flock(File::LOCK_EX | File::LOCK_NB) }
          break unless running
          sleep 0.1
        end
        FileUtils.rm_f(File.join(Beacon.runtime, 'stop'))
        commands = [[RbConfig.ruby, File.expand_path(__FILE__), 'repair'], [RbConfig.ruby, Beacon::SCRIPT, 'run']]
        LABELS.each_with_index do |label, index|
          path = File.join(agent_dir, "#{label}.plist")
          atomic(path, plist(label, commands[index], interval: index == 0))
          raise 'Invalid launch configuration' unless system('/usr/bin/plutil', '-lint', path)
          raise "Could not load #{label}" unless system('/bin/launchctl', 'bootstrap', domain, path)
        end
        puts 'Persistence installed. Login runs mapping repair and the LED controller.'
      rescue StandardError
        main('uninstall')
        raise
      end
    elsif action == 'uninstall'
      raise 'No installation manifest' unless File.exist?(manifest_path)
      backup = JSON.parse(File.read(manifest_path))
      LABELS.each do |label|
        path = File.join(agent_dir, "#{label}.plist")
        if File.exist?(path)
          system('/bin/launchctl', 'bootout', "#{domain}/#{label}", out: File::NULL, err: File::NULL)
          FileUtils.rm_f(path)
        end
      end
      Beacon.main(['stop'])
      sleep 0.5
      config = JSON.parse(File.read(config_path))
      profile = config.fetch('profiles').find { |item| item['name'] == backup['profile_name'] }
      raise 'Profile changed; restore manually from persistence-backup.json' unless profile && profile['devices'] == [DEVICE]
      profile.delete('devices')
      raise 'Could not clear system mapping; backup retained' unless system('/usr/bin/hidutil', 'property', '--matching', JSON.generate(MATCH), '--set', '{"UserKeyMapping":[]}')
      atomic(config_path, config == JSON.parse(backup['original']) ? backup['original'] : JSON.pretty_generate(config) + "\n")
      File.rename(manifest_path, "#{manifest_path}.restored-#{Time.now.to_i}")
      puts 'Original Karabiner handling restored; LaunchAgents removed. Agent hooks remain installed.'
    else
      raise 'Usage: ruby bin/persistence.rb install|uninstall|repair'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Persistence.main(ARGV.first)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
