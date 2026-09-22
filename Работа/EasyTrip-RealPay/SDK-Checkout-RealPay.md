---
tags: [работа, easy-trip, realpay, api, sdk]
date: 2026-09-22
---

# RealPay checkout SDK — API оплаты

Через этот сервис мобильное приложение easy-trip проводит оплату (RealPay Flutter SDK,
`realpay_flutter_sdk` 2.0.0). Обзор и поток: [[00-Обзор]]. Наши эндпоинты: [[Эндпоинты-easy-trip]].

- Базовый URL stage: `https://api-checkout.stage.realpay.uz/api/merchant/sdk`
- Схема OpenAPI (открыта): `https://api-checkout.stage.realpay.uz/api/merchant/sdk/api/docs`
  (`/docs` требует токен, а `/api/docs` — нет)
- Авторизация: `Authorization: Bearer <токен SDK>`. Токен приложение получает у easy-trip:
  `POST https://easy-trip.com/endpoint/api/v1/real-pay/auth/sdk` со своим токеном easy-trip,
  ответ — токен в `data`.
- Заголовки SDK: `Accept-Language: uz`, `SDK-Version: 2.0.0`.

## Порядок оплаты картой
1. `GET /service/v1/get?kassa_id=…` — поля кассы, лимиты, комиссия.
2. `POST /payment/v2/info/card-id` — RealPay вызывает наш `/info`, клиенту уходит SMS-код.
3. `POST /payment/v2/payment/card-id` — с кодом; RealPay списывает деньги и вызывает наш `/payment`.

Перед этим приложение вызывает наш `payment/create` и получает `payment_id` и `kassa_id`.

## Эндпоинты

| Метод | Путь | Что делает |
|---|---|---|
| GET | `/service/v1/get?kassa_id=` | поля и настройки кассы |
| GET | `/service/v2/get?kassa_id=&provider_id=` | то же, v2 |
| POST | `/payment/v2/info/card-id` | info по сохранённой карте + SMS |
| POST | `/payment/v2/info` | info по номеру карты (`pan`, `expiry`) + SMS |
| POST | `/payment/v2/payment/card-id` | оплата сохранённой картой с SMS-кодом |
| POST | `/payment/v2/payment` | оплата по номеру карты с SMS-кодом |
| POST | `/payment/v1/info`, `/payment/v1/payment` | без SMS, по `card_id` |
| POST | `/payment/v3/info`, `/payment/v3/payment` | по `provider_id`; у v3 payment есть `additional_params` и `save_card` |
| POST | `/payment/fee-commission` | расчёт комиссии |
| POST | `/card/v1/add`, `/card/v1/add/confirm` | добавить карту клиенту (SMS) |
| GET | `/card/client-card/get-all/{client_id}` | карты клиента |
| DELETE | `/card/client-card/remove` | удалить карту |
| GET | `/transaction/v1/get-detail/by-transaction-id/{transaction_id}` | детали транзакции |
| GET | `/constants/v1/*` | справочники: типы карт, статусы |
| POST | `/auth/sign-in` | вход по логину/паролю |

## Схемы

**`POST /payment/v2/info/card-id`** — обязательны `kassa_id`, `param_in_values`, `card_id`, `client_id`:
```json
{
  "kassa_id": "3f65645e-62d0-40b9-913b-091ea0541d31",
  "param_in_values": { "payment_id": "<из payment/create>" },
  "card_id": "…",
  "client_id": "…",
  "sms_suffix": "…"
}
```
Ответ `data`: `card_id`, `receipt_id`, `masked_phone`, `verification_code_id`,
`info[]` (`{key, value, sort_order}` — то, что вернул наш `/info`), `wait_time`,
`sms_provider_type` (`SMS24`/`TELECOM`).

**`POST /payment/v2/payment/card-id`** — все поля обязательны:
`kassa_id`, `client_id`, `card_id`, `service_commission_amount`, `param_in_values`,
`verification_code_id`, `otp_code`, `ref_id`. Предположительно `ref_id` = `receipt_id`
из info, `service_commission_amount` — из `service/v1/get` или `fee-commission` (подтвердить).
Ответ `data`: `receipt_id`, `time`, `status` (`NEW/IN_PROGRESS/ERROR/SUCCESS/CANCEL_IN_PROGRESS/CANCELLED`),
`params[]`, `amount`, `ofd{id, status, type, terminal, fiscal, url}`.

**`GET /service/v1/get`** → `data.info_service` и `data.payment_service`: `ofd_type`, `gen_type`,
`name_*`, `min_amount`, `max_amount`, `serviceCommission`, комиссии и кешбэки, и
`service_param_in_info_response_list[]` — **поля кассы**: `field_name`, `field_type`,
`required`, `read_only`, `field_size`, `values[]`.

## Правила
- **`param_in_values` — ровно поля кассы** (`param_ins`), значения — **строки** (`map<string,string>`).
  Лишние или отсутствующие поля → `code: -1039` «Xizmat parametrlari noto'g'ri».
  Так было на старой кассе: приложение слало `merchant_id` и `amount`, а касса ждала `phone`/`payer_name`.
- `merchant_id` в SDK не нужен: касса определяется по `kassa_id`.
- Нужно ли передавать `amount` в `param_in_values` — смотреть в `service/v1/get` новой кассы.
- `client_id` — клиент RealPay, к нему привязаны карты. **У каждого пользователя easy-trip
  должен быть свой**, иначе карты общие. Проверить в `auth/sdk`.
- `sms_suffix` — обычно хеш приложения для автоподстановки SMS на Android; в тесте была заглушка `smsSuffix`.
- SDK в debug-логах печатает Bearer и тела запросов — в релизе выключить.
- После `ERROR` для новой попытки нужен новый `payment/create` (новый `payment_id`).
