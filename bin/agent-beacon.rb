require 'json'
require 'fileutils'
require 'digest'
require 'shellwords'
require 'rbconfig'
require 'timeout'
require_relative 'codex-status'
require_relative 'codex-live'
require_relative 'backlight'

module Beacon
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'bin', 'agent-beacon.rb')
  HELPER = File.join(ROOT, 'build', 'beacon-led')
  STATES = %w[working attention done idle error].freeze
  EVENTS = {
    'UserPromptSubmit' => 'working', 'PreToolUse' => 'working',
    'PostToolUse' => 'working', 'PermissionRequest' => 'attention',
    'Stop' => 'done', 'SessionEnd' => 'idle', 'Interrupt' => 'idle',
    'StopFailure' => 'error'
  }.freeze

  def self.runtime
    File.expand_path(ENV.fetch('AGENT_BEACON_HOME', File.join(Dir.home, 'Library', 'Application Support', 'AgentBeacon')))
  end

  def self.transaction
    FileUtils.mkdir_p(runtime, mode: 0700)
    File.open(File.join(runtime, 'state.lock'), File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      path = File.join(runtime, 'state.json')
      state = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      result = yield state
      temporary = "#{path}.#{Process.pid}.tmp"
      File.open(temporary, 'w', 0600) { |file| file.write(JSON.generate(state)) }
      File.rename(temporary, path)
      result
    end
  end

  def self.event(agent, session, status, turn = nil)
    raise ArgumentError, 'agent/session required (maximum 200 characters)' unless [agent, session].all? { |v| v.is_a?(String) && !v.empty? && v.size <= 200 }
    raise ArgumentError, 'unknown state' unless STATES.include?(status)
    raise ArgumentError, 'invalid turn ID' unless turn.nil? || (turn.is_a?(String) && turn.size <= 200)
    transaction do |state|
      key = Digest::SHA256.hexdigest("#{agent}\0#{session}")
      old = state[key]
      next false if old && old['status'] == 'error' && old['turn'] == turn && status == 'working'
      if old && turn && old['turn'] && old['turn'] != turn && status != 'working'
        next false
      end
      if status == 'idle'
        state.delete(key)
      else
        state[key] = { 'agent' => agent, 'session' => session, 'status' => status,
                       'turn' => turn || (old && old['turn']), 'at' => Time.now.to_f }
      end
      true
    end
  end

  def self.mode(state, now = Time.now.to_f)
    active = state.values.select { |s| now - s.fetch('at') < (s['status'] == 'done' ? 6 : 43_200) }
    return 'attention' if active.any? { |s| %w[attention error].include?(s['status']) }
    return 'working' if active.any? { |s| s['status'] == 'working' }
    return 'done' if active.any? { |s| s['status'] == 'done' }
    'idle'
  end

  def self.hook(agent, input)
    data = JSON.parse(input)
    raise ArgumentError, 'hook payload must be an object' unless data.is_a?(Hash)
    name = data['hook_event_name']
    # A permission request may be handled automatically, without waiting for the user.
    return false if agent == 'codex' && name == 'PermissionRequest'
    status = EVENTS[name]
    if name == 'Notification'
      status = 'attention' if %w[permission_prompt idle_prompt elicitation_dialog].include?(data['notification_type'])
    end
    status = 'attention' if agent != 'codex' && name == 'PreToolUse' && data['tool_name'].to_s.match?(/AskUserQuestion|request_user_input/)
    return false unless status
    event(agent, data['session_id'] || data['thread_id'], status, data['turn_id'])
  end

  def self.start
    FileUtils.mkdir_p(runtime, mode: 0700)
    File.open(File.join(runtime, 'spawn.lock'), File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      File.open(File.join(runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) do |daemon|
        return if !daemon.flock(File::LOCK_EX | File::LOCK_NB)
        daemon.flock(File::LOCK_UN)
      end
      FileUtils.rm_f(File.join(runtime, 'stop'))
      log = File.open(File.join(runtime, 'daemon.log'), 'a', 0600)
      begin
        if ENV['AGENT_BEACON_BREW']
          raise 'Could not start Homebrew service; run agent-beacon setup' unless system(ENV.fetch('AGENT_BEACON_BREW'), 'services', 'start', 'rynzh/tap/agent-beacon', out: log, err: log)
        elsif File.file?(File.join(runtime, 'service-receipt.json'))
          raise 'Could not start managed controller service' unless system('/bin/launchctl', 'kickstart', "gui/#{Process.uid}/local.agent-beacon.controller", out: log, err: log)
        else
          pid = Process.spawn(RbConfig.ruby, SCRIPT, 'run', in: File::NULL, out: log, err: log, pgroup: true)
          Process.detach(pid)
        end
      ensure
        log.close
      end
      20.times do
        sleep 0.05
        break if File.exist?(File.join(runtime, 'ready'))
      end
    end
  end

  def self.run
    FileUtils.mkdir_p(runtime, mode: 0700)
    File.open(File.join(runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) do |lock|
      return unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      simulation = ENV['AGENT_BEACON_SIMULATE'] == '1'
      output = simulation ? nil : IO.popen([HELPER, 'serve'], 'r+')
      output.sync = true if output
      stopping = false
      %w[INT TERM HUP].each { |sig| Signal.trap(sig) { stopping = true } }
      File.write(File.join(runtime, 'ready'), Process.pid.to_s)
      previous = nil
      previous_mode = nil
      previous_backlight = nil
      backlight = Backlight.new
      watcher = nil
      begin
        raise 'HID helper failed to start; run doctor' if output && Timeout.timeout(2) { output.gets } != "ready\n"
        unless simulation
          watcher = Thread.new do
            live = CodexLive.new
            sources = [File.join(Dir.home, '.codex', 'thread_history_1.sqlite'),
                       File.join(Dir.home, '.codex', 'sqlite', 'thread_history_1.sqlite')].map { |path| CodexStatus.new(path) }
            database_at = 0
            database_errors = {}
            until stopping
              live.poll
              begin
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if now >= database_at
                  database_at = now + 1
                  sources.each_with_index do |source, index|
                    begin
                      source.poll
                      database_errors.delete(index)
                    rescue StandardError => error
                      warn "Agent Beacon database observer #{index}: #{error.class}" unless database_errors[index] == error.class
                      database_errors[index] = error.class
                    end
                  end
                end
              rescue StandardError => error
                warn "Agent Beacon status observer: #{error.message}"
              end
              sleep 0.1
            end
          ensure
            live.close if live
          end
        end
        until stopping || File.exist?(File.join(runtime, 'stop'))
          current = transaction do |state|
            state.delete_if { |_, s| Time.now.to_f - s['at'] >= (s['status'] == 'done' ? 6 : 43_200) }
            mode(state)
          end
          phase = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          command = case current
                    when 'working' then '1'
                    when 'attention' then phase % 0.4 < 0.2 ? '1' : '0'
                    else '0'
                    end
          enabled = Backlight.enabled?(runtime)
          if command != previous || current != previous_mode
            output.write(command) if output
            raise 'HID write failed; see daemon.log' if output && Timeout.timeout(2) { output.gets } != "ok\n"
          end
          backlight_status = if simulation
                               {'enabled' => enabled, 'active' => false, 'error' => nil, 'simulated' => true}
                             else
                               backlight.update(current, command, enabled: enabled).merge('simulated' => false)
                             end
          if command != previous || current != previous_mode || backlight_status != previous_backlight
            File.write(File.join(runtime, 'output.json'), JSON.generate({ mode: current, command: command, simulated: simulation, backlight: backlight_status, at: Time.now.to_f }))
            previous = command
            previous_mode = current
            previous_backlight = backlight_status
          end
          sleep 0.1
        end
      ensure
        stopping = true
        backlight.close
        watcher.join if watcher
        if output && !output.closed?
          output.close_write
          output.close
        end
        FileUtils.rm_f(File.join(runtime, 'ready'))
      end
    end
  end

  def self.configuration(agent, command)
    names = EVENTS.keys - (agent == 'codex' ? ['StopFailure'] : ['Interrupt'])
    names += ['Notification'] if agent == 'claude'
    names.to_h { |name| [name, [{ 'hooks' => [{ 'type' => 'command', 'command' => command, 'timeout' => 3 }] }]] }
  end

  def self.configure(agent, path, remove: false)
    raise ArgumentError, 'agent must be codex or claude' unless %w[codex claude].include?(agent)
    command = if ENV['AGENT_BEACON_COMMAND']
                [ENV.fetch('AGENT_BEACON_COMMAND'), 'hook', agent].shelljoin
              else
                [RbConfig.ruby, SCRIPT, 'hook', agent].shelljoin
              end
    FileUtils.mkdir_p(File.dirname(path))
    File.open("#{path}.agent-beacon.lock", File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      original = File.exist?(path) ? File.read(path) : '{}'
      config = JSON.parse(original)
      raise ArgumentError, 'configuration must be an object' unless config.is_a?(Hash)
      hooks = config.fetch('hooks', {})
      raise ArgumentError, 'hooks must be an object' unless hooks.is_a?(Hash)
      hooks.each_value do |groups|
        raise ArgumentError, 'hook groups must be arrays' unless groups.is_a?(Array)
        groups.each do |group|
          raise ArgumentError, 'invalid hook group' unless group.is_a?(Hash) && group['hooks'].is_a?(Array)
          group['hooks'].reject! { |h| h.is_a?(Hash) && h['command'] == command }
        end
        groups.reject! { |g| g['hooks'].empty? }
      end
      hooks.delete_if { |_, groups| groups.empty? }
      configuration(agent, command).each { |name, groups| (hooks[name] ||= []).concat(groups) } unless remove
      config['hooks'] = hooks
      backup = "#{path}.agent-beacon-backup-#{Time.now.strftime('%Y%m%d%H%M%S')}-#{Process.pid}"
      File.open(backup, 'w', 0600) { |f| f.write(original) } if File.exist?(path)
      temporary = "#{path}.agent-beacon.tmp"
      File.open(temporary, 'w', 0600) { |f| f.write(JSON.pretty_generate(config) + "\n") }
      File.rename(temporary, path)
    end
  end

  def self.main(args)
    command = args.shift
    case command
    when 'backlight'
      action = args.shift
      raise ArgumentError, 'backlight on|off|status|inspect' unless args.empty? && %w[on off status inspect].include?(action)
      if action == 'inspect'
        exit(system(Backlight::HELPER, 'inspect') ? 0 : 1)
      elsif action == 'status'
        puts JSON.pretty_generate({enabled: Backlight.enabled?(runtime)})
      else
        FileUtils.mkdir_p(runtime, mode: 0700)
        temporary = File.join(runtime, "backlight.#{Process.pid}.tmp")
        File.write(temporary, JSON.generate({'enabled' => action == 'on'}) + "\n", perm: 0600)
        File.rename(temporary, File.join(runtime, 'backlight.json'))
        start if action == 'on'
        puts "Keyboard backlight alerts #{action == 'on' ? 'enabled' : 'disabled'}; the running controller picks up this setting automatically."
      end
    when 'doctor'
      raise 'Run make first' unless File.executable?(HELPER)
      exit(system(HELPER, 'inspect') ? 0 : 1)
    when 'demo'
      FileUtils.mkdir_p(runtime, mode: 0700)
      File.open(File.join(runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        raise 'Stop the controller before running demo' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        IO.popen([HELPER, 'serve'], 'r+') do |io|
          io.sync = true
          raise 'HID access unavailable' unless Timeout.timeout(2) { io.gets } == "ready\n"
          6.times do |i|
            io.write(i.even? ? '1' : '0')
            raise 'LED write failed' unless Timeout.timeout(2) { io.gets } == "ok\n"
            sleep 0.7
          end
          io.write('q')
        end
        raise 'Hardware demo failed; inspect daemon/system permissions' unless $?.success?
      end
      puts 'LED commands completed; confirm the physical light and Command shortcuts visually.'
    when 'event'
      raise ArgumentError, 'event AGENT SESSION STATE [TURN]' unless (3..4).cover?(args.size)
      event(*args); start
    when 'hook'
      raise ArgumentError, 'hook AGENT' unless args.size == 1
      input = Timeout.timeout(1) { STDIN.read(1_048_577) }
      raise ArgumentError, 'hook payload too large' if input.bytesize > 1_048_576
      start if hook(args[0], input)
    when 'start' then start
    when 'run' then run
    when 'stop'
      FileUtils.mkdir_p(runtime, mode: 0700)
      File.write(File.join(runtime, 'stop'), '')
    when 'clear'
      transaction { |state| state.clear }
    when 'status'
      snapshot = transaction { |state| { mode: mode(state), sessions: state.dup } }
      snapshot[:output] = JSON.parse(File.read(File.join(runtime, 'output.json'))) if File.exist?(File.join(runtime, 'output.json'))
      live_path = File.join(runtime, 'live-status.json')
      snapshot[:live_observer] = JSON.parse(File.read(live_path)) if File.exist?(live_path)
      File.open(File.join(runtime, 'daemon.lock'), File::RDWR | File::CREAT, 0600) do |lock|
        snapshot[:controller_running] = !lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      puts JSON.pretty_generate(snapshot)
    when 'install-hooks', 'uninstall-hooks'
      agent = args.shift
      raise ArgumentError, 'choose codex or claude' unless %w[codex claude].include?(agent)
      default = agent == 'codex' ? File.join(Dir.home, '.codex', 'hooks.json') : File.join(Dir.home, '.claude', 'settings.json')
      path = File.expand_path(args.shift || default)
      configure(agent, path, remove: command == 'uninstall-hooks')
      puts "#{command}: #{path}"
    when nil, 'help', '--help'
      puts "Agent Beacon: status lights; keyboard mappings are never changed.\nCommands: doctor, demo, start, stop, status, clear\n          backlight on|off|status|inspect (optional attention flashes)\n          event AGENT SESSION working|attention|done|idle|error [TURN]\n          install-hooks|uninstall-hooks codex|claude [CONFIG_PATH]\nEnvironment: AGENT_BEACON_HOME, AGENT_BEACON_SIMULATE=1 (test only)"
    else
      raise ArgumentError, 'Unknown command; use --help'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  hook_invocation = ARGV.first == 'hook'
  begin
    Beacon.main(ARGV)
  rescue StandardError => error
    warn "Agent Beacon: #{error.message}"
    exit(hook_invocation ? 0 : 1)
  end
end
