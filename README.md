# discourse-lms

Discourse-Plugin, das Kategorien in strukturierte **LMS-Kurse** verwandelt — mit Lektions-Tracking, Fortschrittsbalken und automatischer Nummerierung.

## Features

- **Kurs-Modus pro Kategorie** — Admin-Checkbox aktiviert LMS-Features auf jeder Kategorie
- **Automatische Lektions-Nummerierung** — Topics werden sequenziell nummeriert (1., 2., 3., ...)
- **Smart-Skip** — Titel die bereits mit einer Zahl beginnen (z.B. "1.1 Pacing...") bekommen keine doppelte Nummerierung
- **Konfigurierbare Sortierung** — Admin-Dropdown pro Kategorie:
  - `Erstelldatum` (Standard) — sortiert nach Topic-Erstelldatum
  - `Titel (A-Z)` — alphabetisch
  - `Manuell` — per `lms_position` Custom Field (via Reorder-API)
- **Fortschrittsbalken** — zeigt "X von Y Lektionen abgeschlossen" pro Kategorie und User
- **Completion-Tracking** — Button am Ende jeder Lektion zum Markieren als abgeschlossen
- **Nächste Lektion** — nach Abschluss erscheint Link zur nächsten Lektion
- **Needs-Review** — wenn ein Topic-Erstbeitrag bearbeitet wird, werden bestehende Abschlüsse als "Aktualisiert" markiert + Notification
- **Server-seitige Topic-Sortierung** — `TopicQuery#apply_ordering` Prepend sortiert Topic-Listen in LMS-Kategorien direkt in SQL nach `lms_sort_order` (kein Client-seitiges DOM-Reshuffling, kein Flicker)

## Architektur

Split in zwei Repos:

| Teil | Repo | Technologie | Deployment |
|------|------|-------------|------------|
| **Backend-Plugin** | [oxscience/discourse-lms](https://github.com/oxscience/discourse-lms) | Ruby (plugin.rb, Controller) | GitHub → `app.yml` → Rebuild |
| **Theme Component** | [oxscience/discourse-lms-theme](https://github.com/oxscience/discourse-lms-theme) | JS/CSS (lms-init.gjs, common.scss) | Admin → Themes → Install from Git |

## Dateistruktur

```
discourse-lms-plugin/
├── plugin.rb                          # Custom Fields, Serializer, Event Hooks, Routes,
│                                      # TopicQuery#apply_ordering Prepend
├── app/
│   └── controllers/
│       └── lms_controller.rb          # API-Endpoints (progress, lessons, complete, reorder)
├── config/
│   ├── settings.yml                   # Site Settings (lms_enabled, Button-Texte)
│   └── locales/
└── README.md
```

Frontend (lms-init.gjs, common.scss) liegt im **separaten Theme-Repo** [oxscience/discourse-lms-theme](https://github.com/oxscience/discourse-lms-theme).

## Custom Fields

| Feld | Ebene | Typ | Beschreibung |
|------|-------|-----|-------------|
| `lms_enabled` | Category | Boolean | Kurs-Modus aktiviert |
| `lms_sort_order` | Category | String | Sortierung: `created`, `title`, `manual` |
| `lms_position` | Topic | Integer | Manuelle Position (nur bei sort_order=manual) |

## API-Endpoints

Alle unter `/lms/` gemountet, erfordern Login.

| Methode | Endpoint | Beschreibung |
|---------|----------|-------------|
| `POST` | `/lms/complete/:topic_id` | Completion toggeln |
| `GET` | `/lms/status/:topic_id` | Completion-Status eines Topics |
| `GET` | `/lms/progress/:category_id` | Fortschritt pro Kategorie (total, completed, percent) |
| `GET` | `/lms/lessons/:category_id` | Sortierte Lektions-Liste mit Completion-Status |
| `PUT` | `/lms/reorder/:category_id` | Positionen setzen (Admin only) |

## Deployment

### Theme Component (JS/CSS) — eigenes Repo

Liegt in [oxscience/discourse-lms-theme](https://github.com/oxscience/discourse-lms-theme). Updates: `git push` → Admin → Customize → Themes → "LMS Course Tracker" → "Check for updates".

### Backend-Plugin (Ruby) — erfordert Rebuild

```bash
# 1. Änderungen committen + pushen
git add . && git commit -m "..." && git push

# 2. Auf dem Server: Rebuild (5-10 Min, Forum offline)
ssh root@<server-ip>
cd /var/discourse && ./launcher rebuild app
```

## Site Settings

| Setting | Default | Beschreibung |
|---------|---------|-------------|
| `lms_enabled` | `false` | Plugin global aktivieren |
| `lms_show_position_numbers` | `true` | Positionsnummern anzeigen |
| `lms_completion_button_text_complete` | "Als abgeschlossen markieren" | Button-Text |
| `lms_completion_button_text_undo` | "Abschluss aufheben" | Button-Text (Undo) |

## Beispiel-Setup

Das Plugin unterstützt mehrere Kurse parallel mit unterschiedlichen Sortierungen:

| Kategorie | Topics | Sortierung |
|-----------|--------|------------|
| Symposien-Reihe | 27 | Erstelldatum (Titel haben eigene Nummern → Smart-Skip) |
| Seminar-Reihe A | 10 | Erstelldatum |
| Seminar-Reihe B | 26 | Erstelldatum |
