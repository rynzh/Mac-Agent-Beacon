require 'json'
require 'open3'
require 'fileutils'
require 'time'

root = File.expand_path('..', __dir__)
config_path = File.join(Dir.home, '.config/karabiner/karabiner.json')
original = File.binread(config_path)
config = JSON.parse(original)
profile = config.fetch('profiles').find { |item| item['selected'] }
abort 'No selected profile' unless profile
abort 'Trial expects no existing per-device rules; inspect manually first' if profile.fetch('devices', []).any?
match = JSON.generate({'Product' => 'Apple Internal Keyboard / Trackpad', 'PrimaryUsagePage' => 1, 'PrimaryUsage' => 6})
backup = File.join(root, '.runtime', "mapping-trial-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
FileUtils.mkdir_p(backup, mode: 0700)
File.open(File.join(backup, 'karabiner.json'), 'w', 0600) { |file| file.write(original) }
profile['devices'] = [{'identifiers' => {'vendor_id' => 0, 'product_id' => 0, 'is_keyboard' => true, 'is_pointing_device' => false}, 'ignore' => true}]
trial_config = JSON.pretty_generate(config) + "\n"
def replace_config(path, text)
  temporary = "#{path}.agent-beacon-trial.tmp"
  File.open(temporary, 'w', 0600) { |file| file.write(text) }
  File.rename(temporary, path)
end
mapped = false
begin
  replace_config(config_path, trial_config)
  sleep 2
  before, error, status = Open3.capture3('/usr/bin/hidutil', 'property', '--matching', match, '--get', 'UserKeyMapping')
  File.write(File.join(backup, 'mapping-before.txt'), before)
  empty_mapping = before.include?('(null)') || before.match?(/UserKeyMapping\s+\(\s*\)\s*\z/)
  abort "Cannot safely replace existing mapping: #{before} #{error}" unless status.success? && empty_mapping
  mapping = [[0x39, 0xe3], [0xe7, 0xe0], [0xe6, 0x6e]].map do |from, to|
    {'HIDKeyboardModifierMappingSrc' => 0x700000000 | from, 'HIDKeyboardModifierMappingDst' => 0x700000000 | to}
  end
  mapped = true
  raise 'Mapping write failed' unless system('/usr/bin/hidutil', 'property', '--matching', match, '--set', JSON.generate({'UserKeyMapping' => mapping}))
  system('/usr/bin/hidutil', 'property', '--matching', match, '--get', 'UserKeyMapping')
  puts 'Trial mapping active on built-in keyboard only. Testing LED now.'
  STDOUT.flush
  raise 'LED demo failed; restoring settings' unless system('/usr/bin/ruby', File.join(root, 'bin/agent-beacon.rb'), 'demo')
  puts 'LED commands succeeded. Test Caps Lock as Command, right Command as Control, right Option as F19 now. Automatic restore in 45 seconds.'
  STDOUT.flush
  sleep 45
ensure
  if mapped
    restored = system('/usr/bin/hidutil', 'property', '--matching', match, '--set', '{"UserKeyMapping":[]}')
    warn 'WARNING: temporary system mapping could not be cleared' unless restored
  end
  current = JSON.parse(File.read(config_path))
  current_profile = current.fetch('profiles').find { |item| item['name'] == profile['name'] }
  if current_profile && current_profile['devices'] == profile['devices']
    current_profile.delete('devices')
    if current == JSON.parse(original)
      replace_config(config_path, original)
    else
      replace_config(config_path, JSON.pretty_generate(current) + "\n")
    end
    puts "Karabiner restored; backup: #{backup}"
  else
    warn "Configuration changed during trial; inspect backup before restoring: #{backup}"
  end
end
