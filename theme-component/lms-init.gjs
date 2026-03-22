import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";

export default apiInitializer((api) => {
  var siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.lms_enabled) return;

  function getCategoryById(categoryId) {
    if (!categoryId) return null;
    var site = api.container.lookup("service:site");
    return site.categories?.find(function(c) { return c.id === categoryId; }) || null;
  }

  function isLmsCategory(categoryId) {
    var cat = getCategoryById(categoryId);
    if (!cat) return false;
    if (cat.lms_enabled === true || cat.lms_enabled === "true") return true;
    if (cat.custom_fields?.lms_enabled === true || cat.custom_fields?.lms_enabled === "true") return true;
    return false;
  }

  function isRoadmapCategory(categoryId) {
    var cat = getCategoryById(categoryId);
    if (!cat) return false;
    if (cat.roadmap_enabled === true || cat.roadmap_enabled === "true") return true;
    if (cat.custom_fields?.roadmap_enabled === true || cat.custom_fields?.roadmap_enabled === "true") return true;
    return false;
  }

  function getCategoryIdFromUrl(url) {
    var pathParts = url.replace(/^\/c\//, "").split("/");
    return parseInt(pathParts[pathParts.length - 1], 10) || 0;
  }

  // --- 1. Completion Button on first post ---
  api.decorateCookedElement(
    function(element, helper) {
      if (!helper) return;
      if (element.closest(".d-editor-preview, .composer-popup, .edit-body")) return;

      var post = helper.getModel();
      if (!post || post.post_number !== 1) return;

      var topic = post.topic;
      if (!topic) return;
      if (!api.getCurrentUser()) return;
      if (!isLmsCategory(topic.category_id)) return;
      if (element.querySelector(".lms-completion-wrapper")) return;

      var wrapper = document.createElement("div");
      wrapper.className = "lms-completion-wrapper";

      var btn = document.createElement("button");
      btn.className = "btn btn-primary lms-complete-btn";
      btn.innerHTML = '<svg class="lms-check-icon" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg><span class="lms-btn-text">Laden...</span>';
      btn.disabled = true;

      var nextContainer = document.createElement("div");
      nextContainer.className = "lms-next-lesson";

      wrapper.appendChild(btn);
      wrapper.appendChild(nextContainer);
      element.appendChild(wrapper);

      ajax("/lms/status/" + topic.id + ".json")
        .then(function(result) {
          btn.disabled = false;
          setButtonState(btn, result.completed, result.needs_review);
          if (result.completed) {
            loadNextLesson(topic.category_id, topic.id, nextContainer);
          }
        })
        .catch(function() {
          btn.disabled = false;
          setButtonState(btn, false, false);
        });

      btn.addEventListener("click", function() {
        btn.disabled = true;
        ajax("/lms/complete/" + topic.id, { type: "POST" })
          .then(function(result) {
            btn.disabled = false;
            setButtonState(btn, result.completed, result.needs_review);
            if (result.completed) {
              loadNextLesson(topic.category_id, topic.id, nextContainer);
            } else {
              nextContainer.innerHTML = "";
            }
          })
          .catch(function() { btn.disabled = false; });
      });
    },
    { id: "discourse-lms-completion" }
  );

  function setButtonState(btn, completed, needsReview) {
    var textEl = btn.querySelector(".lms-btn-text");
    if (completed) {
      btn.classList.remove("btn-primary");
      btn.classList.add("btn-default", "lms-done");
      textEl.textContent = "Abschluss aufheben";
    } else {
      btn.classList.remove("btn-default", "lms-done");
      btn.classList.add("btn-primary");
      textEl.textContent = "Als abgeschlossen markieren";
    }
    if (needsReview) {
      btn.classList.add("lms-needs-review");
      textEl.textContent = "Aktualisiert \u2014 bitte erneut ansehen";
    } else {
      btn.classList.remove("lms-needs-review");
    }
  }

  function loadNextLesson(categoryId, currentTopicId, container) {
    ajax("/lms/lessons/" + categoryId + ".json")
      .then(function(data) {
        var lessons = data.lessons || [];
        var currentIdx = -1;
        for (var i = 0; i < lessons.length; i++) {
          if (lessons[i].id === currentTopicId) { currentIdx = i; break; }
        }
        if (currentIdx >= 0 && currentIdx < lessons.length - 1) {
          var next = lessons[currentIdx + 1];
          container.innerHTML = '<a href="/t/' + next.slug + '/' + next.id + '" class="btn btn-default lms-next-btn"><svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" style="margin-right:0.4em;vertical-align:middle"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>Weiter zu: ' + next.title + '</a>';
        }
      })
      .catch(function() {});
  }

  // --- 2. Category Page: Course header + topic badges ---
  api.onPageChange(function(url) {
    if (!url.match(/^\/c\//)) return;

    var categoryId = getCategoryIdFromUrl(url);
    if (!categoryId) return;

    setTimeout(function() {
      var currentUser = api.getCurrentUser();
      var isAdmin = currentUser && currentUser.admin;
      var isLms = isLmsCategory(categoryId);

      // Course header: badge/toggle + progress bar stacked vertically
      var isRoadmap = isRoadmapCategory(categoryId);
      var titleEl = document.querySelector(".category-title-contents .category-name, .category-heading");
      if (titleEl && !document.querySelector(".lms-course-header")) {
        var header = document.createElement("div");
        header.className = "lms-course-header";

        // Admin checkboxes (always for admins)
        if (isAdmin) {
          // Kurs checkbox
          var label = document.createElement("label");
          label.className = "lms-admin-toggle";
          label.title = isLms ? "Kurs-Modus deaktivieren" : "Als Kurs aktivieren";

          var checkbox = document.createElement("input");
          checkbox.type = "checkbox";
          checkbox.checked = isLms;
          checkbox.className = "lms-admin-checkbox";

          var labelText = document.createElement("span");
          labelText.className = "lms-admin-label";
          labelText.textContent = "Kurs";

          label.appendChild(checkbox);
          label.appendChild(labelText);
          header.appendChild(label);

          checkbox.addEventListener("change", function() {
            checkbox.disabled = true;
            var newState = checkbox.checked;

            ajax("/categories/" + categoryId + ".json", {
              type: "PUT",
              data: { "custom_fields[lms_enabled]": newState }
            })
              .then(function() {
                var cat = getCategoryById(categoryId);
                if (cat) {
                  if (!cat.custom_fields) cat.custom_fields = {};
                  cat.custom_fields.lms_enabled = newState;
                }
                checkbox.disabled = false;
                label.title = newState ? "Kurs-Modus deaktivieren" : "Als Kurs aktivieren";
                window.location.reload();
              })
              .catch(function() {
                checkbox.checked = !newState;
                checkbox.disabled = false;
              });
          });

          // Roadmap checkbox
          var rmLabel = document.createElement("label");
          rmLabel.className = "lms-admin-toggle";
          rmLabel.title = isRoadmap ? "Roadmap-Modus deaktivieren" : "Als Roadmap aktivieren";

          var rmCheckbox = document.createElement("input");
          rmCheckbox.type = "checkbox";
          rmCheckbox.checked = isRoadmap;
          rmCheckbox.className = "lms-admin-checkbox";

          var rmLabelText = document.createElement("span");
          rmLabelText.className = "lms-admin-label";
          rmLabelText.textContent = "Roadmap";

          rmLabel.appendChild(rmCheckbox);
          rmLabel.appendChild(rmLabelText);
          header.appendChild(rmLabel);

          rmCheckbox.addEventListener("change", function() {
            rmCheckbox.disabled = true;
            var newState = rmCheckbox.checked;

            ajax("/categories/" + categoryId + ".json", {
              type: "PUT",
              data: { "custom_fields[roadmap_enabled]": newState }
            })
              .then(function() {
                var cat = getCategoryById(categoryId);
                if (cat) {
                  if (!cat.custom_fields) cat.custom_fields = {};
                  cat.custom_fields.roadmap_enabled = newState;
                }
                rmCheckbox.disabled = false;
                rmLabel.title = newState ? "Roadmap-Modus deaktivieren" : "Als Roadmap aktivieren";
                window.location.reload();
              })
              .catch(function() {
                rmCheckbox.checked = !newState;
                rmCheckbox.disabled = false;
              });
          });
        } else {
          if (isLms) {
            var courseBadge = document.createElement("span");
            courseBadge.className = "lms-course-badge";
            courseBadge.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:middle;margin-right:0.3em"><path d="M5 13.18v4L12 21l7-3.82v-4L12 17l-7-3.82zM12 3L1 9l11 6 9-4.91V17h2V9L12 3z"/></svg>Kurs';
            header.appendChild(courseBadge);
          }
          if (isRoadmap) {
            var roadmapBadge = document.createElement("span");
            roadmapBadge.className = "lms-course-badge lms-roadmap-badge";
            roadmapBadge.textContent = "Roadmap";
            header.appendChild(roadmapBadge);
          }
        }

        titleEl.after(header);
      }

      // --- Roadmap: Voting Overview ---
      if (isRoadmap && !document.querySelector(".voting-overview")) {
        var match = url.match(/\/c\/(.+?)(?:\?|$)/);
        if (match) {
          var categoryPath = match[1].replace(/\/l\/.*$/, "");
          ajax("/c/" + categoryPath + ".json")
            .then(function(data) {
              if (document.querySelector(".voting-overview")) return;
              var topics = (data.topic_list && data.topic_list.topics) || [];
              // Filter: all non-pinned topics (category already has voting enabled)
              var displayTopics = topics.filter(function(t) { return !t.pinned; });

              if (displayTopics.length === 0) return;

              // Fetch vote counts for each topic individually
              var promises = displayTopics.map(function(t) {
                return ajax("/t/" + t.id + ".json").then(function(topicData) {
                  return {
                    id: t.id,
                    slug: t.slug,
                    fancy_title: t.fancy_title,
                    vote_count: topicData.vote_count || 0
                  };
                }).catch(function() {
                  return { id: t.id, slug: t.slug, fancy_title: t.fancy_title, vote_count: 0 };
                });
              });

              Promise.all(promises).then(function(votable) {
                if (document.querySelector(".voting-overview")) return;
                votable.sort(function(a, b) { return b.vote_count - a.vote_count; });

                var maxVotes = Math.max(1, votable.reduce(function(m, t) { return Math.max(m, t.vote_count); }, 0));

                var overview = document.createElement("div");
                overview.className = "voting-overview";

                var html = '<h3>Abstimmungen</h3>';
                html += '<ul class="voting-overview__list">';

                votable.forEach(function(t) {
                  var count = t.vote_count;
                  var pct = maxVotes > 0 ? Math.round((count / maxVotes) * 100) : 0;
                  var zeroClass = count === 0 ? " --zero" : "";
                  html += '<li class="voting-overview__item">';
                  html += '<span class="voting-overview__count' + zeroClass + '">' + count + '</span>';
                  html += '<a href="/t/' + t.slug + '/' + t.id + '" class="voting-overview__title">' + t.fancy_title + '</a>';
                  html += '<div class="voting-overview__bar-bg"><div class="voting-overview__bar-fill" style="width:' + pct + '%"></div></div>';
                  html += '</li>';
                });

                html += '</ul>';
                overview.innerHTML = html;

                var courseHeader = document.querySelector(".lms-course-header");
                if (courseHeader) {
                  courseHeader.after(overview);
                }
              });
            })
            .catch(function() {});
        }
      }

      if (!isLms) return;

      // Progress bar
      var courseHeader = document.querySelector(".lms-course-header");
      if (courseHeader && !document.querySelector(".lms-progress-bar") && currentUser) {
        ajax("/lms/progress/" + categoryId + ".json")
          .then(function(data) {
            if (document.querySelector(".lms-progress-bar")) return;
            var el = document.createElement("div");
            el.className = "lms-progress-bar";
            var pct = data.percent || 0;
            el.innerHTML = '<div class="lms-progress-track"><div class="lms-progress-fill" style="width:' + pct + '%"></div></div><span class="lms-progress-label">' + data.completed + " von " + data.total + " Lektionen abgeschlossen</span>";
            courseHeader.appendChild(el);
          })
          .catch(function() {});
      }

      // Topic list: badges and position numbers
      if (currentUser) {
        ajax("/lms/lessons/" + categoryId + ".json")
          .then(function(data) {
            var lessons = data.lessons || [];
            var byId = {};
            for (var i = 0; i < lessons.length; i++) {
              byId[lessons[i].id] = lessons[i];
            }

            var rows = document.querySelectorAll("tr.topic-list-item, .topic-list-item");
            rows.forEach(function(row) {
              var link = row.querySelector("a.title.raw-link, a.raw-topic-link");
              if (!link) return;

              var href = link.getAttribute("href") || "";
              var match = href.match(/\/t\/[^/]+\/(\d+)/);
              if (!match) return;

              var topicId = parseInt(match[1], 10);
              var lesson = byId[topicId];
              if (!lesson) return;

              if (lesson.position > 0 && !row.querySelector(".lms-position")) {
                var posEl = document.createElement("span");
                posEl.className = "lms-position";
                posEl.textContent = lesson.position + ". ";
                link.prepend(posEl);
              }

              if (!row.querySelector(".lms-status-badge")) {
                if (lesson.needs_review) {
                  var badge = document.createElement("span");
                  badge.className = "lms-status-badge lms-review";
                  badge.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg> Aktualisiert';
                  link.after(badge);
                } else if (lesson.completed) {
                  var badge = document.createElement("span");
                  badge.className = "lms-status-badge lms-done";
                  badge.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg> Abgeschlossen';
                  link.after(badge);
                }
              }
            });
          })
          .catch(function() {});
      }
    }, 600);
  });

});
