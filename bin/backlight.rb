require 'json'
require 'open3'
require 'timeout'

module Beacon
  class Backlight
    HELPER = File.expand_path('../build/beacon-backlight', __dir__)

    def self.enabled?(runtime)
      path = File.join(runtime, 'backlight.json')
      return false unless File.file?(path)
      config = JSON.parse(File.read(path))
      config.is_a?(Hash) && config['enabled'] == true
    rescue JSON::ParserError, SystemCallError, IOError
      false
    end

    def initialize(helper: HELPER)
      @helper = helper
      @enabled = false
      @error = nil
      @previous = nil
    end

    def status
      {'enabled' => @enabled, 'active' => !@writer.nil?, 'error' => @error}
    end

    def update(mode, phase, enabled:)
      if !enabled || mode != 'attention'
        close
        @error = nil
      elsif !@error
        unless @writer
          @writer, @reader, @process = Open3.popen2(@helper, 'serve')
          @writer.sync = true
          raise 'backlight helper did not become ready' unless Timeout.timeout(1) { @reader.gets } == "ready\n"
        end
        if phase != @previous
          @writer.write(phase)
          raise 'backlight helper did not acknowledge phase' unless Timeout.timeout(1) { @reader.gets } == "ok\n"
          @previous = phase
        end
      end
      @enabled = enabled
      status
    rescue StandardError => error
      close
      @enabled = enabled
      @error = error.message
      warn "Agent Beacon optional backlight: #{@error}"
      status
    end

    def close
      @writer.close if @writer && !@writer.closed?
      if @process && !@process.join(0.5)
        Process.kill('TERM', @process.pid) rescue Errno::ESRCH
        unless @process.join(0.5)
          Process.kill('KILL', @process.pid) rescue Errno::ESRCH
          @process.join(0.5)
        end
      end
      @reader.close if @reader && !@reader.closed?
    ensure
      @writer = @reader = @process = @previous = nil
    end
  end
end
