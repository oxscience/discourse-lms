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
    // Clean up old LMS elements from previous category page
    document.querySelectorAll(".lms-course-header, .lms-progress-bar").forEach(function(el) { el.remove(); });
    document.querySelectorAll(".lms-position, .lms-position-input, .lms-status-badge").forEach(function(el) { el.remove(); });

    if (!url.match(/^\/c\//)) return;

    var categoryId = getCategoryIdFromUrl(url);
    if (!categoryId) return;

    setTimeout(function() {
      var currentUser = api.getCurrentUser();
      var isAdmin = currentUser && currentUser.admin;
      var isLms = isLmsCategory(categoryId);

      // Read current sort order from category data
      var cat = getCategoryById(categoryId);
      var sortOrder = cat?.lms_sort_order || cat?.custom_fields?.lms_sort_order || "created";

      var titleEl = document.querySelector(".category-title-contents .category-name, .category-heading");
      if (titleEl && !document.querySelector(".lms-course-header")) {
        var header = document.createElement("div");
        header.className = "lms-course-header";

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

          // Sort order dropdown (only visible when Kurs is active)
          if (isLms) {
            var sortWrapper = document.createElement("div");
            sortWrapper.className = "lms-sort-wrapper";

            var sortLabel = document.createElement("span");
            sortLabel.className = "lms-sort-label";
            sortLabel.textContent = "Sortierung:";
            sortWrapper.appendChild(sortLabel);

            var select = document.createElement("select");
            select.className = "lms-sort-select";
            var options = [
              { value: "created", text: "Erstelldatum" },
              { value: "title", text: "Titel (A-Z)" },
              { value: "manual", text: "Manuell" }
            ];
            options.forEach(function(opt) {
              var option = document.createElement("option");
              option.value = opt.value;
              option.textContent = opt.text;
              if (opt.value === sortOrder) option.selected = true;
              select.appendChild(option);
            });
            sortWrapper.appendChild(select);
            header.appendChild(sortWrapper);

            select.addEventListener("change", function() {
              select.disabled = true;
              ajax("/categories/" + categoryId + ".json", {
                type: "PUT",
                data: { "custom_fields[lms_sort_order]": select.value }
              })
                .then(function() {
                  var cat = getCategoryById(categoryId);
                  if (cat) {
                    if (!cat.custom_fields) cat.custom_fields = {};
                    cat.custom_fields.lms_sort_order = select.value;
                    cat.lms_sort_order = select.value;
                  }
                  window.location.reload();
                })
                .catch(function() {
                  select.disabled = false;
                });
            });
          }
        } else {
          if (isLms) {
            var courseBadge = document.createElement("span");
            courseBadge.className = "lms-course-badge";
            courseBadge.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:middle;margin-right:0.3em"><path d="M5 13.18v4L12 21l7-3.82v-4L12 17l-7-3.82zM12 3L1 9l11 6 9-4.91V17h2V9L12 3z"/></svg>Kurs';
            header.appendChild(courseBadge);
          }
        }

        titleEl.after(header);
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

      // Topic list: reorder DOM rows to match LMS sort, then add badges and auto-numbering
      if (currentUser) {
        ajax("/lms/lessons/" + categoryId + ".json")
          .then(function(data) {
            var lessons = data.lessons || [];

            // Build ordered topic ID list and lookup maps
            var orderedIds = lessons.map(function(l) { return l.id; });
            var byId = {};
            for (var i = 0; i < lessons.length; i++) {
              byId[lessons[i].id] = lessons[i];
            }

            // Build auto-number map: sequential display numbers, skip "Über" topics
            var displayNum = {};
            var counter = 1;
            for (var i = 0; i < lessons.length; i++) {
              var isAboutTopic = /^[Üü]ber die Kategorie/i.test(lessons[i].title);
              if (!isAboutTopic) {
                displayNum[lessons[i].id] = counter;
                counter++;
              }
            }

            // Collect topic rows (order is already correct — server sorts them
            // for LMS categories via TopicQuery#apply_ordering). We only need
            // the row lookup here to attach numbers/badges below.
            var rows = document.querySelectorAll("tr.topic-list-item, .topic-list-item");
            var rowById = {};
            rows.forEach(function(row) {
              var link = row.querySelector("a.title.raw-link, a.raw-topic-link");
              if (!link) return;
              var href = link.getAttribute("href") || "";
              var match = href.match(/\/t\/[^/]+\/(\d+)/);
              if (!match) return;
              rowById[parseInt(match[1], 10)] = row;
            });

            // Helper: save positions to server and reload
            function savePositions(orderedTopicIds) {
              var positions = {};
              orderedTopicIds.forEach(function(id, idx) {
                positions[id] = idx + 1;
              });
              ajax("/lms/reorder/" + categoryId, {
                type: "PUT",
                data: { positions: positions }
              }).then(function() {
                window.location.reload();
              });
            }

            // Helper: move a topic to a specific position
            function moveToPosition(topicId, newPos) {
              newPos = Math.max(1, Math.min(orderedIds.length, newPos));
              var oldIdx = orderedIds.indexOf(topicId);
              if (oldIdx < 0) return;
              // Remove from old position
              orderedIds.splice(oldIdx, 1);
              // Insert at new position (1-based → 0-based)
              orderedIds.splice(newPos - 1, 0, topicId);
              savePositions(orderedIds);
            }

            // Now add numbering, badges, and position inputs to the reordered rows
            Object.keys(rowById).forEach(function(topicIdStr) {
              var topicId = parseInt(topicIdStr, 10);
              var row = rowById[topicId];
              var lesson = byId[topicId];
              if (!row || !lesson) return;

              var link = row.querySelector("a.title.raw-link, a.raw-topic-link");
              if (!link) return;

              // Auto-numbering: show display number unless title already starts with a number
              var num = displayNum[topicId];
              if (num && !row.querySelector(".lms-position") && !row.querySelector(".lms-position-input")) {
                var titleStartsWithNumber = /^\d/.test(lesson.title);
                if (!titleStartsWithNumber) {
                  // Admin + manual sort → editable number input
                  if (isAdmin && sortOrder === "manual") {
                    var input = document.createElement("input");
                    input.type = "number";
                    input.className = "lms-position-input";
                    input.value = num;
                    input.min = 1;
                    input.max = orderedIds.length;
                    input.title = "Position eingeben + Enter";
                    input.addEventListener("keydown", function(e) {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        var newPos = parseInt(input.value, 10);
                        if (newPos && newPos !== num) {
                          input.disabled = true;
                          moveToPosition(topicId, newPos);
                        }
                      }
                    });
                    input.addEventListener("blur", function() {
                      var newPos = parseInt(input.value, 10);
                      if (newPos && newPos !== num) {
                        input.disabled = true;
                        moveToPosition(topicId, newPos);
                      }
                    });
                    link.parentNode.insertBefore(input, link);
                  } else {
                    // Normal display number
                    var posEl = document.createElement("span");
                    posEl.className = "lms-position";
                    posEl.textContent = num + ". ";
                    link.prepend(posEl);
                  }
                }
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
