---
tags: [работа, easy-trip, uzum, доставка, конструктор, api]
date: 2026-11-24
---

# Эндпоинты easy-trip для доставки Uzum

Контракт для приложения и админки. Адрес — `https://easy-trip.com/endpoint/api/<путь>`, ответ
платформы в конверте `{data, code, message}`; ниже — что лежит в `data`. Стадии — в
`P01-Platon-API-Uzum.sql` (собирает `tools/gen_p01.py`), функции — в `01-DDL.sql`.
Обзор — [[00-Обзор]], API Uzum — [[API-Uzum-Tezkor]].

## Кто что может

| Эндпоинт | Кто |
|---|---|
| `calculate`, `points`, `me` | любой вошедший (bearer) |
| `claim/create`, `claim/accept`, `claim/cancel` | оператор объекта (`uzum_operators`: `user_id` + `place_id`) или администратор (`place_id` пустой) |
| `claim/info`, `claim/courier` | оператор или тот, кто создал доставку |
| `claims` | оператор — по своим объектам, администратор — по всем |
| `diag` | администратор |
| `callback` | без авторизации — для Uzum |
| `sync` | Basic — cron `UzumSync` |

## Ошибки

- **Наши проверки** — ошибка платформы с текстом `uzum_<код>: описание`: `uzum_no_access`,
  `uzum_bad_request`, `uzum_no_point` (объект не подключён), `uzum_branch_required` (у объекта
  несколько точек — нужен `branch_id`), `uzum_not_found`, `uzum_inappropriate_status`,
  `uzum_order_busy` (по заказу уже есть доставка на другой адрес).
- **Ошибки Uzum** — не исключение: обычный ответ с `ok = false`, `error_code` (код Uzum:
  `address_too_far`, `estimating.route_too_long`, `inappropriate_status`…) и `error_message`.
  Свои коды того же вида: `paid_cancel_not_confirmed`, `cancel_unavailable`, `create_timeout`,
  `http_error` (нет связи), `unauthorized` (токен точки не принят), `platform_result`.

## Доставка — поля ответа

`create`, `accept`, `info`, `cancel` и элементы `claims` отдают одну и ту же строку:

| Поле | Что это |
|---|---|
| `id` | наш id доставки — его передавать в остальные методы |
| `claim_id`, `display_id` | id заявки у Uzum и номер заказа у Uzum (его называть поддержке) |
| `place_id`, `branch_id`, `point_id`, `env` | объект, филиал, точка забора, контур (`test` / `prod`) |
| `order_ref`, `external_order_id` | номер заказа из запроса; номер, который курьер называет на кассе (`order_ref` или `ET-XXXXXX`) |
| `status`, `stage`, `is_final` | статус Uzum, крупный этап (ниже), финальный ли |
| `price`, `currency`, `eta_minutes` | стоимость доставки, прогноз в минутах |
| `performer_name`, `performer_transport`, `sharing_link` | курьер и ссылка отслеживания |
| `cancel_state`, `cancel_price` | последний ответ cancel-info |
| `recipient_name`, `recipient_phone`, `address`, `lon`, `lat`, `items_total` | получатель, адрес, сумма позиций |
| `ok`, `error_code`, `error_message` | последняя ошибка; сбрасывается следующей удачной операцией |
| `created_at`, `accepted_at`, `picked_up_at`, `delivered_at`, `finished_at`, `status_changed_at` | время этапов |

| `stage` | Статусы Uzum | Что показать |
|---|---|---|
| `creating` | `new` | заявка уходит в Uzum |
| `draft` | `ready_for_approval` | цена есть, ждёт подтверждения; можно бесплатно отменить |
| `searching` | `accepted`, `performer_lookup`, `performer_draft` | ищем курьера |
| `to_pickup` | `performer_found`, `pickup_arrived` | курьер едет за заказом / на месте |
| `delivering` | `pickuped`, `delivery_arrived` | везёт покупателю / у покупателя; отмена платная |
| `delivered` | `delivered`, `delivered_finish` | вручён |
| `cancelled` | `cancelled*` | отменён |
| `failed` | `failed`, `error` | не создался или не подтвердился |

## Методы

**`POST v1/uzum/calculate`** — цена до создания, ничего не создаёт.
Тело: `place_id`, `lon`, `lat` (обязательно), `branch_id`, `address`, `taxi_class` (`courier` —
любой курьер, `express` — на машине), `weight` (кг). Ответ: `ok`, `price`, `currency`,
`taxi_class`, `pickup_from` / `pickup_to`, `delivery_from` / `delivery_to`, `error_code`,
`error_message`. Цена не резервируется: точную отдаёт `create`.

**`POST v1/uzum/claim/create`** — вызвать курьера. Тело:

| Поле | |
|---|---|
| `place_id`, `branch_id` | объект и филиал (филиал — если у объекта несколько точек) |
| `order_ref` | номер заказа: курьер называет его на кассе; повтор с ним — та же доставка, второго курьера не будет |
| `recipient_name`, `recipient_phone` | обязательно; телефон приводится к `+998…` |
| `address`, `lon`, `lat` | обязательно: текст видит курьер, маршрут — по координатам |
| `porch`, `sfloor`, `sflat`, `door_code`, `address_comment` | подъезд, этаж, квартира, домофон, комментарий к адресу |
| `comment` | комментарий к заказу |
| `items` | `[{"title", "quantity", "price", "weight"}]` — цена и вес за единицу; можно не передавать |
| `taxi_class` | `courier` (по умолчанию точки) или `express` |
| `optional_return` | `true` — при отмене после забора курьер не везёт заказ обратно |
| `auto_accept` | `true` — сразу заказ и поиск курьера, без шага `accept` |

Ответ — доставка, обычно `stage = draft` с ценой. Заказ оплачен заранее, поэтому выкупа нет:
`price` позиций курьеру справочно.

**`POST v1/uzum/claim/accept`** — `id`. Подтвердить черновик: начинается поиск курьера. После
этого адрес и позиции не меняются — только отмена и новая доставка.

**`GET v1/uzum/claim/info?id=`** — доставка со свежим статусом из Uzum. Экран доставки может
спрашивать раз в 15–30 секунд; статусы и без того приходят callback-ом и cron-ом.

**`POST v1/uzum/claim/cancel`** — `id`, `allow_paid`. Бесплатная отмена — сразу. Платная (курьер
уже забрал заказ) без `allow_paid` не выполняется: `ok = false`,
`error_code = paid_cancel_not_confirmed`, `cancel_price` — показать и переспросить, потом
повторить с `allow_paid = true`.

**`GET v1/uzum/claim/courier?id=`** — `id`, `status`, `stage`, `performer_name`,
`performer_transport`, `phone`, `lat`, `lon`, `position_at`, `sharing_link`, `ok`, `error_code`,
`error_message`. До назначения курьера `phone` и координаты пустые — это не ошибка. Телефон
спрашивать перед каждым звонком: курьер может смениться. Ссылку отслеживания покупатель и так
получает от Uzum по SMS примерно через 5 минут после заказа.

**`GET v1/uzum/claims?place_id=&status=&active=&limit=&offset=`** — список доставок; `status` —
статус Uzum или `stage`, `active=true` — только незавершённые, `limit` до 500 (по умолчанию 50).

**`GET v1/uzum/points?place_id=`** — где доступна доставка: `id`, `place_id`, `branch_id`, `env`,
`place_name`, `name`, `address`, `lon`, `lat`, `taxi_class`. Без токенов.

**`GET v1/uzum/me`** — `user_id`, `username`, `is_admin`, `operator_places`, `points`. `user_id` —
то, что вписывать в `uzum_operators`.

**`GET v1/uzum/diag?place_id=`** — проверка платформы (администратор): `info404_code`,
`info404_how` (`exception` или `body` — как `http.post` ведёт себя на 404), `calc_string_ok`,
`calc_string_price`, `calc_object_ok`, `js_body_mode`, `recommended_js_body_mode`, `raw_info404`.

**`POST v1/uzum/callback`** — для Uzum, не вызывать из приложения. Отвечает `ok = true` всегда:
подделки и повторы игнорирует, по настоящему запрашивает `claims/info`.

**`POST v1/uzum/sync`** — для cron `UzumSync` (каждую минуту): `checked`, `changed`, `errors`.

## Сценарий оператора

1. `calculate` — показать цену доставки.
2. `create` с `order_ref` — черновик с точной ценой.
3. `accept` — поиск курьера. Дальше статусы обновляются сами (callback и cron).
4. Экран доставки — `info` раз в 15–30 секунд; на этапах `to_pickup` и `delivering` — `courier`.
5. Отмена — `cancel`; бесплатно до приезда курьера за заказом.
