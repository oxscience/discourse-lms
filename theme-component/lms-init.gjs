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
    // Always clean up roadmap body class on navigation
    document.body.classList.remove("roadmap-active");

    if (!url.match(/^\/c\//)) return;

    var categoryId = getCategoryIdFromUrl(url);
    if (!categoryId) return;

    // Check roadmap IMMEDIATELY (before setTimeout) to prevent flash
    var isRoadmap = isRoadmapCategory(categoryId);
    if (isRoadmap) {
      document.body.classList.add("roadmap-active");
    }

    setTimeout(function() {
      var currentUser = api.getCurrentUser();
      var isAdmin = currentUser && currentUser.admin;
      var isLms = isLmsCategory(categoryId);
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

      // --- Roadmap: Kanban Board ---
      if (isRoadmap && !document.querySelector(".roadmap-board")) {
        var match = url.match(/\/c\/(.+?)(?:\?|$)/);
        if (match) {
          var categoryPath = match[1].replace(/\/l\/.*$/, "");

          // Kanban columns: tag → label mapping (order matters)
          var columns = [
            { tag: "geplant", label: "Geplant", icon: "📋" },
            { tag: "in-arbeit", label: "In Arbeit", icon: "🔨" },
            { tag: "erledigt", label: "Erledigt", icon: "✅" }
          ];
          var columnTags = columns.map(function(c) { return c.tag; });

          // Show loading skeleton immediately
          var courseHeader = document.querySelector(".lms-course-header");
          var skeleton = document.createElement("div");
          skeleton.className = "roadmap-board roadmap-board--loading";
          skeleton.innerHTML = '<div class="roadmap-columns">' +
            columns.map(function(col) {
              return '<div class="roadmap-col"><div class="roadmap-col__header">' +
                '<span class="roadmap-col__icon">' + col.icon + '</span>' +
                '<span class="roadmap-col__label">' + col.label + '</span>' +
                '</div><div class="roadmap-col__items">' +
                '<div class="roadmap-skeleton"></div>' +
                '<div class="roadmap-skeleton"></div>' +
                '</div></div>';
            }).join("") + '</div>';
          if (courseHeader) courseHeader.after(skeleton);

          ajax("/c/" + categoryPath + ".json")
            .then(function(data) {
              var topics = (data.topic_list && data.topic_list.topics) || [];
              var displayTopics = topics.filter(function(t) { return !t.pinned; });

              if (displayTopics.length === 0) {
                skeleton.remove();
                return;
              }

              // Fetch vote counts per topic
              var promises = displayTopics.map(function(t) {
                return ajax("/t/" + t.id + ".json").then(function(td) {
                  return {
                    id: t.id,
                    slug: t.slug,
                    fancy_title: t.fancy_title,
                    tags: t.tags || [],
                    vote_count: td.vote_count || 0,
                    excerpt: (t.excerpt || "").replace(/<[^>]*>/g, "").substring(0, 120)
                  };
                }).catch(function() {
                  return {
                    id: t.id, slug: t.slug, fancy_title: t.fancy_title,
                    tags: t.tags || [], vote_count: 0, excerpt: ""
                  };
                });
              });

              Promise.all(promises).then(function(items) {
                // Group by column tag
                var grouped = {};
                columns.forEach(function(c) { grouped[c.tag] = []; });

                items.forEach(function(item) {
                  var placed = false;
                  for (var i = 0; i < columnTags.length; i++) {
                    if (item.tags.indexOf(columnTags[i]) !== -1) {
                      grouped[columnTags[i]].push(item);
                      placed = true;
                      break;
                    }
                  }
                  if (!placed) {
                    grouped[columns[0].tag].push(item);
                  }
                });

                // Sort each column by vote_count desc
                columns.forEach(function(c) {
                  grouped[c.tag].sort(function(a, b) { return b.vote_count - a.vote_count; });
                });

                // Build board HTML
                var html = '<div class="roadmap-columns">';
                columns.forEach(function(col) {
                  var colItems = grouped[col.tag];
                  html += '<div class="roadmap-col" data-column="' + col.tag + '">';
                  html += '<div class="roadmap-col__header">';
                  html += '<span class="roadmap-col__icon">' + col.icon + '</span>';
                  html += '<span class="roadmap-col__label">' + col.label + '</span>';
                  html += '<span class="roadmap-col__count">' + colItems.length + '</span>';
                  html += '</div>';
                  html += '<div class="roadmap-col__items" data-column="' + col.tag + '">';

                  if (colItems.length === 0) {
                    html += '<div class="roadmap-card --empty --drop-hint">Hierher ziehen</div>';
                  }

                  colItems.forEach(function(item) {
                    var allTags = JSON.stringify(item.tags).replace(/"/g, "&quot;");
                    html += '<a href="/t/' + item.slug + '/' + item.id + '" class="roadmap-card" draggable="true" data-topic-id="' + item.id + '" data-tags="' + allTags + '">';
                    html += '<div class="roadmap-card__top">';
                    html += '<span class="roadmap-card__title">' + item.fancy_title + '</span>';
                    if (item.vote_count > 0) {
                      html += '<span class="roadmap-card__votes">▲ ' + item.vote_count + '</span>';
                    }
                    html += '</div>';
                    if (item.excerpt) {
                      html += '<div class="roadmap-card__excerpt">' + item.excerpt + '</div>';
                    }
                    html += '</a>';
                  });

                  html += '</div></div>';
                });
                html += '</div>';

                // Replace skeleton with real board
                skeleton.classList.remove("roadmap-board--loading");
                skeleton.innerHTML = html;

                // --- Drag & Drop ---
                if (!isAdmin) return; // Only admins can drag

                var dragCard = null;

                skeleton.querySelectorAll(".roadmap-card[draggable]").forEach(function(card) {
                  card.addEventListener("dragstart", function(e) {
                    dragCard = card;
                    card.classList.add("--dragging");
                    e.dataTransfer.effectAllowed = "move";
                    e.dataTransfer.setData("text/plain", card.dataset.topicId);
                    // Prevent navigation on drag
                    e.stopPropagation();
                  });

                  card.addEventListener("dragend", function() {
                    card.classList.remove("--dragging");
                    dragCard = null;
                    skeleton.querySelectorAll(".roadmap-col__items").forEach(function(col) {
                      col.classList.remove("--drag-over");
                    });
                  });

                  // Prevent click navigation during drag
                  card.addEventListener("click", function(e) {
                    if (card.classList.contains("--was-dragged")) {
                      e.preventDefault();
                      card.classList.remove("--was-dragged");
                    }
                  });
                });

                skeleton.querySelectorAll(".roadmap-col__items").forEach(function(colEl) {
                  colEl.addEventListener("dragover", function(e) {
                    e.preventDefault();
                    e.dataTransfer.dropEffect = "move";
                    colEl.classList.add("--drag-over");
                  });

                  colEl.addEventListener("dragleave", function(e) {
                    if (!colEl.contains(e.relatedTarget)) {
                      colEl.classList.remove("--drag-over");
                    }
                  });

                  colEl.addEventListener("drop", function(e) {
                    e.preventDefault();
                    colEl.classList.remove("--drag-over");
                    if (!dragCard) return;

                    var newColumn = colEl.dataset.column;
                    var topicId = dragCard.dataset.topicId;
                    var currentTags = JSON.parse(dragCard.dataset.tags.replace(/&quot;/g, '"'));

                    // Remove old column tags, add new one
                    var newTags = currentTags.filter(function(t) {
                      return columnTags.indexOf(t) === -1;
                    });
                    newTags.push(newColumn);

                    // Move card visually
                    var emptyCard = colEl.querySelector(".--empty");
                    if (emptyCard) emptyCard.remove();
                    colEl.appendChild(dragCard);
                    dragCard.dataset.tags = JSON.stringify(newTags);
                    dragCard.classList.add("--was-dragged");

                    // Update counts
                    skeleton.querySelectorAll(".roadmap-col").forEach(function(col) {
                      var tag = col.dataset.column;
                      var count = col.querySelectorAll(".roadmap-card[draggable]").length;
                      var countEl = col.querySelector(".roadmap-col__count");
                      if (countEl) countEl.textContent = count;
                      // Show empty hint if column is empty
                      var itemsEl = col.querySelector(".roadmap-col__items");
                      if (count === 0 && !itemsEl.querySelector(".--empty")) {
                        var hint = document.createElement("div");
                        hint.className = "roadmap-card --empty --drop-hint";
                        hint.textContent = "Hierher ziehen";
                        itemsEl.appendChild(hint);
                      }
                    });

                    // Update tags via API
                    ajax("/t/" + topicId + ".json", {
                      type: "PUT",
                      data: { tags: newTags }
                    }).catch(function() {
                      // Reload on failure
                      window.location.reload();
                    });
                  });
                });
              });
            })
            .catch(function() { skeleton.remove(); });
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
