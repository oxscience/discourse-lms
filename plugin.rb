# frozen_string_literal: true

# name: discourse-lms
# about: Turns Discourse categories into structured LMS courses with completion tracking, ordered lessons, and progress indicators.
# version: 0.2.0
# authors: Pat
# url: https://github.com/your-org/discourse-lms-plugin
# required_version: 2.7.0

enabled_site_setting :lms_enabled

after_initialize do
  module ::DiscourseLms
    PLUGIN_NAME = "discourse-lms"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseLms
    end

    # Issue a certificate when the user has every topic in `category` marked
    # complete and none of them flagged needs_review. Idempotent: re-activates
    # a previously outdated cert instead of issuing a new one.
    def self.issue_certificate_if_complete(user, category)
      return nil unless user && category
      return nil unless category.custom_fields["lms_enabled"]

      topic_ids = Topic.where(category_id: category.id, archetype: Archetype.default, deleted_at: nil).pluck(:id)
      return nil if topic_ids.empty?

      all_valid = topic_ids.all? do |tid|
        data = PluginStore.get(PLUGIN_NAME, "completed_#{user.id}_#{tid}")
        data.present? && !(data.is_a?(Hash) && data["needs_review"] == true)
      end
      return nil unless all_valid

      cert_key = "cert_#{user.id}_#{category.id}"
      existing = PluginStore.get(PLUGIN_NAME, cert_key)

      if existing.is_a?(Hash)
        # Reactivate outdated cert and surface it; otherwise stay silent so
        # repeat toggles don't re-trigger the celebration modal.
        if existing["status"] == "outdated"
          existing["status"] = "active"
          existing["reactivated_at"] = Time.now.iso8601
          PluginStore.set(PLUGIN_NAME, cert_key, existing)
          return existing
        end
        return nil
      end

      display_name = (user.custom_fields["lms_cert_name"].presence ||
                      user.name.presence ||
                      user.username).to_s

      cert = {
        "cert_id" => SecureRandom.urlsafe_base64(16),
        "issued_at" => Time.now.iso8601,
        "display_name" => display_name,
        "category_id" => category.id,
        "category_name" => category.name,
        "status" => "active"
      }
      PluginStore.set(PLUGIN_NAME, cert_key, cert)
      cert
    end

    # Mark an active cert as outdated. No-op if cert doesn't exist or is
    # already outdated.
    def self.mark_certificate_outdated(user_id, category_id)
      return unless user_id && category_id
      cert_key = "cert_#{user_id}_#{category_id}"
      cert = PluginStore.get(PLUGIN_NAME, cert_key)
      return unless cert.is_a?(Hash) && cert["status"] == "active"
      cert["status"] = "outdated"
      cert["outdated_at"] = Time.now.iso8601
      PluginStore.set(PLUGIN_NAME, cert_key, cert)
    end
  end

  # --- Custom Fields ---

  # Category: is this an LMS course?
  Site.preloaded_category_custom_fields << "lms_enabled"
  register_category_custom_field_type("lms_enabled", :boolean)


  # Category: sort order for lessons (created, title, manual)
  Site.preloaded_category_custom_fields << "lms_sort_order"
  register_category_custom_field_type("lms_sort_order", :string)


  # Category: is this a Roadmap (voting overview)?
  Site.preloaded_category_custom_fields << "roadmap_enabled"
  register_category_custom_field_type("roadmap_enabled", :boolean)


  # Topic: lesson position within course — preload in topic lists
  register_topic_custom_field_type("lms_position", :integer)
  TopicList.preloaded_custom_fields << "lms_position"

  # --- Load Controller ---
  require_relative "app/controllers/lms_controller"

  # --- Routes ---
  DiscourseLms::Engine.routes.draw do
    post "/complete/:topic_id" => "lms#toggle_complete"
    get "/status/:topic_id" => "lms#topic_status"
    get "/progress/:category_id" => "lms#category_progress"
    get "/lessons/:category_id" => "lms#category_lessons"
    put "/reorder/:category_id" => "lms#reorder"
    get "/certificates" => "lms#certificates"
    put "/certificate/:category_id" => "lms#update_certificate"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseLms::Engine, at: "/lms"
  end


  # --- Helper: check if a topic belongs to an LMS category ---
  lms_category_ids_cache = {}
  lms_category_check = lambda do |category_id|
    return false unless category_id
    unless lms_category_ids_cache.key?(category_id)
      cat = Category.find_by(id: category_id)
      lms_category_ids_cache[category_id] = cat&.custom_fields&.[]("lms_enabled") == true
    end
    lms_category_ids_cache[category_id]
  end

  # Clear cache when categories change
  on(:site_setting_changed) { lms_category_ids_cache.clear }

  # --- Server-side topic ordering for LMS categories ---
  # Discourse normally sorts category topic lists by activity (bumped_at).
  # For LMS categories we sort by the configured lms_sort_order
  # (created | title | manual) so the list renders in the correct order on
  # first paint — no client-side DOM reshuffling, no flicker, no races.
  module ::DiscourseLms::TopicQueryLmsOrdering
    def apply_ordering(result, options = {})
      category_id = options[:category] || @options[:category]
      return super unless category_id

      cat = Category.find_by(id: category_id.to_i)
      return super unless cat&.custom_fields&.[]("lms_enabled")

      sort_order = cat.custom_fields["lms_sort_order"].presence || "created"
      case sort_order
      when "title"
        result.reorder("topics.title ASC")
      when "manual"
        result
          .joins("LEFT JOIN topic_custom_fields tcf_pos ON tcf_pos.topic_id = topics.id AND tcf_pos.name = 'lms_position'")
          .reorder(Arel.sql("CAST(COALESCE(tcf_pos.value, '99999') AS INTEGER) ASC, topics.created_at ASC"))
      else # "created"
        result.reorder("topics.created_at ASC")
      end
    end
  end

  reloadable_patch { ::TopicQuery.prepend(::DiscourseLms::TopicQueryLmsOrdering) }

  # --- Serializers ---

  # Expose lms_enabled on categories
  add_to_serializer(:basic_category, :lms_enabled) do
    object.custom_fields["lms_enabled"]
  end

  add_to_serializer(:basic_category, :include_lms_enabled?) do
    SiteSetting.lms_enabled
  end

  # Expose lms_sort_order on categories (default: "created")
  add_to_serializer(:basic_category, :lms_sort_order) do
    object.custom_fields["lms_sort_order"].presence || "created"
  end

  add_to_serializer(:basic_category, :include_lms_sort_order?) do
    SiteSetting.lms_enabled
  end

  # Expose roadmap_enabled on categories
  add_to_serializer(:basic_category, :roadmap_enabled) do
    object.custom_fields["roadmap_enabled"]
  end

  add_to_serializer(:basic_category, :include_roadmap_enabled?) do
    SiteSetting.lms_enabled
  end

  # Expose lms_position on topics (single topic view)
  add_to_serializer(:topic_view, :lms_position) do
    object.topic.custom_fields["lms_position"]
  end

  add_to_serializer(:topic_view, :include_lms_position?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.topic.category_id)
  end

  # Expose completion status on topic list items — only for LMS categories
  add_to_serializer(:topic_list_item, :lms_completed) do
    return false unless scope.user
    PluginStore.get(
      DiscourseLms::PLUGIN_NAME,
      "completed_#{scope.user.id}_#{object.id}"
    ).present?
  end

  add_to_serializer(:topic_list_item, :include_lms_completed?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.category_id)
  end

  add_to_serializer(:topic_list_item, :lms_needs_review) do
    return false unless scope.user
    data = PluginStore.get(
      DiscourseLms::PLUGIN_NAME,
      "completed_#{scope.user.id}_#{object.id}"
    )
    return false unless data
    data.is_a?(Hash) && data["needs_review"] == true
  end

  add_to_serializer(:topic_list_item, :include_lms_needs_review?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.category_id)
  end

  add_to_serializer(:topic_list_item, :lms_position) do
    object.custom_fields["lms_position"]
  end

  add_to_serializer(:topic_list_item, :include_lms_position?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.category_id)
  end

  # Expose completion on topic_view too (for single topic page)
  add_to_serializer(:topic_view, :lms_completed) do
    return false unless scope.user
    PluginStore.get(
      DiscourseLms::PLUGIN_NAME,
      "completed_#{scope.user.id}_#{object.topic.id}"
    ).present?
  end

  add_to_serializer(:topic_view, :include_lms_completed?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.topic.category_id)
  end

  add_to_serializer(:topic_view, :lms_needs_review) do
    return false unless scope.user
    data = PluginStore.get(
      DiscourseLms::PLUGIN_NAME,
      "completed_#{scope.user.id}_#{object.topic.id}"
    )
    return false unless data
    data.is_a?(Hash) && data["needs_review"] == true
  end

  add_to_serializer(:topic_view, :include_lms_needs_review?) do
    SiteSetting.lms_enabled && lms_category_check.call(object.topic.category_id)
  end

  # --- Event Hooks ---

  # When a topic's first post is revised, mark completions as "needs_review"
  on(:post_edited) do |post, _topic_changed, _revisor|
    next unless post.post_number == 1
    next unless SiteSetting.lms_enabled

    topic = post.topic
    next unless topic

    category = topic.category
    next unless category && category.custom_fields["lms_enabled"]

    # Find all completions for this topic and flag them
    rows = PluginStoreRow.where(
      plugin_name: DiscourseLms::PLUGIN_NAME
    ).where("key LIKE ?", "completed_%_#{topic.id}")

    rows.each do |row|
      data = JSON.parse(row.value) rescue {}
      next if data["needs_review"] == true

      data["needs_review"] = true
      data["revised_at"] = Time.now.iso8601
      row.update!(value: data.to_json, type_name: "JSON")

      # Send notification to the user
      user_id = row.key.match(/completed_(\d+)_/)[1].to_i
      user = User.find_by(id: user_id)
      next unless user

      DiscourseLms.mark_certificate_outdated(user_id, category.id)

      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: user.id,
        topic_id: topic.id,
        post_number: 1,
        data: {
          topic_title: topic.title,
          display_username: post.user&.username || "system",
          message: "discourse_lms.notifications.lesson_updated"
        }.to_json
      )
    end
  end
end
