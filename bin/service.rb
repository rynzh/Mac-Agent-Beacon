require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require_relative 'agent-beacon'

module BeaconService
  LABEL = 'local.agent-beacon.controller'.freeze

  def self.plist(root)
    escape = ->(value) { CGI.escapeHTML(value) }
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>Label</key><string>#{LABEL}</string>
      <key>ProgramArguments</key><array><string>#{escape.call(RbConfig.ruby)}</string><string>#{escape.call(File.join(root, 'app/bin/agent-beacon.rb'))}</string><string>run</string></array>
      <key>EnvironmentVariables</key><dict><key>AGENT_BEACON_HOME</key><string>#{escape.call(root)}</string></dict>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>ThrottleInterval</key><integer>30</integer>
      <key>StandardOutPath</key><string>#{escape.call(File.join(root, 'controller.log'))}</string>
      <key>StandardErrorPath</key><string>#{escape.call(File.join(root, 'controller.log'))}</string>
      </dict></plist>
    XML
  end

  def self.path(home = Dir.home)
    File.join(home, 'Library/LaunchAgents', "#{LABEL}.plist")
  end

  def self.install(root, home: Dir.home, runner: ->(*args) { system(*args) })
    destination = path(home)
    raise "Existing service not overwritten: #{destination}" if File.exist?(destination) || File.symlink?(destination)
    FileUtils.mkdir_p(File.dirname(destination))
    content = plist(root)
    File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(content) }
    registered = false
    begin
      raise 'LaunchAgent validation failed' unless runner.call('/usr/bin/plutil', '-lint', destination)
      raise 'LaunchAgent registration failed' unless runner.call('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", destination)
      registered = true
      File.write(File.join(root, 'service-receipt.json'), JSON.generate({'path' => destination, 'sha256' => Digest::SHA256.hexdigest(content)}), perm: 0600)
    rescue StandardError
      runner.call('/bin/launchctl', 'bootout', "gui/#{Process.uid}/#{LABEL}") if registered
      File.delete(destination) if File.file?(destination) && File.read(destination) == content
      raise
    end
  end

  def self.remove(root, home: Dir.home, runner: ->(*args) { system(*args) })
    receipt_path = File.join(root, 'service-receipt.json')
    raise 'No service receipt; legacy mapping installations must use their original uninstaller' unless File.file?(receipt_path)
    receipt = JSON.parse(File.read(receipt_path))
    destination = path(home)
    raise 'Service receipt path mismatch' unless receipt['path'] == destination
    if File.exist?(destination)
      raise 'Service configuration changed; refusing removal' unless !File.symlink?(destination) && Digest::SHA256.file(destination).hexdigest == receipt['sha256']
      raise 'Could not unload service; configuration and receipt retained' unless runner.call('/bin/launchctl', 'bootout', "gui/#{Process.uid}/#{LABEL}")
      File.delete(destination)
    end
    File.delete(receipt_path)
    puts 'Background service removed. App files, hook configuration, and keyboard mappings are unchanged.'
  end

  def self.main(action)
    case action
    when 'install' then install(Beacon.runtime)
    when 'remove' then remove(Beacon.runtime)
    when 'restart'
      FileUtils.rm_f(File.join(Beacon.runtime, 'stop'))
      raise 'Could not restart installed service' unless system('/bin/launchctl', 'kickstart', '-k', "gui/#{Process.uid}/#{LABEL}")
    else raise 'Usage: beacon service install|remove|restart'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BeaconService.main(ARGV.shift)
  rescue StandardError => error
    warn "Agent Beacon service: #{error.message}"
    exit 1
  end
end
