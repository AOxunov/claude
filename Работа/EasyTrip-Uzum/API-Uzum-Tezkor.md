---
tags: [работа, easy-trip, uzum, доставка, api]
date: 2026-11-24
---

# Uzum Tezkor Cargo API — выжимка и проверки на стенде

Источники: документация Uzum <https://cargo-tools-n-pages.vercel.app/cargo-api> (поведение на
13.10.2026) и письмо Бахтиёра (интеграция Uzum Tezkor) от 24.11.2026. Проверено 24.11.2026 на
тестовом стенде токеном нашей тестовой точки. Обзор интеграции — [[00-Обзор]].

API совместим с Yandex Delivery Express API v2, но реализована только часть: ровно две точки,
только `courier` / `express`, без заказа ко времени и без подписи callback-ов.

## Контуры и доступ

| Контур | Базовый адрес | |
|---|---|---|
| Тест | `https://cargo.stable.ufood.uz/b2b/cargo/integration` | курьеров нет, назначают вручную по просьбе |
| Прод | `https://cargo.uzumtezkor.uz/b2b/cargo/integration` | реальные заказы |

- Постоянный Bearer-токен **на точку (филиал)**: по токену Uzum знает, от какой точки заказ.
  Каждый токен видит только свои заявки (чужая → `404 not_found`). Тестовый — только на тесте,
  боевой выпускают отдельно; новый ключ начинает работать в течение 15 минут.
- Заголовки: `Authorization: Bearer <token>`, `Content-Type: application/json`, `Accept-Language: ru`.
- Часы работы — 07:00–03:00 по Ташкенту. Вне них `create` и `calculate` отвечают
  `unknown_error` «service is closed by schedule».
- Проверка токена без заявки: `claims/info` с `claim_id` из 32 нулей → `404 not_found`.

## Методы (пути проверены на стенде)

| Метод | Путь после `/integration` | Что передать | Заметки |
|---|---|---|---|
| POST | `/v2/offers/calculate` | `route_points` [{`id`, `coordinates`, `fullname`}], `items` [{`quantity`, `weight`, `pickup_point`, `dropoff_point`}], `selected_taxi_class` | ничего не создаёт; стенд отдал **один** offer (в документации — два) |
| POST | `/v2/claims/create?request_id=` | `items`, `route_points` (source и destination), `client_requirements.taxi_class`, `callback_properties.callback_url`, `auto_accept`, `optional_return`, `comment` | сразу `ready_for_approval` с ценой; повтор с тем же `request_id` — та же заявка (проверено) |
| POST | `/v2/claims/accept?claim_id=` | `{version}` | в ответе может ещё стоять `ready_for_approval`; есть `display_id` |
| POST | `/v2/claims/info?claim_id=` | — | источник истины; лимитов нет, активные — раз в 15–30 с |
| POST | `/v2/claims/edit?claim_id=&version=` | полное тело, как в create | только до accept; ответ — **старые** данные, `version` не растёт (растёт `revision`) |
| POST | `/v2/claims/cancel-info?claim_id=` | — | `free` / `paid` (+`price`) / `unavailable` |
| POST | `/v2/claims/cancel?claim_id=` | `{cancel_state, version}` | `free` при платной → `409 free_cancel_is_unavailable` |
| GET | `/v2/claims/performer-position?claim_id=` | — | **POST → 405**; до курьера `409 inappropriate_status`; `sharing_link` у destination |
| POST | `/v2/driver-voiceforwarding` | `{claim_id}` | реальный номер, `ext` пустой; до курьера `409` |

**Расхождения с письмом Бахтиёра.** В письме `performer-position` — POST, а стенд принимает только
GET (документация тоже GET). Путь `/v2/claims/v2/driver-voiceforwarding` из письма отвечает 404,
рабочий — `/v2/driver-voiceforwarding`. Пример заявки `019eabb9…` из письма нашим токеном не виден
(404): по документации заявки другого токена и не должны быть видны.

## Форматы

- Координаты — `[долгота, широта]`; деньги — строка `"18000.00"`, валюта UZS; время — ISO 8601 UTC;
  `claim_id` — 32 hex.
- `cost_value` — цена **за единицу**. Позиция с `"0"` принимается (проверено).
- `weight` позиций складывается **без** умножения на `quantity` — передавать вес позиции целиком.
  От 15 кг Uzum сам назначает машину; габариты не учитываются.
- `external_order_id` в destination — номер, который курьер называет на кассе.
- Неизвестные поля игнорируются; ошибка — только на то, чего явно нет (`due`, `return`, карта…).

## Статусы

Основной путь: `ready_for_approval` → `accepted` → `performer_lookup` → `performer_draft` →
`performer_found` → `pickup_arrived` → `pickuped` → `delivery_arrived` → `delivered` →
`delivered_finish` (примерно через час после `delivered`).

Финальные: `cancelled`, `cancelled_with_payment`, `cancelled_with_items_on_hands`, `failed`
(не удался `auto_accept`). Не приходят: `new`, `estimating`, `performer_not_found` (через ~10 минут
курьера назначает логист, авто-отмены нет), возвратные, `ready_for_*_confirmation`.

Отмена: бесплатна до `pickup_arrived` включительно; после забора — платно (доставка плюс обратная
дорога, если заказ возвращается); после `delivered` — нельзя.

## Callback

- `POST` на `callback_url` при каждой смене статуса. В query — наши параметры и `claim_id`,
  `status`, `updated_ts`; в теле — `claim_id`, `status`, `updated_ts`, `performer_info`, `route_points`.
- Подписи нет — свой секрет в query `callback_url`.
- Успех — только **HTTP 200** за 15 секунд (201 и 204 — неуспех). Иначе 6 попыток за ~2 минуты.
- Промежуточный статус может не прийти; дубли отбрасывать по `claim_id` + `status` + `updated_ts`.
  Первый callback — не раньше 5 секунд после создания.

## Ошибки

Тело `{"code", "message"}`, логика — по `code`:
- заявки — `400`: `no_input_point`, `unsupported_points_count`, `address_not_found`,
  `invalid_destination_point`, `address_outside_delivery_zone`, `address_too_far`, `unknown_zone`,
  `invalid_delivery_interval`, `invalid_buyout_payment_method`, `bad_request`, `unknown_error`;
  `404 not_found`; `409 inappropriate_status`, `409 free_cancel_is_unavailable`;
- расчёт — `409`: `estimating.zone_unavailable`, `estimating.route_too_long`,
  `estimating.requirement_unavailable`, `estimating.route_is_prohibited`, `unknown_error`;
- `401` / `403` — `{"status": 401, "message": "Unauthorized"}`;
- проверено на стенде: неизвестный путь — `{"code": 404, "message": "path … was not found"}`,
  неверный метод — `{"code": 405, …}`; Самарканд от точки в Ташкенте — `409 estimating.route_too_long`.

## Стенд

- `calculate` иногда отвечает «source not in city» для Ташкента — повторить запрос.
- Тестовый маршрут 24.11 (Кукча Дарвоза 377 → Кончилик 47, 1,5 км): 14 949 сум, `eta` 50 минут,
  `display_id` вида `112449-422816`.
- Курьера на тестовую заявку назначает Бахтиёр вручную — полный прогон договариваться в чате.
