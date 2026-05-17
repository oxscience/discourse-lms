# frozen_string_literal: true

module DiscourseLms
  class LmsController < ::ApplicationController
    requires_plugin DiscourseLms::PLUGIN_NAME
    before_action :ensure_logged_in

    # POST /lms/complete/:topic_id
    # Toggle completion status for current user
    def toggle_complete
      topic = Topic.find(params[:topic_id])
      guardian.ensure_can_see!(topic)

      category = topic.category
      raise Discourse::InvalidAccess unless category&.custom_fields&.[]("lms_enabled")

      key = "completed_#{current_user.id}_#{topic.id}"
      existing = PluginStore.get(PLUGIN_NAME, key)

      if existing
        PluginStore.remove(PLUGIN_NAME, key)
        DiscourseLms.mark_certificate_outdated(current_user.id, category.id)
        render json: { completed: false, needs_review: false }
      else
        PluginStore.set(PLUGIN_NAME, key, {
          completed_at: Time.now.iso8601,
          needs_review: false
        })
        cert = DiscourseLms.issue_certificate_if_complete(current_user, category)
        render json: { completed: true, needs_review: false, certificate: cert }
      end
    end

    # GET /lms/certificates
    # Returns all certificates for the current user (active + outdated)
    def certificates
      rows = PluginStoreRow.where(plugin_name: PLUGIN_NAME)
                           .where("key LIKE ?", "cert_#{current_user.id}_%")
      certs = rows.map do |row|
        data = JSON.parse(row.value) rescue nil
        next unless data.is_a?(Hash)
        data
      end.compact.sort_by { |c| c["issued_at"].to_s }.reverse

      render json: { certificates: certs }
    end

    # PUT /lms/certificate/:category_id
    # Update display_name on an existing cert and store it as the user's
    # default for future certs. Only the cert's owner can update it.
    def update_certificate
      category_id = params[:category_id].to_i
      raw_name = params[:display_name].to_s.strip
      raise Discourse::InvalidParameters.new(:display_name) if raw_name.empty?
      display_name = raw_name[0, 120]

      cert_key = "cert_#{current_user.id}_#{category_id}"
      cert = PluginStore.get(PLUGIN_NAME, cert_key)
      raise Discourse::NotFound unless cert.is_a?(Hash)

      cert["display_name"] = display_name
      PluginStore.set(PLUGIN_NAME, cert_key, cert)

      current_user.custom_fields["lms_cert_name"] = display_name
      current_user.save_custom_fields

      render json: { certificate: cert }
    end

    # GET /lms/progress/:category_id
    # Returns completion progress for current user in a course category
    def category_progress
      category = Category.find(params[:category_id])
      raise Discourse::InvalidAccess unless category.custom_fields["lms_enabled"]

      topic_ids = Topic.where(category_id: category.id)
                       .where(archetype: Archetype.default)
                       .where(deleted_at: nil)
                       .pluck(:id)

      total = topic_ids.size
      completed = 0
      needs_review = 0

      topic_ids.each do |tid|
        data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{tid}")
        next unless data
        completed += 1
        needs_review += 1 if data.is_a?(Hash) && data["needs_review"]
      end

      render json: {
        category_id: category.id,
        total: total,
        completed: completed,
        needs_review: needs_review,
        percent: total > 0 ? ((completed.to_f / total) * 100).round : 0
      }
    end

    # GET /lms/status/:topic_id
    # Returns completion status for current user on a single topic
    def topic_status
      topic = Topic.find(params[:topic_id])
      guardian.ensure_can_see!(topic)

      category = topic.category
      raise Discourse::InvalidAccess unless category&.custom_fields&.[]("lms_enabled")

      data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{topic.id}")

      render json: {
        topic_id: topic.id,
        completed: data.present?,
        needs_review: data.is_a?(Hash) && data["needs_review"] == true
      }
    end

    # GET /lms/lessons/:category_id
    # Returns ordered list of lessons in a course category with completion status
    # Sort order is determined by category custom field lms_sort_order:
    #   "created" (default) — by topic creation date
    #   "title"  — alphabetically by title
    #   "manual" — by lms_position custom field
    def category_lessons
      category = Category.find(params[:category_id])
      raise Discourse::InvalidAccess unless category.custom_fields["lms_enabled"]

      sort_order = category.custom_fields["lms_sort_order"].presence || "created"

      topics = Topic.where(category_id: category.id)
                    .where(archetype: Archetype.default)
                    .where(deleted_at: nil)
                    .select(:id, :title, :slug, :created_at)

      lessons = topics.map do |t|
        pos = t.custom_fields["lms_position"]
        data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{t.id}")
        {
          id: t.id,
          title: t.title,
          slug: t.slug,
          position: pos.to_i,
          created_at: t.created_at.iso8601,
          completed: data.present?,
          needs_review: data.is_a?(Hash) && data["needs_review"] == true
        }
      end

      case sort_order
      when "title"
        lessons.sort_by! { |l| l[:title].downcase }
      when "manual"
        lessons.sort_by! { |l| [l[:position], l[:created_at]] }
      else # "created"
        lessons.sort_by! { |l| l[:created_at] }
      end

      render json: { category_id: category.id, sort_order: sort_order, lessons: lessons }
    end

    # PUT /lms/reorder/:category_id
    # Admin-only: set lesson positions
    # Expects params[:positions] = { topic_id => position, ... }
    def reorder
      guardian.ensure_is_admin!

      category = Category.find(params[:category_id])
      raise Discourse::InvalidAccess unless category.custom_fields["lms_enabled"]

      positions = params.require(:positions).permit!.to_h

      positions.each do |topic_id, position|
        topic = Topic.find_by(id: topic_id, category_id: category.id)
        next unless topic
        topic.custom_fields["lms_position"] = position.to_i
        topic.save_custom_fields
      end

      render json: { success: true }
    end
  end
end
