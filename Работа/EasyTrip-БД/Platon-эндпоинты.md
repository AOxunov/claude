---
tags: [работа, easy-trip, platon, конструктор, api]
date: 2026-11-05
---

# Platon: как устроены api_endpoints и api_stages

Разбор по дампу `platon` от 02.11.2026: 119 эндпоинтов, 287 стадий, 1 задача cron.
Нужен, чтобы вставлять эндпоинты SQL-ом. Связано: [[EasyTrip-БД/00-Обзор|разбор прод-БД]],
[[EasyTrip-RealPay/Эндпоинты-easy-trip|эндпоинты RealPay]],
[[EasyTrip-Бонусные-карты/00-Обзор|бонусные карты]].

## Главное для инсертов

- **id.** Колонка без default. Платформа берёт id из `seq_api_endpoint` / `seq_api_stage`, но
  этих последовательностей нет в дампе (нет прав). Строки, вставленные вручную (перенос
  RealPay из edu), имеют **отрицательные id**: эндпоинты −1…−15, стадии до −105. Новые ручные
  id брать ниже текущего минимума.
- **Служебные колонки.** У ручных строк заполнены только `state = 1` и `version = 1`, а
  `created_at`, `update_id` и `created_by` — `NULL`. На проде такие эндпоинты работают
  (callback-и RealPay).
- **Внешних ключей нет.** Ни `api_stages.endpoint_id`, ни уникальности `method + path`.
  Дубликат пути никто не остановит.
- **Порядок.** Стадии выполняются по `sort_order`. Стадия с alias `_body` формирует ответ.
- **Адрес.** Снаружи — `https://easy-trip.com/endpoint/api/<path>`; cron вызывает
  `http://gateway/endpoint/api/<path>`. В `path` нет ведущего `/`.

## api_endpoints

| Колонка | Значения в дампе |
|---|---|
| `method` | GET 68, POST 38, PUT 12, DELETE 1 |
| `path` | `v1/...`; для теста RealPay — `v1/stage/...` |
| `auth_handler` | `bearer` 78 — токен пользователя; `basic` 11 — callback-и RealPay; `NULL` 30 — без авторизации |
| `has_transaction` | `true` 49 — все стадии в одной транзакции; `false` 70 |
| `group_by` | папка в интерфейсе: `Ungrouped`, `RealPay (Mutalib)`, `hotels`, ... |
| `result_cached_seconds` | обычно 0; у 6 GET-запросов 60 или 300 |
| `attributes` | всегда `{}` |
| `access_condition`, `note`, `sort_order` | почти всегда пусто |

**Basic.** Логинов и паролей нет ни в эндпоинтах, ни в `platon.auth_users` (таблица пустая).
Basic проверяет платформа по своим пользователям, их заводят в платформе, не инсертом.

## api_stages

| Колонка | Смысл |
|---|---|
| `endpoint_id` | эндпоинт |
| `sort_order` | порядок выполнения |
| `alias` | имя результата для следующих стадий; `_body` — ответ |
| `handler` | тип стадии, ниже |
| `attributes` | настройки стадии (JSON), набор ключей зависит от handler |
| `serialize_result` | у всех `_body` — `true`; у стадий, чей результат подставляется в SQL как текст (`:alias`), тоже `true`. Точный смысл не описан |
| `access_condition` | условие запуска стадии: `#slug == 'restaurants'`, `:place_type == "STORE"`, `:request.code === 0` |
| `parent_id` | всегда пусто (`NULL`) |
| `state` | 1 — работает, 0 — стадия выключена (у `v1/stage/real-pay/token` так выключены прод-стадии) |

| handler | Сколько | Ключи `attributes` |
|---|---|---|
| `sql_select` | 97 | `datasource` (`project`), `sql`, `sql_result_type`: `list` / `map` / `object` |
| `js_eval_handler` | 48 | `js_eval` — строка JSON `{"code": исходник, "es5": собранный код}` |
| `sql_insert` | 47 | `datasource`, `sql`, `returning_fields` (платформа сама добавляет `RETURNING`) |
| `sql_bulk_insert` | 37 | `datasource`, `sql`, `batch_data_source` |
| `http_request_handler` | 24 | `http_method`, `resource_url`, `content_type`, `http_headers`, `request_body`, `http_request_response` (строка `"false"`), `request_form_data` |
| `sql_update` | 17 | `datasource`, `sql`, `returning_fields` |
| `static_json` | 14 | `static_json` |
| `validation_handler` | 2 | `condition`, `error_message1..4`: при истинном условии — ошибка с этим текстом |
| `sql_batch_update` | 1 | `datasource`, `sql`, `batch_data_source` |

**Подстановки.**
- `#field` — поле запроса (у GET — параметр строки), `#body.x` — вложенное.
- `:alias` / `:alias.field` — результат прошлой стадии.
- `$user.id` — текущий пользователь (bearer).
- `@field` — элемент массива в bulk.
- В SQL подстановка идёт параметром (`#amount::numeric`, `:merchant_creator::jsonb`), в URL и
  теле HTTP — текстом, поэтому строки берут в кавычки: `":student.client_id"`.

**Тип результата `sql_select`** (`sql_result_type`):
- `object` — одно значение, первая колонка первой строки: `select gen_random_uuid()`;
- `map` — одна строка объектом: `select * from merchant where id = …`;
- `list` — все строки.

**Ответ HTTP-стадии в SQL.** При `serialize_result = true` ответ целиком подставляется как
`:alias` — текстом JSON: `long02 = :template_creator` в `v1/stage/real-pay/create/template`.
Поле ответа — `:alias.поле`: `:stage_agent_token.data.access_token::varchar`. Так сделан
`v1/ti/currency/load` (бонусные карты, `P01`): `ti_currency_rates_load_cbu(:cbu::jsonb)`.

**SQL-стадия, которая пишет.** В дампе нет `sql_select`, вызывающих функции с записью. Для
`select project.ti_…()` ставлю `has_transaction = true` — первая проверка на сервере — `P01`.

**Инсерты из DataGrip.** `:alias`, `#field` и `$user` внутри SQL стадий DataGrip может принять
за свои параметры и открыть окно Parameters. В JSON стадии такой символ пишу
escape-последовательностью: двоеточие — \u003a, `#` — \u0023, `$` — \u0024. Платформа
читает JSON и видит обычный символ; кириллица в JS-стадиях RealPay хранится так же (\uXXXX).

**JS-стадия.** Платформа хранит исходник и собранный ES5-вариант с обёрткой
`return (function(){ … })();` — похоже, выполняется он. При вставке SQL-ом нужны оба поля:
писать сразу на ES5 и класть в `es5` с обёрткой.
- **Есть:** `variables.<alias>`, `http.post(url, body, headers)` и `http.get(url)` (возвращают
  разобранный JSON), `userActions.loadToken()`, `redis.publicGet/publicSet`.
- **Нет:** `Buffer`, `require`, `atob`, `fetch`, `console`.

## cron_schedules

- В дампе одна задача — `TokenUpdater`, выключена (`state = 0`).
  - `code_type = 'REQUEST'`, `methods = 'POST'`, `url` — путь эндпоинта без адреса.
  - `cron_expression` — 5 полей (`*/30 * * * *`).
  - `datasource = 'project'` (NOT NULL даже для REQUEST), `content_type`.
  - `attributes = {"header": {"Authorization": "Basic …"}, "js_eval": null}`.
- **Результат запуска** платформа пишет в `details` (`attempt_count`, `cron_message_error`) и
  `last_run_time`.
- **Почему TokenUpdater падал с 401:** эндпоинт `v1/stage/real-pay/token` — `bearer`, а cron
  шлёт Basic. Эндпоинты для cron должны быть `basic` (или без авторизации).
- **Колонка `sql`** (до 4000 символов) есть, но задач с `code_type` кроме REQUEST в дампе нет.
- **Новые задачи** вставляю с отрицательными id: последовательности для cron в дампе нет.
  Остальное — как у TokenUpdater: `log_level = 'ERROR'`, `attempt_count = 1`, заголовок
  `Authorization` копируется из него запросом, значение в файл не попадает.

**Последовательности** в дампе видны: `seq_api_endpoint` (139), `seq_api_stage` (401),
`seq_update_id`. Строки, созданные платформой, получают `created_at`, `update_id` и
`created_by`; у ручных — только `state` и `version`, и на проде они работают.

## env_group / env_item

Таблицы «ключ — значение» есть, но пустые. Как стадии на них ссылаются — неизвестно.

## Известные проблемы

Секреты лежат прямо в настройках стадий: пароли в HTTP-телах, ключи в URL, Basic в
заголовках. Список мест — в [[EasyTrip-БД/00-Обзор|разборе прод-БД]]. Значения в заметки и
git не писать.
