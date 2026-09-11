require 'socket'
require 'securerandom'

module Beacon
  # Retain only status fields; conversation text received over IPC is discarded.
  class CodexLiveState
    APPROVALS = %w[item/commandExecution/requestApproval item/fileChange/requestApproval item/permissions/requestApproval].freeze
    INPUTS = %w[item/tool/requestUserInput item/tool/requestOptionPicker mcpServer/elicitation/request].freeze

    def initialize
      @threads = {}
    end

    def apply(session, change)
      return false unless change.is_a?(Hash) && change['revision'].is_a?(Integer)
      old = @threads[session]
      if change['type'] == 'snapshot'
        incoming = change['conversationState']
        return false unless incoming.is_a?(Hash)
        state = {'requests' => project_requests(incoming['requests']), 'threadRuntimeStatus' => incoming['threadRuntimeStatus']}
      elsif change['type'] == 'patches'
        return false unless old && old['revision'] == change['baseRevision'] && change['revision'] > old['revision']
        return false unless change['patches'].is_a?(Array)
        state = JSON.parse(JSON.generate(old))
        change['patches'].each { |patch| apply_patch(state, patch) }
      else
        return false
      end
      runtime = state['threadRuntimeStatus']
      return false unless runtime.is_a?(Hash) && %w[active idle notLoaded systemError].include?(runtime['type'])
      return false if runtime['type'] == 'active' && !runtime['activeFlags'].is_a?(Array)
      state['revision'] = change['revision']
      @threads[session] = state
      flags = Array(runtime['activeFlags'])
      methods = state['requests'].map { |request| request['method'] }
      reason = if runtime['type'] == 'systemError'
                 'runtime_error'
               elsif runtime['type'] == 'active' && flags.include?('waitingOnApproval') && (methods & APPROVALS).any?
                 'approval_pending'
               elsif runtime['type'] == 'active' && (flags & %w[waitingOnUserInput waitingOnApproval]).any? && (methods & INPUTS).any?
                 'input_pending'
               end
      publish(session, reason)
      true
    rescue ArgumentError, TypeError, IndexError
      false
    end

    def project_requests(value)
      raise ArgumentError, 'invalid requests' unless value.is_a?(Array)
      value.map do |request|
        raise ArgumentError, 'invalid request' unless request.is_a?(Hash) && request['method'].is_a?(String)
        request.slice('id', 'method')
      end
    end

    def apply_patch(state, patch)
      raise ArgumentError, 'invalid patch' unless patch.is_a?(Hash) && patch['path'].is_a?(Array)
      path, op, value = patch.values_at('path', 'op', 'value')
      return unless %w[requests threadRuntimeStatus].include?(path.first)
      raise ArgumentError, 'invalid operation' unless %w[add replace remove].include?(op)
      if path.length == 1
        raise ArgumentError, 'missing status field' if op == 'remove'
        state[path.first] = path.first == 'requests' ? project_requests(value) : value
      elsif path.first == 'requests'
        index = path[1]
        list = state['requests']
        raise ArgumentError, 'invalid request index' unless index.is_a?(Integer) && index >= 0 && index <= list.length
        if path.length == 2
          raise IndexError if op != 'add' && index == list.length
          case op
          when 'remove' then list.delete_at(index)
          when 'add' then list.insert(index, project_requests([value]).first)
          when 'replace' then list[index] = project_requests([value]).first
          end
        elsif path.length == 3 && %w[id method].include?(path[2])
          raise IndexError if index == list.length
          raise ArgumentError if op == 'remove' || (path[2] == 'method' && !value.is_a?(String))
          list[index][path[2]] = value
        end
      else
        # Runtime status is currently replaced atomically; a new shape needs a fresh snapshot.
        raise ArgumentError, 'unsupported status patch'
      end
    end

    def publish(session, reason)
      Beacon.transaction do |state|
        key = Digest::SHA256.hexdigest("codex-live\0#{session}")
        if reason
          old = state[key]
          next if old && old['reason'] == reason
          state[key] = {'agent' => 'codex-live', 'session' => session, 'status' => 'attention',
                        'reason' => reason, 'at' => Time.now.to_f}
        else
          state.delete(key)
        end
      end
    end

    def disconnected(sessions = @threads.keys)
      sessions.each do |session|
        state = @threads[session]
        publish(session, 'observer_disconnected') if state && state.dig('threadRuntimeStatus', 'type') == 'active'
        @threads.delete(session)
      end
    end

    def remove(session)
      @threads.delete(session)
      publish(session, nil)
    end
  end

  # An observer only: never answers approvals, changes ownership, or starts/stops turns.
  class CodexLive
    MAX_FRAME = 32 * 1024 * 1024
    VERSION = 11

    def initialize(path = File.join(Dir.home, '.codex/ipc/ipc.sock'))
      @path = path
      @state = CodexLiveState.new
      @socket = nil
      @buffer = ''.b
      @subscriptions = {}
      @owners = {}
      @retry_at = 0
      @scan_at = 0
      @client = nil
      @initialize_deadline = nil
      @initialize_id = nil
      @reconcile_at = 0
    end

    def poll
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now >= @reconcile_at
        @reconcile_at = now + 1
        Beacon.transaction do |records|
          sessions = records.values.select { |s| s['agent'] == 'codex' }.map { |s| s['session'] }
          records.delete_if { |_, s| s['agent'] == 'codex-live' && !sessions.include?(s['session']) }
        end
      end
      connect if !@socket && now >= @retry_at
      return unless @socket
      drain
      raise 'IPC initialization timeout' if !@client && @initialize_deadline && now >= @initialize_deadline
      if @client && now >= @scan_at
        @scan_at = now + 1
        sessions = Beacon.transaction { |records| records.values.select { |s| s['agent'] == 'codex' }.map { |s| s['session'] } }
        (@subscriptions.keys - sessions).each do |session|
          follow(session, false)
          @subscriptions.delete(session)
          @owners.delete(session)
          @state.remove(session)
        end
        sessions.each do |session|
          last = @subscriptions[session]
          next if last == :ready || (last && now - last < 5)
          follow(session, true)
          @subscriptions[session] = now
        end
        File.open(File.join(Beacon.runtime, 'live-status.json'), 'w', 0600) do |file|
          file.write(JSON.generate({'connected' => true, 'protocol_version' => VERSION,
                                    'subscribed' => @subscriptions.values.count(:ready), 'at' => Time.now.to_f}))
        end
      end
    rescue StandardError => error
      warn "Agent Beacon live observer: #{error.class}"
      disconnect
    end

    def connect
      @retry_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      return unless File.exist?(@path)
      file = File.lstat(@path)
      directory = File.stat(File.dirname(@path))
      raise 'unsafe IPC endpoint' unless file.socket? && file.uid == Process.uid && directory.uid == Process.uid && directory.mode & 0022 == 0
      @socket = UNIXSocket.new(@path)
      @initialize_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      @initialize_id = SecureRandom.uuid
      send_message('type' => 'request', 'requestId' => @initialize_id, 'method' => 'initialize',
                   'version' => 0, 'params' => {'clientType' => 'agent-beacon'})
    end

    def send_message(message)
      json = JSON.generate(message)
      Timeout.timeout(1) { @socket.write([json.bytesize].pack('V') + json) }
    end

    def follow(session, following)
      send_message('type' => 'broadcast', 'method' => 'thread-stream-following-changed', 'sourceClientId' => @client,
                   'version' => 1, 'params' => {'conversationId' => session, 'hostId' => 'local', 'following' => following})
    end

    def drain
      128.times do
        bytes = @socket.read_nonblock(65_536, exception: false)
        break if bytes == :wait_readable
        raise EOFError if bytes.nil?
        @buffer << bytes
        while @buffer.bytesize >= 4
          length = @buffer.unpack1('V')
          raise 'unsupported IPC frame size' unless length.between?(1, MAX_FRAME)
          break if @buffer.bytesize < length + 4
          payload = @buffer.byteslice(4, length)
          @buffer = @buffer.byteslice(length + 4, @buffer.bytesize) || ''.b
          receive(JSON.parse(payload))
        end
      end
    end

    def receive(message)
      if message['type'] == 'client-discovery-request'
        send_message('type' => 'client-discovery-response', 'requestId' => message['requestId'], 'response' => {'canHandle' => false})
      elsif message['type'] == 'response' && message['requestId'] == @initialize_id
        raise 'IPC initialization rejected' unless message['resultType'] == 'success' && message['method'] == 'initialize'
        @client = message.dig('result', 'clientId')
        raise 'invalid IPC client ID' unless @client.is_a?(String) && !@client.empty?
        @initialize_deadline = nil
      elsif message['type'] == 'broadcast'
        params = message['params']
        return unless params.is_a?(Hash)
        case message['method']
        when 'thread-stream-state-changed'
          session = params['conversationId']
          return unless params['hostId'] == 'local' && @subscriptions.key?(session)
          raise 'unsupported IPC version' unless message['version'] == VERSION
          if @state.apply(session, params['change'])
            @subscriptions[session] = :ready
            @owners[session] = message['sourceClientId']
          else
            @subscriptions[session] = nil
          end
        when 'thread-stream-following-status-requested'
          session = params['conversationId']
          follow(session, true) if params['hostId'] == 'local' && @subscriptions.key?(session)
        when 'client-status-changed'
          if params['status'] == 'disconnected'
            sessions = @owners.select { |_, owner| owner == params['clientId'] }.keys
            @state.disconnected(sessions)
            sessions.each { |session| @subscriptions[session] = nil; @owners.delete(session) }
          end
        end
      end
    end

    def disconnect
      @state.disconnected
      close
      File.open(File.join(Beacon.runtime, 'live-status.json'), 'w', 0600) do |file|
        file.write(JSON.generate({'connected' => false, 'at' => Time.now.to_f}))
      end
      @retry_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    end

    def close
      @socket.close if @socket && !@socket.closed?
      @socket = nil
      @client = nil
      @initialize_id = nil
      @initialize_deadline = nil
      @buffer = ''.b
      @subscriptions.clear
      @owners.clear
    end
  end
end
