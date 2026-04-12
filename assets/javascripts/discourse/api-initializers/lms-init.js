import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.lms_enabled) return;

  // --- Notification icon for lesson_updated ---
  api.registerNotificationTypeRenderer(
    "discourse_lms.notifications.lesson_updated",
    (NotificationTypeBase) => {
      return class extends NotificationTypeBase {
        get icon() {
          return "book";
        }
      };
    }
  );

  // --- Completion Button on first post ---
  api.decorateCookedElement(
    (element, helper) => {
      if (!helper) return;
      if (element.closest(".d-editor-preview, .composer-popup, .edit-body")) return;

      const post = helper.getModel();
      if (!post || post.post_number !== 1) return;

      const topic = post.topic;
      if (!topic) return;

      if (!api.getCurrentUser()) return;

      // Check if category is LMS-enabled
      const site = api.container.lookup("service:site");
      const category = site.categories?.find((c) => c.id === topic.category_id);
      if (!category || !category.custom_fields?.lms_enabled) return;

      // Don't add twice
      if (element.querySelector(".lms-completion-wrapper")) return;

      const wrapper = document.createElement("div");
      wrapper.className = "lms-completion-wrapper";
      wrapper.style.cssText = "margin-top:1.5em;padding-top:1em;border-top:1px solid var(--primary-low)";

      const btn = document.createElement("button");
      btn.className = "btn btn-primary lms-complete-btn";
      btn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" style="margin-right:0.4em"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg><span class="lms-btn-text">Als abgeschlossen markieren</span>';

      btn.addEventListener("click", () => {
        btn.disabled = true;
        ajax("/lms/complete/" + topic.id, { type: "POST" })
          .then((result) => {
            btn.disabled = false;
            const textEl = btn.querySelector(".lms-btn-text");
            if (result.completed) {
              btn.classList.remove("btn-primary");
              btn.classList.add("btn-default");
              btn.style.borderColor = "var(--success)";
              btn.style.color = "var(--success)";
              textEl.textContent = "Abschluss aufheben";
            } else {
              btn.classList.remove("btn-default");
              btn.classList.add("btn-primary");
              btn.style.borderColor = "";
              btn.style.color = "";
              textEl.textContent = "Als abgeschlossen markieren";
            }
          })
          .catch(() => {
            btn.disabled = false;
          });
      });

      wrapper.appendChild(btn);
      element.appendChild(wrapper);
    },
    { id: "discourse-lms-completion" }
  );
});
