# frozen_string_literal: true
#
# Sets lms_position for all lessons of a category and switches it to manual sorting.
#
# Dry run (default):
#   CATEGORY_ID=39 ORDER=989,1041,355 bin/rails runner /tmp/set_manual_order.rb
# Apply:
#   APPLY=1 CATEGORY_ID=39 ORDER=... bin/rails runner /tmp/set_manual_order.rb
#
# ORDER must list every lesson of the category exactly once (aborts otherwise).
# Run as OS user `discourse` inside the app container.

category = Category.find(ENV.fetch("CATEGORY_ID"))
order = ENV.fetch("ORDER").split(",").map { |id| Integer(id.strip) }

topics = Topic.where(category_id: category.id, archetype: Archetype.default, deleted_at: nil).index_by(&:id)
missing = topics.keys - order
unknown = order - topics.keys
abort "ORDER has duplicates" if order.uniq.size != order.size
abort "Not in ORDER: #{missing.inspect}" if missing.any?
abort "Not a lesson of category #{category.id}: #{unknown.inspect}" if unknown.any?

puts "#{category.name} (#{category.id}): lms_sort_order #{category.custom_fields["lms_sort_order"].inspect} -> \"manual\""
order.each_with_index do |id, idx|
  t = topics[id]
  old = Array(t.custom_fields["lms_position"]).last
  puts format("  %2d (was %-3s) %s %s", idx + 1, old.inspect, t.visible ? " " : "U", t.title)
end

if ENV["APPLY"] == "1"
  Topic.transaction do
    order.each_with_index do |id, idx|
      t = topics[id]
      t.custom_fields["lms_position"] = idx + 1
      t.save_custom_fields
    end
    category.custom_fields["lms_sort_order"] = "manual"
    category.save_custom_fields
  end
  Site.clear_cache
  puts "Applied."
else
  puts "Dry run (U = unlisted). Re-run with APPLY=1 to write."
end
