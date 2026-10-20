# frozen_string_literal: true
#
# One-time reset: marks every "updated" lesson of every user as re-read (DiscourseLms.clear_reviews:
# keeps completed_at, reactivates certificates, marks "lesson updated" notifications read).
# Meant for the switch to "only Update: edits flag lessons", when the old flags were mostly noise.
#
# Dry run (default):
#   bin/rails runner /tmp/clear_review_flags.rb
# Apply:
#   APPLY=1 bin/rails runner /tmp/clear_review_flags.rb
#
# Run as OS user `discourse` inside the app container.

flagged = Hash.new(0)
PluginStoreRow.where(plugin_name: DiscourseLms::PLUGIN_NAME).where("key LIKE ?", "completed\\_%").each do |row|
  data = JSON.parse(row.value) rescue {}
  flagged[row.key[/\Acompleted_(\d+)_/, 1].to_i] += 1 if data.is_a?(Hash) && data["needs_review"] == true
end
puts "#{flagged.values.sum} flagged lessons across #{flagged.size} users"

if ENV["APPLY"] == "1"
  cleared = User.where(id: flagged.keys).sum { |user| DiscourseLms.clear_reviews(user) }
  puts "cleared #{cleared}"
else
  puts "Dry run. APPLY=1 to clear."
end
