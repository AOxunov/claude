---
tags: [работа, easy-trip, realpay, api]
date: 2026-09-17
---

# RealPay Agent API — что вызывает EasyTrip

Обзор и контекст: [[00-Обзор]]. Обратная сторона: [[Callback-API-RealPay]].

**Источник истины — Swagger**, сверено 2026-09-17:
`https://agent.stage.realpay.uz/api/agent/swagger-ui/index.html`, схема — `/api/agent/docs`.

## Базовое

- Stage: `https://agent.stage.realpay.uz/api/agent`. Прод-адрес пока неизвестен.
- JSON в обе стороны.
- Любой ответ завёрнут в конверт:
  ```json
  { "code": 200, "data": { }, "message": "OK", "additional": {} }
  ```
- **Успех определяем по `code` в конверте, а не по HTTP-статусу.**

### Ошибки

| Ситуация | HTTP | Конверт |
|---|---|---|
| Нет токена / токен невалиден, истёк, отозван | **200** | `{"code":-8,"message":"Unauthenticated! Please login first…"}` — проверено на stage |
| Токен валиден, но нет прав | 403 | |
| Ошибка валидации тела | 400 | |
| Не найдено (мерчант, касса, заявка…) | 200 или 404 | `message` называет, что не найдено |
| Ошибка сервера | 500 | |

## Токен

- `POST /auth/sign-in`, тело `{"username","password"}`, без авторизации.
- Ответ (`data`, **snake_case**): `access_token`, `access_token_issued_at`,
  `refresh_token`, `refresh_token_issued_at`, `authorities[]`, `user_type`.
- Вход проходит только для аккаунтов с `user_type = AGENT`.
- Эндпоинта обновления токена **нет**: истёк → снова `sign-in`. `refresh_token` здесь не используется.
- Дальше заголовок `Authorization: Bearer <access_token>`.

### Текущая реализация в easy-trip
Эндпоинт конструктора `POST https://easy-trip.com/endpoint/api/v1/real-pay/token`
(в админке `tables/api_stages?endpoint_id=66`):
`redis.publicGet(ключ)` → если пусто, `http.post(sign-in)` → достаёт `exp` из JWT
самописным base64url-декодером → `redis.publicSet(ключ, токен, (exp − now − 60 с) · 1000)`.

Судя по `resp.data.access_token` и `resp.code`, `http.post` в конструкторе возвращает
уже разобранное тело ответа (конверт).

**Что верно:** поле `access_token` (в PDF ошибочно `accessToken`); декодер корректен
для `exp`; запас 60 секунд.

**Что поправить:**
1. **Ключ Redis совпадает с паролем агента.** Если `publicSet` пишет в общее
   пространство, пароль виден в списке ключей → назвать, например, `realpay:agent:token`.
2. Логин и пароль захардкожены в коде эндпоинта → вынести в настройки/секреты платформы.
3. **Нет сброса кэша.** Токен может перестать работать раньше `exp`, API ответит
   HTTP 200 с `code: -8`, а скрипт будет отдавать мёртвый токен до конца TTL.
   Нужна общая обёртка для всех вызовов RealPay:
   `code === -8` → удалить ключ → `sign-in` → **один** повтор запроса.
4. Проверять `resp.code === 200`, а не только наличие токена — будет понятная ошибка
   при неверном пароле.
5. Гонка: при пустом кэше параллельные запросы сделают несколько `sign-in`.
   Безвредно, если RealPay не отзывает старые токены; в любом случае закрывается пунктом 3.

## Эндпоинты

Все, кроме `sign-in`, требуют Bearer-токен.

### Справочники
| Метод | Путь | Ответ `data` |
|---|---|---|
| GET | `/const/v1/merchant-registration-status` | `[{value, key_uz, key_ru, key_en}]` |
| GET | `/const/v1/transaction-status` | то же |
| GET | `/const/v1/field-type` | то же — типы полей для `param_ins` |
| GET | `/const/v1/card-type` | то же |
| GET | `/const/v1/business-activities` | `[{id, name_uz, name_ru, name_en}]` |
| GET | `/const/v1/business-categories/{business_activity_id}` | то же |
| GET | `/const/v1/business-forms` | то же |
| GET | `/const/v1/bank-details/{mfo}` | `{bank_name, branch_name_uz/ru/en}` |

### Мерчант
| Метод | Путь | Назначение |
|---|---|---|
| POST | `/merchant/v1/create` | регистрация мерчанта + первая касса, см. ниже |
| GET | `/merchant/v1/get-by-id/{id}` | полная информация |
| GET | `/merchant/v1/get-by-tin/{tin}` | то же по ИНН/ПИНФЛ |
| GET | `/merchant/v1/contract-status?document_status=NEW\|SIGNED\|CANCELLED` | договоры мерчантов текущего агента: `kassa_id, hujjat_link, document_status, document_type, created_at` |
| POST | `/merchant/v1/contract-update` | переотправить договор неподписавшим. Тело **camelCase**: `merchantList[]`, `contractLanguage`, `signType` |
| POST | `/merchant/v1/kassa-inactivate` | заявка на отключение кассы: `merchant_id, kassa_id, phone_number, contract_language, application_reason, begin_date, end_date` (всё обязательно) |
| POST | `/merchant/v1/delete` | заявка на отключение мерчанта: `merchant_id, phone_number, contract_language`, `email` — необязательно |

Заявки возвращают `{application_id, application_status, document_url}`.

### Счета мерчанта
| Метод | Путь | Назначение |
|---|---|---|
| GET | `/merchant-bank/v1/get-all/{merchant_id}` | `[{id, merchant_id, name_*, mfo, bank_account, budget_account, main}]` |
| POST | `/merchant-bank/v1/change` | заявка на смену счёта: `merchant_id, kassa_id, contract_language, phone_number, bank_info{mfo, bank_account, budget_account?}` |

### Заявки
| Метод | Путь | Назначение |
|---|---|---|
| GET | `/application/all` | фильтры: `page, size, sort_column, sort_direction, id, merchant_id, applicant_id, type, applicant_type, document_url, status, from_date, to_date` |
| GET | `/application/{id}` | детали заявки |

### Касса
| Метод | Путь | Назначение |
|---|---|---|
| POST | `/kassa/v1/create` | ещё одна касса существующему мерчанту |
| GET | `/kassa/v1/{kassaId}` | детали: `id, name_*, status, min_amount, max_amount, type{type, name_*}, credentials{url, username, password}, bank_response, logo_id, merchant_bank_id, payment_purpose` |
| GET | `/kassa/v1/all` | **нет в PDF.** Фильтры: `merchant_id, tin_or_pinfl, name, page, size, sort_column, sort_direction` → `{id, name_*, status, type}` |

Тело `kassa/v1/create` — **все три поля обязательны** (в PDF `bank_create_request` помечен как необязательный):
```json
{
  "merchant_id": 101,
  "kassa_create_request": { "...": "как kassa в merchant/v1/create" },
  "bank_create_request": { "mfo": "00450", "bank_account": "20208000000000000001", "main_account": true }
}
```

### Шаблоны касс
| Метод | Путь | Назначение |
|---|---|---|
| POST | `/kassa-template/v1/create` | тело — конфигурация кассы (`KassaCreateRequest`), ответ — строка. Откуда берётся имя шаблона — неясно |
| GET | `/kassa-template/v1/get-all` | `{имя: KassaCreateRequest}` |
| DELETE | `/kassa-template/v1/delete?name=…` | `true/false` |

### ОФД
| Метод | Путь | Ответ |
|---|---|---|
| GET | `/ofd/v1/check-commitent?tin=…` или `?pinfl=…` | `true/false` |
| GET | `/ofd/v1/get-commitent?tin=…` или `?pinfl=…` | **camelCase**: `tin, companyName, pinfl, contractBeginDate, contractEndDate, deletedDate, subCommissionId, checkType` |

### Выплаты и транзакции
| Метод | Путь | Ответ |
|---|---|---|
| GET | `/v1/payment/order/get-all?kassa_id&date_from&date_to&status` (`status` повторяемый) | `[{id, merchant_kassa_id, kassa_name_*, to_bank_mfo, to_bank_account, transactions_sum, transactions_count, purpose, status, created_at, updated_at}]` |
| GET | `/v1/payment/order/transactions?payment_order_id` | `[{transaction_id, external_id, customer_id, status, card_id, masked_pan, created_at, cancelled_at, card_type, payment_order_id, payment_order_date, total_amount, commission_amount, ofd{transaction_id, terminal_id, status, type, fiscal_sign, qr_code_url}}]` |
| GET | `/transactions/v1/get-detail?transaction_id` | `{transaction_id, transaction_time, provider_name_*, card_type, masked_pan, customer_id, status, amount, fiscal_url}` |

### Коды ответов провайдера
| Метод | Путь | Тело |
|---|---|---|
| POST | `/provider/response/create` | **массив** `[{code, message_uz, message_ru, message_en}]` |
| PUT | `/provider/response/edit` | `{code, message_uz, message_ru, message_en}` |
| GET | `/provider/response/all` | `[{code, message_*, moderated, created_at}]` |
| DELETE | `/provider/response/delete` | тело `{code}` |

Предположение: это справочник текстов для наших отрицательных `response_code`,
которые клиент видит в приложении. Подтвердить у RealPay.

## `merchant/v1/create` — реальная структура

Пример в PDF **не пройдёт валидацию**. Структура по Swagger (значения — пример):

```json
{
  "document": {
    "contract_language": "UZBEK",
    "contract_type": "CONTRACT",
    "sign_type": "EIMZO"
  },
  "merchant": {
    "merchant": {
      "name": "…", "brand_name": "…", "tin_or_pinfl": "123456789",
      "business_form_id": 1, "business_category_id": 5, "address": "…",
      "gov_reg_number": "…", "gov_reg_date": "…", "gov_reg_place": "…",
      "type": "PRIVATE", "oked_code": "…", "licensed": false
    },
    "merchant_owner": {
      "full_name": "…", "phone": "998901234567", "pinfl": "12345678901234",
      "id_number": "AA1234567", "id_issuer": "…", "id_date": "…", "id_expiry_date": "…",
      "email": "…"
    },
    "merchant_banks": [
      { "mfo": "00450", "bank_account": "20208000000000000001", "main_account": true }
    ],
    "merchant_affiliated_company": { "name": "…", "tin": "…", "address": "…" },
    "license_base64": "…"
  },
  "kassa": {
    "name_uz": "…", "name_ru": "…", "name_en": "…",
    "template_name": "…",
    "kassa": {
      "url": "https://easy-trip.com/endpoint/api/v1/real-pay",
      "username": "…", "password": "…",
      "min_amount": 1000, "max_amount": 5000000,
      "param_ins": [
        {
          "field_name": "booking_id",
          "name_uz": "…", "name_ru": "Номер брони", "name_en": "…",
          "field_type": "STRING", "field_size": 20, "field_control": "…",
          "customer_id": true, "sort_order": 1,
          "param_in_value_list": [
            { "field_value": "…", "name_uz": "…", "name_ru": "…", "name_en": "…" }
          ]
        }
      ],
      "info_service_param_outs": [
        { "field_name": "tour_name", "name_uz": "…", "name_ru": "Тур", "name_en": "…", "sort_order": 1 }
      ],
      "payment_service_param_outs": [
        { "field_name": "voucher", "name_uz": "…", "name_ru": "Ваучер", "name_en": "…", "sort_order": 1 }
      ]
    }
  }
}
```

### Обязательные поля
- `document`: только `contract_language`.
- `merchant.merchant`: `name, brand_name, tin_or_pinfl, business_form_id, business_category_id, address, gov_reg_number, gov_reg_date, gov_reg_place, type`.
- `merchant.merchant_owner`: `full_name, phone, pinfl, id_number, id_issuer, id_date, id_expiry_date`.
- `merchant.merchant_banks[]`: `mfo, bank_account, main_account`.
- `merchant.merchant_affiliated_company` — необязателен, но если есть: `name, tin, address`.
- `kassa`: `name_uz, name_ru, name_en`.
- `kassa.kassa`: `url, username, password, min_amount, max_amount, param_ins, info_service_param_outs, payment_service_param_outs`.
- `param_ins[]`: `field_name, name_uz, name_ru, name_en`. `param_in_value_list[]` — вероятно, варианты для `COMBOBOX`.
- `*_service_param_outs[]`: `field_name, name_uz, name_ru, name_en`.

### Как настройки кассы попадают в вызовы RealPay
- `param_ins[].field_name` → ключи `body` в `/info` и `/payment`.
  Поле с `customer_id: true` потом видно в транзакциях как `customer_id`.
- `info_service_param_outs[].field_name` → ключи `additional` в ответе `/info`.
- `payment_service_param_outs[].field_name` → ключи `additional` в ответах `/payment` и `/check-status`.

### Ответ
`data.merchant_response` (полная информация о мерчанте) + `data.kassa_response` (детали кассы).
- id мерчанта: `data.merchant_response.merchant_info_response.id` (в PDF ошибочно `merchant_response.id`).
- id кассы: `data.kassa_response.id`.

## Форматы и валидация

| Поле | Формат |
|---|---|
| телефон (`phone`, `phone_number`) | `^(998)[98753][01345789]\d{7}` |
| `tin_or_pinfl` | `^(\d{9}\|\d{14})$` |
| `merchant_owner.pinfl` | 14 цифр |
| `merchant_owner.id_number` | `^[A-Z]{2}\d{7}$` (серия паспорта) |
| `merchant_affiliated_company.tin` | 9 или 14 цифр |
| `mfo` | 5 цифр |
| `bank_account` | 20 цифр |
| `budget_account` | 27 цифр |
| даты в фильтрах | `yyyy-MM-dd` |
| `gov_reg_date`, `id_date`, `id_expiry_date` | в Swagger просто string — формат уточнить |

## Enum-ы

| Enum | Значения |
|---|---|
| `contract_language` | UZBEK, RUSSIAN, ENGLISH |
| `contract_type` | CONTRACT, OFFER |
| `sign_type` | EIMZO, FACE_ID, RS_IMZO, SMS, TELEGRAM, UNI_PASS, DYNAMIC |
| `document_status` | NEW, SIGNED, CANCELLED |
| `document_type` | CONTRACT, OFFER, INVOICE, APPLICATION |
| тип мерчанта | BUDGET, PRIVATE |
| статус мерчанта | NEW, MERCHANT_SIGNED, MODERATED, REJECTED, ACTIVE, INACTIVE |
| статус кассы | NEW, ACCEPTED, REJECTED, MODIFIED, DELETED |
| тип кассы | WITH_BILLING, WITHOUT_BILLING, PAYMENT_ON_SPOT, INVOICE, REAL_GO |
| `field_type` | COMBOBOX, STRING, PHONE, REGEXBOX, DATEPOPUP, MONEY, CARDBOX, NUMBER |
| тип заявки | CONTRACT_CANCEL, KASSA_CANCEL, BANK_REQUISITE_CHANGE |
| статус заявки | ACTIVE, RESOLVED, REJECTED, DELETED |
| кто подал заявку | AGENT, MERCHANT |
| статус транзакции (RealPay) | NEW, IN_PROGRESS, ERROR, SUCCESS, CANCEL_IN_PROGRESS, CANCELLED |
| статус выплаты | NEW, INVOICE_GENERATED, PREPARED, SENT, PAID, ERROR, UNKNOWN |
| ОФД: статус / тип | SENT, SUCCESS, FAILED, CANCELLED / PAYMENT, AVANS, CREDIT |
| карта | UZCARD, HUMO |

## PDF против Swagger

- **Поля ответов — snake_case**, в PDF — camelCase. Исключения, где camelCase настоящий:
  пагинация (`items, totalItems, totalPages, currentPage`), `Commitent`, тело `contract-update`.
- Пример `merchant/v1/create`: не хватает обязательных `brand_name`, `gov_reg_*`,
  `id_number`, `id_issuer`, `id_date`, `id_expiry_date`, трёх массивов параметров кассы;
  `is_licensed` → на самом деле `licensed`; у счёта нет поля `name`.
- `kassa/v1/create`: `bank_create_request` обязателен; есть `template_name`.
- `GET /kassa/v1/all` в PDF отсутствует.
- `sign_type` — в PDF только EIMZO, на деле 7 вариантов.
- Путь к id мерчанта в ответе `create` — см. выше.
- В Swagger безопасность объявлена глобально, включая `sign-in`, но по факту он публичный.
