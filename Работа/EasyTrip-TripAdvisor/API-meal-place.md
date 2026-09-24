---
tags: [работа, easy-trip, конструктор, sql, бд]
date: 2026-09-24
---

# `POST v1/meal-place` и загрузка файлов

API создания **и** изменения ресторана (upsert по `id` на каждом уровне). Через него компонент
TripAdvisor сохраняет рестораны. Обзор: [[00-Обзор]].

## Стадии

| id | alias | handler | Таблица | Из тела |
|---|---|---|---|---|
| 35 | `places` | `sql_insert` | `places` | `id`, `place_type`, `name_*`, `description_*`, `address_uz`, `latitude`, `longitude`, `card_discount_percentage`, `did_you_know_*`, `logo`, `social_links`, `sub_category_id` |
| 36 | `meal_place` | `sql_insert` | `meal_places` | `category_id`, `cuisine_types[]`, `websites{}`, `discount`, `about`, `logo`, `menu_photos[]`, `phones[]`, `emails[]` |
| 47 | `branches` | `sql_bulk_insert` | `place_branches` | `branches[]`: `id`, `lat`, `lng`, `is_main`, `name`, `phones[]` |
| 62 | `amenities` | `sql_bulk_insert` | `selected_amenities` | `amenities[]`: `amenity_id` (может быть `null`), `name_uz/ru/en` |
| 37 | `place-images` | `sql_bulk_insert` | `place_images` | `place_images[]`: `id`, `file_id`, `is_main`, `sort_order` |
| 38 | `menu-items` | `sql_bulk_insert` | `menu_items` | `menu_items[]` |
| 39 | `place_categories` | `sql_insert` | `place_categories` | `category_id` |
| 40 | `work-times` | `sql_bulk_insert` | `place_working_hours` | `work_times[]`: `id`, `day_of_week`, `open_time`, `close_time` |

Синтаксис в SQL стадий: `#field` — поле тела, `@field` — поле элемента массива в
`sql_bulk_insert`, `:places.id` — результат предыдущей стадии, `$user.id` — текущий пользователь.

`place_type` для ресторана — **`MEAL_PLACE`**.

## Подводные камни

- `on conflict (id) do update set … = excluded.…` переписывает **все** колонки: поле, которое не
  прислали, станет `null`. Новые колонки (например `ta_id`) обновлять через
  `coalesce(excluded.x, places.x)`, иначе обычная форма их затрёт.
- `place_categories.category_id not null` → без `category_id` стадия падает.
- `places`-стадия **не пишет** `ta_id`, `region_id`, `address_ru`, `address_en`, `rating_avg`,
  `reviews_count` — хотя колонки есть.
- `places.state` / `moderator_status` не передаются → берутся умолчания (`moderator_status = 'CREATED'`).

## Ключевые колонки (DDL 2026-09-24)

**`places`**: `id uuid`, **`ta_id varchar(50) unique`** (ID TripAdvisor), `place_type
project.place_type not null`, **`name_uz not null`**, `name_ru`, `name_en`, `description_*`,
`address_uz/ru/en`, `latitude numeric(10,8)`, `longitude numeric(11,8)`, `rating_avg numeric(3,2)`
(0–5), `reviews_count`, `card_discount_percentage smallint` (0–100), `did_you_know_*`, `state`
(0 — неактивен, 1 — активен, 2 — на модерации, 3 — отклонён модератором), `moderator_status`
(по умолч. `CREATED`), `moderator_note`, `moderated_at/by`, `logo`, `social_links jsonb`,
`sub_category_id`, `region_id integer` (→ `lists` `type_id = 1`), `user_id`, `audio_git_file_ids`.

**`meal_places`**: `place_id → places`, `category_id`, `cuisine_types bigint[]`, `websites jsonb`,
`discount numeric(5,2)`, `amenities integer[]`, `about`, `social_medias jsonb`, `logo varchar(50)`,
`menu_photos varchar[]`, `phones varchar(50)[]`, `emails varchar(255)[]`.

**`place_images`**: `place_id`, `file_id varchar`, **`url text`**, `is_main`, `sort_order`.

**`place_working_hours`**: `day_of_week integer`, `open_time time`, `close_time time`.

Также: `place_branches` (`lat`, `lng`, `is_main`, `name`, `phones`), `selected_amenities`,
`menu_items` (`price not null`), `place_categories (place_id, category_id)` → `categories`.

## Загрузка файлов

```
POST https://easy-trip.com/file/api/v1/upload/form
Authorization: Bearer <токен пользователя>
multipart/form-data: form_element_id=2, file=<файл>
```
Ответ: `{"id": "8a81819b14de00d25c050e7d", "name", "size", "extension", "contentType", "createdAt"}`.
`id` (24 hex, не UUID) сохраняется в `place_images.file_id`.

В компоненте — `fetch` с Bearer; токен в `localStorage` по ключу `auth_token`.
