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
        render json: { completed: false, needs_review: false }
      else
        PluginStore.set(PLUGIN_NAME, key, {
          completed_at: Time.now.iso8601,
          needs_review: false
        })
        render json: { completed: true, needs_review: false }
      end
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
    def category_lessons
      category = Category.find(params[:category_id])
      raise Discourse::InvalidAccess unless category.custom_fields["lms_enabled"]

      topics = Topic.where(category_id: category.id)
                    .where(archetype: Archetype.default)
                    .where(deleted_at: nil)
                    .select(:id, :title, :slug)

      lessons = topics.map do |t|
        pos = t.custom_fields["lms_position"]
        data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{t.id}")
        {
          id: t.id,
          title: t.title,
          slug: t.slug,
          position: pos.to_i,
          completed: data.present?,
          needs_review: data.is_a?(Hash) && data["needs_review"] == true
        }
      end

      lessons.sort_by! { |l| l[:position] }

      render json: { category_id: category.id, lessons: lessons }
    end

    # GET /lms/dashboard
    # Returns all LMS courses with progress for current user
    def dashboard
      lms_categories = Category.where(id:
        CategoryCustomField.where(name: "lms_enabled", value: "t").pluck(:category_id)
      ).select(:id, :name, :slug, :color)

      courses = []

      lms_categories.each do |cat|
        next unless guardian.can_see?(cat)

        topic_ids = Topic.where(category_id: cat.id)
                         .where(archetype: Archetype.default)
                         .where(deleted_at: nil)
                         .pluck(:id)

        total = topic_ids.size
        next if total == 0

        completed = 0
        needs_review = 0

        topic_ids.each do |tid|
          data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{tid}")
          next unless data
          completed += 1
          needs_review += 1 if data.is_a?(Hash) && data["needs_review"]
        end

        # Find next uncompleted lesson
        topics = Topic.where(category_id: cat.id)
                      .where(archetype: Archetype.default)
                      .where(deleted_at: nil)
                      .select(:id, :title, :slug)

        lessons = topics.map do |t|
          pos = t.custom_fields["lms_position"]
          data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{t.id}")
          { id: t.id, title: t.title, slug: t.slug, position: pos.to_i, completed: data.present? }
        end.sort_by { |l| l[:position] }

        next_lesson = lessons.find { |l| !l[:completed] }

        course = {
          category_id: cat.id,
          name: cat.name,
          slug: cat.slug,
          color: cat.color,
          total: total,
          completed: completed,
          needs_review: needs_review,
          percent: ((completed.to_f / total) * 100).round
        }
        course[:next_lesson] = { id: next_lesson[:id], title: next_lesson[:title], slug: next_lesson[:slug] } if next_lesson

        courses << course
      end

      # Sort: in-progress first, then not-started, then completed
      courses.sort_by! { |c| c[:percent] == 100 ? 2 : (c[:percent] > 0 ? 0 : 1) }

      render json: { courses: courses }
    end

    # GET /lms/kurse
    # Full HTML page showing all courses with progress
    def kurse_page
      lms_categories = Category.where(id:
        CategoryCustomField.where(name: "lms_enabled", value: "t").pluck(:category_id)
      ).select(:id, :name, :slug, :color, :parent_category_id)

      courses = []

      lms_categories.each do |cat|
        next unless guardian.can_see?(cat)

        topic_ids = Topic.where(category_id: cat.id)
                         .where(archetype: Archetype.default)
                         .where(deleted_at: nil)
                         .pluck(:id)

        total = topic_ids.size
        next if total == 0

        completed = 0
        needs_review = 0

        topic_ids.each do |tid|
          data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{tid}")
          next unless data
          completed += 1
          needs_review += 1 if data.is_a?(Hash) && data["needs_review"]
        end

        # Find next uncompleted lesson
        topics = Topic.where(category_id: cat.id)
                      .where(archetype: Archetype.default)
                      .where(deleted_at: nil)
                      .select(:id, :title, :slug)

        lessons = topics.map do |t|
          pos = t.custom_fields["lms_position"]
          data = PluginStore.get(PLUGIN_NAME, "completed_#{current_user.id}_#{t.id}")
          { id: t.id, title: t.title, slug: t.slug, position: pos.to_i, completed: data.present? }
        end.sort_by { |l| l[:position] }

        next_lesson = lessons.find { |l| !l[:completed] }

        # Build category URL
        parent = cat.parent_category_id ? Category.find_by(id: cat.parent_category_id) : nil
        cat_url = if parent
          "/c/#{parent.slug}/#{cat.slug}/#{cat.id}"
        else
          "/c/#{cat.slug}/#{cat.id}"
        end

        pct = ((completed.to_f / total) * 100).round

        courses << {
          name: cat.name,
          color: cat.color,
          url: cat_url,
          total: total,
          completed: completed,
          needs_review: needs_review,
          percent: pct,
          next_lesson: next_lesson
        }
      end

      # Sort: in-progress first, then not-started, then completed
      courses.sort_by! { |c| c[:percent] == 100 ? 2 : (c[:percent] > 0 ? 0 : 1) }

      # Build HTML
      base_url = Discourse.base_url
      site_title = SiteSetting.title
      logo_url = SiteSetting.logo_small_url.presence || SiteSetting.logo_url.presence

      cards_html = courses.map do |c|
        next_html = ""
        if c[:next_lesson]
          nl = c[:next_lesson]
          next_html = %(<div class="lms-card-next"><span class="lms-card-next-label">N\u00e4chste Lektion:</span> <a href="/t/#{nl[:slug]}/#{nl[:id]}">#{ERB::Util.html_escape(nl[:title])}</a></div>)
        elsif c[:percent] == 100
          next_html = '<div class="lms-card-next lms-card-complete-msg">&#10003; Alle Lektionen abgeschlossen</div>'
        end

        review_html = ""
        if c[:needs_review] > 0
          review_html = %(<div class="lms-card-review">#{c[:needs_review]} Lektion#{"en" if c[:needs_review] > 1} aktualisiert</div>)
        end

        <<~HTML
          <a href="#{c[:url]}" class="lms-card" style="border-left: 4px solid ##{c[:color]}">
            <div class="lms-card-header">
              <h3 class="lms-card-title">#{ERB::Util.html_escape(c[:name])}</h3>
              <span class="lms-card-percent">#{c[:percent]}%</span>
            </div>
            <div class="lms-card-progress-track">
              <div class="lms-card-progress-fill" style="width:#{c[:percent]}%"></div>
            </div>
            <div class="lms-card-meta">#{c[:completed]} von #{c[:total]} Lektionen</div>
            #{review_html}
            #{next_html}
          </a>
        HTML
      end.join

      if courses.empty?
        cards_html = '<div class="lms-empty">Noch keine Kurse vorhanden.</div>'
      end

      html = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Meine Kurse - #{ERB::Util.html_escape(site_title)}</title>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, sans-serif;
              background: #1a1a2e;
              color: #d4d4dc;
              min-height: 100vh;
            }
            .lms-page-header {
              background: #16213e;
              border-bottom: 1px solid #2a2a4a;
              padding: 0.75em 1.5em;
              display: flex;
              align-items: center;
              gap: 1em;
            }
            .lms-page-header img {
              height: 28px;
            }
            .lms-page-header a {
              color: #d4d4dc;
              text-decoration: none;
              font-size: 0.95em;
            }
            .lms-page-header a:hover {
              color: #fff;
            }
            .lms-page-content {
              max-width: 800px;
              margin: 0 auto;
              padding: 2em 1.5em;
            }
            .lms-page-title {
              font-size: 1.6em;
              font-weight: 700;
              margin-bottom: 0.3em;
              color: #eee;
            }
            .lms-page-subtitle {
              color: #888;
              margin-bottom: 2em;
              font-size: 0.95em;
            }
            .lms-cards {
              display: flex;
              flex-direction: column;
              gap: 1em;
            }
            .lms-card {
              display: block;
              background: #16213e;
              border-radius: 8px;
              padding: 1.25em 1.5em;
              text-decoration: none;
              color: #d4d4dc;
              transition: background 0.15s, transform 0.1s;
            }
            .lms-card:hover {
              background: #1a2744;
              transform: translateY(-1px);
            }
            .lms-card-header {
              display: flex;
              justify-content: space-between;
              align-items: center;
              margin-bottom: 0.75em;
            }
            .lms-card-title {
              font-size: 1.1em;
              font-weight: 600;
              color: #eee;
              margin: 0;
            }
            .lms-card-percent {
              font-size: 1.1em;
              font-weight: 700;
              color: #6ec4e8;
            }
            .lms-card-progress-track {
              height: 6px;
              background: #2a2a4a;
              border-radius: 3px;
              overflow: hidden;
              margin-bottom: 0.6em;
            }
            .lms-card-progress-fill {
              height: 100%;
              background: #6ec4e8;
              border-radius: 3px;
              transition: width 0.4s ease;
            }
            .lms-card-meta {
              font-size: 0.82em;
              color: #888;
            }
            .lms-card-review {
              font-size: 0.82em;
              color: #e8b86e;
              margin-top: 0.3em;
            }
            .lms-card-next {
              margin-top: 0.5em;
              font-size: 0.85em;
              color: #888;
            }
            .lms-card-next a {
              color: #6ec4e8;
              text-decoration: none;
            }
            .lms-card-next a:hover {
              text-decoration: underline;
            }
            .lms-card-next-label {
              color: #666;
            }
            .lms-card-complete-msg {
              color: #6ecf8e;
            }
            .lms-empty {
              text-align: center;
              color: #666;
              padding: 3em;
              font-size: 1.1em;
            }
            .lms-back-link {
              display: inline-block;
              margin-top: 2em;
              color: #6ec4e8;
              text-decoration: none;
              font-size: 0.9em;
            }
            .lms-back-link:hover {
              text-decoration: underline;
            }
            @media (max-width: 600px) {
              .lms-page-content { padding: 1.5em 1em; }
              .lms-card { padding: 1em; }
              .lms-page-title { font-size: 1.3em; }
            }
          </style>
        </head>
        <body>
          <div class="lms-page-header">
            #{logo_url ? %(<a href="#{base_url}"><img src="#{logo_url}" alt=""></a>) : ""}
            <a href="#{base_url}">#{ERB::Util.html_escape(site_title)}</a>
          </div>
          <div class="lms-page-content">
            <h1 class="lms-page-title">Meine Kurse</h1>
            <p class="lms-page-subtitle">Dein Lernfortschritt im \u00dcberblick</p>
            <div class="lms-cards">
              #{cards_html}
            </div>
            <a href="#{base_url}/categories" class="lms-back-link">&larr; Zur\u00fcck zu allen Kategorien</a>
          </div>
        </body>
        </html>
      HTML

      render html: html.html_safe, layout: false
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
