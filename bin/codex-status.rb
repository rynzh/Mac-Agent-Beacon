require 'json'
require 'open3'

module Beacon
  class CodexStatus
    def initialize(path, since: Time.now.to_i)
      @path = path
      @since = since
      @seen = {}
    end

    def self.failure_reason(code)
      name = code.is_a?(Hash) ? code.keys.first : code
      case name.to_s.downcase
      when 'usagelimitexceeded' then 'usage_limit'
      when 'httpconnectionfailed', 'responsestreamconnectionfailed', 'responsestreamdisconnected', 'responsetoomanyfailedattempts'
        'network_failure'
      when 'unauthorized', 'sandboxerror' then 'permission_failure'
      else 'task_failed'
      end
    end

    def poll
      return unless File.file?(@path)
      sql = <<~SQL
        SELECT t.thread_id,t.turn_id,t.status,t.started_at,t.completed_at,t.error_json
        FROM thread_turns t
        WHERE (t.started_at >= #{@since.to_i} OR t.completed_at >= #{@since.to_i})
        AND NOT EXISTS (SELECT 1 FROM thread_turns newer
          WHERE newer.thread_id=t.thread_id AND newer.rollout_ordinal>t.rollout_ordinal)
      SQL
      out, err, result = Open3.capture3('/usr/bin/sqlite3', '-readonly', '-cmd', '.timeout 1000', '-json', @path, sql)
      raise "Codex status database unavailable: #{err.strip}" unless result.success?
      rows = out.strip.empty? ? [] : JSON.parse(out)
      rows.each { |row| apply(row) }
    end

    def apply(row)
      session, turn, status = row.values_at('thread_id', 'turn_id', 'status')
      return unless [session, turn].all? { |value| value.is_a?(String) && !value.empty? && value.size <= 200 }
      return unless %w[inProgress completed failed interrupted].include?(status)
      fingerprint = [turn, status]
      return if @seen[session] == fingerprint
      applied = Beacon.transaction do |state|
        key = Digest::SHA256.hexdigest("codex\0#{session}")
        old = state[key]
        # A delayed database projection must not overwrite a newer hook turn.
        next false if old && old['turn'] && old['turn'] != turn && old['at'] >= row['started_at'].to_f + 1
        next true if status == 'inProgress' && old && old['turn'] == turn
        if status == 'interrupted'
          state.delete(key)
        else
          mode = {'inProgress' => 'working', 'completed' => 'done', 'failed' => 'error'}.fetch(status)
          reason = nil
          if status == 'failed'
            error = JSON.parse(row['error_json'] || '{}') rescue {}
            code = error.is_a?(Hash) ? error['codexErrorInfo'] : nil
            reason = self.class.failure_reason(code)
          end
          state[key] = {'agent' => 'codex', 'session' => session, 'turn' => turn,
                        'status' => mode, 'at' => Time.now.to_f, 'reason' => reason}
        end
        true
      end
      @seen[session] = fingerprint if applied
    end
  end
end
