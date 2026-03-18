# frozen_string_literal: true

# name: discourse-lms
# about: Turns Discourse categories into structured LMS courses with completion tracking, ordered lessons, and progress indicators.
# version: 0.1.1
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
  end

  # --- Custom Fields ---

  # Category: is this an LMS course?
  Site.preloaded_category_custom_fields << "lms_enabled"
  register_category_custom_field_type("lms_enabled", :boolean)

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
    get "/dashboard" => "lms#dashboard"
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

  # --- Serializers ---

  # Expose lms_enabled on categories
  add_to_serializer(:basic_category, :lms_enabled) do
    object.custom_fields["lms_enabled"]
  end

  add_to_serializer(:basic_category, :include_lms_enabled?) do
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

      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: user.id,
        topic_id: topic.id,
        post_number: 1,
        data: {
          topic_title: topic.title,
          message: "discourse_lms.notifications.lesson_updated"
        }.to_json
      )
    end
  end
end
