---
tags: [работа, easy-trip, realpay, конструктор, sql]
date: 2026-09-22
---

# Эндпоинты easy-trip для RealPay

Все эндпоинты конструктора (Platon), которые участвуют в интеграции, со стадиями.
Обзор: [[00-Обзор]]. Контракт callback-ов: [[Callback-API-RealPay]]. Оплата: [[SDK-Checkout-RealPay]].

## Как устроен эндпоинт конструктора

- Эндпоинт — цепочка **стадий** (alias + handler), выполняются по `sort_order`.
- Handlers: `sql_select`, `sql_update`, `js_eval_handler`, `static_json`, `http_request_handler`.
- Результат стадии доступен дальше: в JS — `variables.<alias>`, в SQL и шаблонах тела —
  `:alias` / `:alias.field`.
- Поля входящего запроса — `#field`, вложенные — `#body.x`. Для GET — параметры строки
  запроса (`#transaction_id`).
- `sql_select`: одна строка → объект, пустой результат → пусто (проверять `!data`),
  список → массив (так отдаёт `reconciliation`; возможно, режим задаётся в настройке стадии).
- Стадия `_body` формирует ответ; платформа заворачивает его в свой конверт
  (`{"data": …, "status": 200, …}`).
- Ограничения JS-стадии (не Node, не браузер) — см. память/описание Platon JS Eval:
  нет `Buffer`, `atob`, `require`, Java-интеропа; есть `http.post(url, body, headers)`,
  `redis.publicGet/publicSet`, `userActions.loadToken()`.
- Внешний адрес: `https://easy-trip.com/endpoint/api/<path>`.
- Числа из SQL в JS приводить через `Number(String(x))`, UUID — через `String(x)`.

## Список

| Путь | Метод | Назначение | Состояние |
|---|---|---|---|
| `v1/stage/real-pay/token` | POST | токен агента RealPay (Redis-кеш) | работает; доработки до прода — [[Agent-API-RealPay#Токен]] |
| `v1/stage/real-pay/create/template` | POST | шаблон кассы в агенте | работает |
| `v1/stage/real-pay/create/merchant` | POST | регистрация мерчанта | работает |
| `v1/stage/real-pay/create/iframe-token` | POST | из edu, в схеме с SDK не нужен | можно отключить |
| `v1/real-pay/auth/sdk` | POST | токен SDK для приложения по токену easy-trip | работает; проверить `client_id` на пользователя |
| `v1/real-pay/payment/create` | POST | создать платёж (`payment_id`) | работает |
| `v1/stage/real-pay/callback/info` | POST | callback RealPay | переписан |
| `v1/stage/real-pay/callback/payment` | POST | callback RealPay | переписан |
| `v1/stage/real-pay/callback/check-status` | GET | callback RealPay | проверен |
| `v1/stage/real-pay/callback/cancel` | PUT | callback RealPay | переписан |
| `v1/stage/real-pay/callback/reconciliation` | GET | callback RealPay | проверить `transaction_id is not null` |

`auth/sdk` и `payment/create` лежат без `stage/` — привести к общей схеме.

---

## База

### `realpay_transaction`
Одна строка = один платёж. Создаётся в `payment/create` (статус `NEW`), дальше её читают
и обновляют callback-и.

```sql
create table realpay_transaction
(
    id             uuid         default gen_random_uuid() not null primary key, -- payment_id и наш external_id
    state          smallint     default 1,
    version        integer      default 1,
    created_at     timestamp    default now(),
    updated_at     timestamp    default now()             not null,
    user_id        uuid                                   not null,            -- кто платит, из токена easy-trip
    place_id       uuid                                   not null,
    merchant_id    uuid                                   not null references merchant (id),
    kassa_id       varchar(100)                           not null,
    amount         numeric(15, 2)                         not null,
    status         varchar(20)  default 'NEW'             not null,            -- NEW / IN_PROGRESS / SUCCESS / ERROR / CANCELLED
    transaction_id varchar(50) unique,                                         -- id в RealPay, появляется в /payment
    payment_type   varchar(10),
    description    varchar(255),
    body           jsonb,                                                      -- осталась от первой версии, не используется
    rp_time        timestamp,
    cancelled_at   timestamp
);

create index realpay_transaction_rp_time_index on realpay_transaction (rp_time);
create index realpay_transaction_user_id_index on realpay_transaction (user_id);
```

В базе таблица была создана по первой версии (с `transaction_id not null`, без `user_id` и
`place_id`) и приведена к этой через `alter table`. `unique` на `transaction_id` допускает
много `null` — неоплаченные платежи не конфликтуют.

### `merchant`
См. [[Таблица-merchant]]. Добавлен `create unique index merchant_kassa_id_uindex on merchant (kassa_id);`.

### `lists` (`type_id = 13`, `id = 1`)
Последний созданный шаблон кассы: `long01` — тело шаблона, `long02` — ответ RealPay,
имя шаблона — `long02::jsonb ->> 'data'`.

---

## `create/template`

| Стадия | Handler | Что делает |
|---|---|---|
| `token` | `js_eval_handler` | берёт токен агента у эндпоинта `real-pay/token` |
| `data` | `static_json` | тело шаблона кассы |
| `template_creator` | `http_request_handler` | `POST https://agent.stage.realpay.uz/api/agent/kassa-template/v1/create`, body `:data`, заголовок `Authorization: Bearer :token`, `serialize_result` включён |
| `kassa_setter` | `sql_update` | `update lists set long01 = :data, long02 = :template_creator where type_id = 13 and id = 1` |

`token`:
```js
const userBearer = userActions.loadToken();
const res = http.post(`https://easy-trip.com/endpoint/api/v1/real-pay/token`, {}, {"Authorization": `Bearer ${userBearer}`});
return res["data"]["<alias стадии эндпоинта token>"];
```

`data` (актуальный шаблон, пароль не записан):
```json
{
  "url": "https://easy-trip.com/endpoint/api/v1/stage/real-pay/callback",
  "username": "<логин Basic callback-ов>",
  "password": "<пароль Basic callback-ов>",
  "min_amount": 1000,
  "max_amount": 100000000,
  "param_ins": [
    { "field_name": "payment_id", "name_uz": "To'lov ID", "name_ru": "ID платежа", "name_en": "Payment ID",
      "field_control": null, "field_size": 36, "field_type": "STRING", "customer_id": true, "sort_order": 1 }
  ],
  "info_service_param_outs": [
    { "field_name": "place_name", "name_uz": "Obyekt", "name_ru": "Объект", "name_en": "Place", "sort_order": 1 }
  ],
  "payment_service_param_outs": [
    { "field_name": "payment_status", "name_uz": "To'lov holati", "name_ru": "Статус платежа", "name_en": "Payment status", "sort_order": 1 }
  ]
}
```

Ответ RealPay: `{"data":"<имя шаблона, 32 hex>","code":0,"message":"Muvaffaqiyatli"}`.
Это **имя шаблона, не касса**. Касса создаётся отдельно — `kassa/v1/create` или вместе с мерчантом.

---

## `create/merchant`

| Стадия | Что делает |
|---|---|
| `merchant_insert` | вставляет строку в `merchant` (из анкеты), возвращает `id` |
| `data` | `select * from merchant where id = :merchant_insert.id::uuid;` |
| `template` | имя шаблона: `select long02::jsonb ->> 'data' as name from lists where type_id = 13 and id = 1` |
| `token` | как в `create/template` |
| HTTP | `POST https://agent.stage.realpay.uz/api/agent/merchant/v1/create`, заголовок `Authorization: Bearer :token` |
| сохранение | `sql_update`, см. ниже |

Тело HTTP-стадии (текстовые подстановки в кавычках, числа — без):
```json
{
  "document": {
    "contract_language": "UZBEK",
    "contract_type": "OFFER"
  },
  "kassa": {
    "name_uz": ":data.brand_name",
    "name_ru": ":data.brand_name",
    "name_en": ":data.brand_name",
    "template_name": ":template.name"
  },
  "merchant": {
    "merchant": {
      "business_form_id": :data.business_form_id,
      "name": ":data.name",
      "tin_or_pinfl": ":data.tin_or_pinfl",
      "address": ":data.address",
      "business_category_id": :data.business_category_id,
      "brand_name": ":data.brand_name",
      "gov_reg_number": ":data.gov_reg_number",
      "gov_reg_date": ":data.gov_reg_date",
      "gov_reg_place": "-",
      "type": "PRIVATE",
      "licensed": false
    },
    "merchant_owner": {
      "full_name": ":data.owner_full_name",
      "pinfl": ":data.owner_pinfl",
      "id_number": ":data.owner_id_number",
      "id_issuer": ":data.owner_id_issuer",
      "id_date": ":data.owner_id_date",
      "id_expiry_date": ":data.owner_id_expiry_date",
      "phone": ":data.owner_phone"
    },
    "merchant_banks": [
      {
        "mfo": ":data.mfo",
        "bank_account": ":data.bank_account",
        "main_account": true
      }
    ]
  }
}
```

Сохранение ответа (подставить alias HTTP-стадии вместо `merchant_creator`):
```sql
update merchant
set merchant_rp_id         = (:merchant_creator::jsonb #>> '{data,merchant_response,merchant_info_response,id}')::integer,
    kassa_id               = :merchant_creator::jsonb #>> '{data,kassa_response,id}',
    document_url           = :merchant_creator::jsonb #>> '{data,merchant_response,merchant_info_response,document_url}',
    status                 = :merchant_creator::jsonb #>> '{data,merchant_response,merchant_info_response,status}',
    merchant_info_response = :merchant_creator::jsonb #> '{data,merchant_response,merchant_info_response}',
    merchant_bank          = :merchant_creator::jsonb #> '{data,merchant_response,merchant_bank}',
    kassa_response         = :merchant_creator::jsonb #> '{data,kassa_response}',
    updated_at             = now()
where id = :merchant_insert.id::uuid
  and :merchant_creator::jsonb ->> 'code' = '0'
```

Риски:
- Название с двойными кавычками (`"SILK ROAD" MCHJ`) ломает JSON тела. Решение — экранировать
  в SQL: `substr(to_json(x)::text, 2, length(to_json(x)::text) - 2)`, либо отдавать из SQL
  `to_json(x)::text` и ставить плейсхолдер без кавычек.
- Пустые `business_form_id` / `business_category_id` ломают JSON (подставляются без кавычек).
- `gov_reg_place: "-"` попадает в текст оферты.
- Названия кассы лучше брать из `places` (`name_uz/ru/en`) — их видит клиент.

## Новая касса существующему мерчанту
Эндпоинта нет, делали через Swagger агента:
```
POST https://agent.stage.realpay.uz/api/agent/kassa/v1/create
```
```json
{
  "merchant_id": 809,
  "kassa_create_request": {
    "name_uz": "…", "name_ru": "…", "name_en": "…",
    "template_name": "<имя шаблона>"
  },
  "bank_create_request": { "mfo": "…", "bank_account": "…", "main_account": true }
}
```
В ответе `data.id` — новый `kassa_id` (UUID с дефисами), `data.credentials.url` — адрес из шаблона.
Потом: `update merchant set kassa_id = '<data.id>', updated_at = now() where merchant_rp_id = 809`.
Если объектов у юрлица станет несколько — сделать эндпоинт `create/kassa` по образцу `create/merchant`.

---

## `payment/create`
Приложение вызывает с токеном пользователя easy-trip, тело `{"place_id": "…", "amount": 1000}`.
Ответ: `{"payment_id": "…", "kassa_id": "…", "amount": 1000}` (в конверте платформы, в `data`).

### `user` (`js_eval_handler`)
Достаёт `sub` из токена пользователя (токен уже проверен платформой).
```js
// Декодер Base64URL без Buffer/atob
function base64UrlDecode(input) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let str = input.replace(/-/g, '+').replace(/_/g, '/');
    while (str.length % 4 !== 0) {
        str += '=';
    }

    let out = '';
    let i = 0;
    while (i < str.length) {
        const e1 = chars.indexOf(str.charAt(i++));
        const e2 = chars.indexOf(str.charAt(i++));
        const c3 = str.charAt(i++);
        const c4 = str.charAt(i++);
        const e3 = c3 === '=' ? 64 : chars.indexOf(c3);
        const e4 = c4 === '=' ? 64 : chars.indexOf(c4);

        out += String.fromCharCode((e1 << 2) | (e2 >> 4));
        if (e3 !== 64) out += String.fromCharCode(((e2 & 15) << 4) | (e3 >> 2));
        if (e4 !== 64) out += String.fromCharCode(((e3 & 3) << 6) | e4);
    }
    return out;
}

const token = String(userActions.loadToken());
const payload = base64UrlDecode(token.split('.')[1]);

// Достаём sub регуляркой: кириллица в full_name после декодера превращается в мусор, JSON.parse не нужен
const match = payload.match(/"sub"\s*:\s*"([^"]+)"/);
if (!match) {
    throw new Error('sub topilmadi');
}

return match[1];
```

### `payment_insert` (тот же handler, что у `merchant_insert`)
```sql
insert into realpay_transaction (user_id, place_id, merchant_id, kassa_id, amount, state)
select u.user_id,
       m.place_id,
       m.id,
       m.kassa_id,
       #amount::numeric,
       1
from merchant m,
     auth_users u
where m.place_id = #place_id::uuid
  and m.state = 1
  and m.kassa_id is not null
  and (u.user_id = :user::uuid or u.id = :user::uuid)
  and u.state = 1
  and #amount::numeric > 0
returning id, kassa_id, amount
```
`sub` сравнивается и с `auth_users.user_id`, и с `auth_users.id` — какой колонке он
соответствует, не уточняли. В платёж пишется `u.user_id`.

**`state` передаём явно.** 2026-09-22 строки из `payment/create` получили `state = null`,
хотя у колонки `default 1`, — видимо, платформа сама заполняет служебные колонки. Из-за этого
все callback-и (`t.state = 1`) не находили платёж: `/info` отвечал `-1`, а RealPay показывал
приложению `-1126`. Исправлено: `state` в `insert`, `update … set state = 1 where state is null`,
`alter column state set not null`.

### `_body`
```js
const p = variables.payment_insert;

// Строка не создалась: объект не подключён к RealPay, пользователь не найден или сумма не больше нуля
if (!p || !p.id) {
    return { "payment_id": null, "message": "To'lovni yaratib bo'lmadi" };
}

return {
    "payment_id": String(p.id),
    "kassa_id": p.kassa_id,
    "amount": Number(String(p.amount))
};
```

---

## `callback/info`
RealPay шлёт `{amount, kassa_id, body: {payment_id}}`.

### `data` (`sql_select`)
```sql
select t.id                                      as payment_id,
       t.status,
       t.amount,
       t.kassa_id,
       #kassa_id::varchar                        as request_kassa_id,
       #amount::numeric                          as request_amount,
       coalesce(p.name_uz, m.brand_name, m.name) as place_name,
       p.place_type::varchar                     as place_type,
       m.tin_or_pinfl::varchar                   as tin_or_pinfl,
       u.mobile_phone                            as phone
from realpay_transaction t
         join merchant m on m.id = t.merchant_id
         left join places p on p.id = t.place_id
         left join auth_users u on u.user_id = t.user_id
-- приводим к uuid, только если строка похожа на uuid: мусор от клиента не уронит запрос
where t.id = (case
                  when #body.payment_id::varchar ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then #body.payment_id::varchar::uuid end)
  and t.state = 1
```

### `_body` (`js_eval_handler`)
```js
// Позиция чека по типу объекта. Ключи — значения enum project.place_type (подставить реальные).
// ИКПУ и код упаковки: для stage спросить у RealPay; для прода — коды объекта с tasnif.soliq.uz.
const ITEMS = {
    "HOTEL":      { "name": "Mehmonxona xizmatlari uchun to'lov",  "spic": "<ИКПУ>", "package_code": "<код упаковки>" },
    "RESTAURANT": { "name": "Ovqatlanish xizmatlari uchun to'lov", "spic": "<ИКПУ>", "package_code": "<код упаковки>" },
    "STORE":      { "name": "Xaridlar uchun to'lov",               "spic": "<ИКПУ>", "package_code": "<код упаковки>" }
};
const DEFAULT_ITEM = { "name": "Xizmatlar uchun to'lov", "spic": "<ИКПУ>", "package_code": "<код упаковки>" };

function fail(code, message) {
    return { "response_code": code, "response_message": message };
}

const data = variables.data;

// Платёж не найден или создан для другой кассы — причину не раскрываем
if (!data || !data.payment_id || String(data.kassa_id) !== String(data.request_kassa_id)) {
    return fail(-1, "To'lov topilmadi");
}

// Платёж уже в работе, проведён или отменён
if (String(data.status) !== 'NEW') {
    return fail(-2, "To'lov allaqachon amalga oshirilgan yoki bekor qilingan");
}

// Сумма от RealPay должна совпасть с суммой, зафиксированной в payment/create
const amount = Number(String(data.amount));
if (Number(String(data.request_amount)) !== amount) {
    return fail(-3, "To'lov summasi mos kelmadi");
}

const item = ITEMS[data.place_type] || DEFAULT_ITEM;

// ИНН — 9 цифр, ПИНФЛ (ИП) — 14 цифр; каждый в своё поле
const tinOrPinfl = String(data.tin_or_pinfl || '');
const commissionInfo = tinOrPinfl.length === 14
    ? { "tin": "", "pinfl": tinOrPinfl }
    : { "tin": tinOrPinfl, "pinfl": "" };

const res = {
    "additional": {
        "place_name": data.place_name
    },
    "ofd": {
        "items": [
            {
                "name": item.name,
                "barcode": "",
                "label": "",
                "spic": item.spic,
                "package_code": item.package_code,
                "good_price": amount,
                "price": amount,
                "vat": 0,
                "vat_percent": 0,
                "amount": 1,
                "discount": 0,
                "other": 0,
                "commission_info": commissionInfo
            }
        ]
    },
    "response_code": 0,
    "response_message": "Success"
};

// Телефон из профиля easy-trip — для налогового кешбэка покупателя
const phoneDigits = String(data.phone || '').replace(/[^0-9]/g, '');
if (phoneDigits.length >= 9) {
    res.ofd.extra_info = { "phone_number": "998" + phoneDigits.slice(-9) };
}

return res;
```
Значения enum для `ITEMS`: `select unnest(enum_range(null::project.place_type));`.
Ключ `HOTEL` подтверждён 2026-09-22 (отель «Bibixonim mehmonxonasi» получил позицию
«Mehmonxona xizmatlari uchun to'lov»); ресторан и магазин — проверить.
`/info` вручную с настоящим платежом отвечает `0` — проверено 2026-09-22.

---

## `callback/payment`
RealPay шлёт `{transaction_id, time, kassa_id, amount, status, description, payment_type, body: {payment_id}}`
дважды: `IN_PROGRESS`, затем `SUCCESS`/`ERROR`. Что `payment_id` приходит в `/payment` в `body` —
пока только по документации, проверить на первой настоящей оплате.

### `updater` (`sql_update`)
```sql
update realpay_transaction t
set transaction_id = #transaction_id::varchar,
    status         = #status::varchar,
    payment_type   = #payment_type::varchar,
    description    = #description::varchar,
    rp_time        = #time::timestamp,
    updated_at     = now()
-- приводим к uuid, только если строка похожа на uuid: мусор не уронит запрос
where t.id = (case
                  when #body.payment_id::varchar ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then #body.payment_id::varchar::uuid end)
  and t.state = 1
  -- касса и сумма должны совпасть с зафиксированными в payment/create
  and t.kassa_id = #kassa_id::varchar
  and t.amount = #amount::numeric
  -- к платежу можно привязать только одну транзакцию RealPay
  and (t.transaction_id is null or t.transaction_id = #transaction_id::varchar)
  -- разрешённые переходы: NEW → любой, IN_PROGRESS → SUCCESS/ERROR; назад статус не откатывается
  and ((t.status = 'NEW' and #status::varchar in ('IN_PROGRESS', 'SUCCESS', 'ERROR'))
    or (t.status = 'IN_PROGRESS' and #status::varchar in ('SUCCESS', 'ERROR')))
```

### `data` (`sql_select`)
```sql
select t.id                                           as external_id,
       t.transaction_id,
       t.kassa_id,
       t.status,
       t.amount,
       to_char(t.updated_at, 'YYYY-MM-DD HH24:MI:SS') as last_time,
       #transaction_id::varchar                       as request_transaction_id,
       #kassa_id::varchar                             as request_kassa_id,
       #amount::numeric                               as request_amount
from realpay_transaction t
where t.id = (case
                  when #body.payment_id::varchar ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then #body.payment_id::varchar::uuid end)
  and t.state = 1
```

### `_body` (`js_eval_handler`)
```js
function fail(code, message) {
    return { "response_code": code, "response_message": message };
}

const data = variables.data;

// Платёж с таким payment_id не найден
if (!data || !data.external_id) {
    return fail(-1, "To'lov topilmadi");
}

// Касса или сумма не совпали с зафиксированными в payment/create — updater строку не тронул
if (String(data.kassa_id) !== String(data.request_kassa_id)
    || Number(String(data.amount)) !== Number(String(data.request_amount))) {
    return fail(-2, "Tranzaksiya ma'lumotlari mos kelmadi");
}

// Платёж уже привязан к другой транзакции RealPay или переход статуса недопустим
if (String(data.transaction_id) !== String(data.request_transaction_id)) {
    return fail(-2, "Tranzaksiya ma'lumotlari mos kelmadi");
}

// Статус берём из БД: повтор или опоздавший IN_PROGRESS получат уже сохранённый статус
return {
    "time": data.last_time,
    "status": data.status,
    "transaction_id": data.transaction_id,
    "external_id": String(data.external_id),
    "amount": Number(String(data.amount)),
    "additional": { "payment_status": data.status },
    "response_code": 0,
    "response_message": "Success"
};
```

---

## `callback/check-status`
`GET …/check-status?transaction_id=…`

### `data`
```sql
select id                                           as external_id,
       transaction_id,
       status,
       amount,
       to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS') as last_time
from realpay_transaction
where transaction_id = #transaction_id::varchar
  and state = 1
```

### `_body`
```js
const data = variables.data;

// Не нашли — строго -99999, этого требует RealPay. Проверка до любого обращения к data.*
if (!data || !data.external_id) {
    return { "response_code": -99999, "response_message": "Tranzaksiya topilmadi" };
}

// Статус берём из колонки status, которую пишет /payment
return {
    "time": data.last_time,
    "status": data.status,
    "transaction_id": data.transaction_id,
    "external_id": String(data.external_id),
    "amount": Number(String(data.amount)),
    "additional": { "payment_status": data.status },
    "response_code": 0,
    "response_message": "Success"
};
```

---

## `callback/cancel`
`PUT …/cancel`, тело `{transaction_id}`. Клиенту возвращается вся сумма, комиссию RealPay платит мерчант.

### `updater`
```sql
update realpay_transaction
set status       = 'CANCELLED',
    cancelled_at = now(),
    updated_at   = now()
where transaction_id = #transaction_id::varchar
  and state = 1
  and status = 'SUCCESS'
```

### `data`
```sql
select id                                           as external_id,
       transaction_id,
       status,
       to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS') as last_time
from realpay_transaction
where transaction_id = #transaction_id::varchar
  and state = 1
```

### `_body`
```js
function fail(code, message) {
    return { "response_code": code, "response_message": message };
}

const data = variables.data;

if (!data || !data.external_id) {
    return fail(-1, "Tranzaksiya topilmadi");
}

// updater отменяет только SUCCESS. Если статус не CANCELLED — транзакция была IN_PROGRESS или ERROR
if (String(data.status) !== 'CANCELLED') {
    return fail(-2, "Faqat muvaffaqiyatli to'lovni bekor qilish mumkin");
}

return {
    "time": data.last_time,
    "status": data.status,
    "transaction_id": data.transaction_id,
    "external_id": String(data.external_id),
    "response_code": 0,
    "response_message": "Success"
};
```
Повторная отмена возвращает `CANCELLED` как успех — RealPay может безопасно повторять запрос.

---

## `callback/reconciliation`
`GET …/reconciliation?from_date=yyyy-MM-dd HH:mm:ss&to_date=…`

### `data` (в режиме списка)
```sql
select transaction_id,
       id                                           as external_id,
       status,
       amount,
       to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS') as last_time
from realpay_transaction
where state = 1
  and transaction_id is not null
  and rp_time between #from_date::timestamp and #to_date::timestamp
order by rp_time
```
Отбор по `rp_time` (время RealPay), а не по нашему `updated_at`: иначе платёж на стыке суток
разъедется по двум дням. В `time` отдаём наше время последнего изменения — так требует документация.

### `_body`
```js
const data = variables.data;

// Список приходит массивом; на случай одной строки объектом или пустого результата — нормализуем
let rows = [];
if (Array.isArray(data)) {
    rows = data;
} else if (data && data.transaction_id) {
    rows = [data];
}

const transactions = [];
for (let i = 0; i < rows.length; i++) {
    transactions.push({
        "time": rows[i].last_time,
        "status": rows[i].status,
        "transaction_id": rows[i].transaction_id,
        "external_id": String(rows[i].external_id),
        "amount": Number(String(rows[i].amount))
    });
}

// Пустой период — не ошибка: пустой список с кодом 0
return {
    "transactions": transactions,
    "response_code": 0,
    "response_message": "Success"
};
```
Все кассы отдаются вместе: запрос не говорит, для какой кассы сверка (логин/пароль общие).
Пока мерчант один — не важно; с ростом — уточнить у RealPay.

---

## Ручная проверка callback-ов
Логин/пароль — Basic кассы. Все запросы на `https://easy-trip.com/endpoint/api/v1/stage/real-pay/callback/…`.

| # | Запрос | Ожидание |
|---|---|---|
| 1 | `payment/create` (токен пользователя) | `payment_id`, `kassa_id` = текущая касса |
| 2 | `info` с `body.payment_id` и той же суммой | `0`, `place_name`, `ofd` |
| 3 | `info` с другой суммой / чужим `payment_id` | `-3` / `-1` |
| 4 | `payment` `IN_PROGRESS`, затем `SUCCESS` (`transaction_id: TEST-0001`) | `0`, статус в БД `SUCCESS` |
| 5 | `info` ещё раз | `-2` |
| 6 | `payment` с `amount: 2000` | `-2` |
| 7 | `check-status?transaction_id=TEST-0001` / `=probe` | `SUCCESS` / `-99999` |
| 8 | `reconciliation` за сутки | список с `TEST-0001` |
| 9 | `cancel` дважды | `CANCELLED` оба раза |
| 10 | любой запрос без Basic | 401 |

Уборка: `delete from realpay_transaction where transaction_id like 'TEST-%' or kassa_id = 'ccba3bcc-983f-4862-a2b9-850a9a0eb810'`.

## Как было в edu (для сравнения)
- Платёж создавался в edu заранее (`students_payments`), RealPay возвращал его id в
  `#additional_data.payment_id` — оплата шла через iframe (`create/iframe-token`).
- Ошибки старых callback-ов, которые не повторяем: в `/payment` жёстко `SUCCESS` в ответе;
  статус мог откатиться; в `check-status` читался `state` вместо `status` (всегда `IN_PROGRESS`)
  и `-1` вместо `-99999`; `cancel` отменял любой статус и ставил `state = 0`;
  в сверке `::date` отбрасывал время, пустой период считался ошибкой.
