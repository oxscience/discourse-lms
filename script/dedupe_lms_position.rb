# frozen_string_literal: true
#
# Lists (and optionally removes) duplicate lms_position rows in topic_custom_fields.
# Duplicates make topic.custom_fields["lms_position"] return an Array.
#
# Read-only (default):
#   bin/rails runner /tmp/dedupe_lms_position.rb
# Cleanup — keeps the newest row (highest id) per topic, deletes the rest:
#   APPLY=1 bin/rails runner /tmp/dedupe_lms_position.rb
#
# Run as OS user `discourse` inside the app container.

rows = DB.query(<<~SQL)
  SELECT tcf.topic_id, t.category_id, t.title, tcf.id, tcf.value, tcf.created_at
  FROM topic_custom_fields tcf
  JOIN topics t ON t.id = tcf.topic_id
  WHERE tcf.name = 'lms_position'
    AND tcf.topic_id IN (
      SELECT topic_id FROM topic_custom_fields
      WHERE name = 'lms_position'
      GROUP BY 1 HAVING count(*) > 1
    )
  ORDER BY tcf.topic_id, tcf.id
SQL

if rows.empty?
  puts "No duplicate lms_position rows."
  exit
end

rows.group_by(&:topic_id).each do |topic_id, dupes|
  puts "topic #{topic_id} (cat #{dupes.first.category_id}) #{dupes.first.title}"
  dupes.each_with_index do |r, i|
    keep = i == dupes.size - 1 ? "KEEP  " : "DELETE"
    puts "  #{keep} id=#{r.id} value=#{r.value} created_at=#{r.created_at.iso8601(3)}"
  end
end

if ENV["APPLY"] == "1"
  deleted = DB.exec(<<~SQL)
    DELETE FROM topic_custom_fields
    WHERE name = 'lms_position'
      AND id NOT IN (
        SELECT max(id) FROM topic_custom_fields
        WHERE name = 'lms_position' GROUP BY topic_id
      )
  SQL
  puts "Deleted #{deleted} rows."
else
  puts "Dry run. Re-run with APPLY=1 to delete the rows marked DELETE."
end
