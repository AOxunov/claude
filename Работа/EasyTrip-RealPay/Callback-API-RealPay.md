---
tags: [работа, easy-trip, realpay, api]
date: 2026-09-17
---

# RealPay Merchant API — что реализует EasyTrip

Эти 5 эндпоинтов **вызывает RealPay**, а реализуем их мы — за каждую подключённую турфирму.
Обзор: [[00-Обзор]]. Обратная сторона: [[Agent-API-RealPay]].

Источник: [Google Doc «RealPay Merchant API»](https://docs.google.com/document/d/1H2-Q8PQJcusay0XPZJevfPcvRlthSs7qkE6cZB2Ekxo),
v1.0 от 26.01.2024, на узбекском.

## Общие правила

- `${url}` — адрес, указанный при создании кассы (`kassa.url`).
- JSON в обе стороны.
- Авторизация **Basic**: `username`/`password`, указанные при создании кассы.
- **Всегда HTTP 200.** Успех или ошибка — по `response_code`.
- Формат ответа:
  ```json
  {
    "timestamp": "12.02.2002 124500",
    "data": {
      "...": "поля ответа",
      "response_code": 0,
      "response_message": "Success"
    }
  }
  ```
- `response_code`: `0` — успех, **отрицательный** — ошибка.
- При ошибке `data` всё равно обязателен, но внутри только `response_code` и `response_message`.
- Формат `timestamp` в примере странный (`dd.MM.yyyy HHmmss`) — уточнить.
- Время во всех полях `time`: `yyyy-MM-dd HH:mm:ss`.
- Статусы транзакции на стороне мерчанта: `IN_PROGRESS`, `SUCCESS`, `ERROR`, `CANCELLED`.

| # | Метод | Путь | Кто определяет кассу |
|---|---|---|---|
| 1 | POST | `${url}/info` | `kassa_id` в теле |
| 2 | POST | `${url}/payment` | `kassa_id` в теле |
| 3 | GET | `${url}/check-status?transaction_id=…` | только через нашу таблицу или Basic-логин |
| 4 | PUT | `${url}/cancel` | только через нашу таблицу или Basic-логин |
| 5 | GET | `${url}/reconciliation?from_date=…&to_date=…` | **только Basic-логин** или свой id в URL |

Почему это важно для агента — см. [[00-Обзор#Как понять, к какой турфирме пришёл запрос]].

---

## 1. Info — проверка перед оплатой

Клиент ввёл данные — RealPay спрашивает, что это за услуга и можно ли её оплатить.

**Запрос** `POST ${url}/info`
```json
{
  "amount": 1000,
  "kassa_id": "6ba860d2-8df6-4fb3-a2e0-8e04b1615785",
  "body": { "pinfl": "12" }
}
```
- `amount` — сумма, которую клиент хочет заплатить.
- `body` — поля из `param_ins` кассы (`field_name` → значение).
- `kassa_id` есть в примере, но отсутствует в таблице полей.

**Ответ** `data`:
- `additional` — `Map<String,String>`, ключи из `info_service_param_outs`; показывается клиенту.
- `ofd` — фискальные данные:
  - `items[]` — позиции чека;
  - `location` — `{longitude, latitude}`, необязательно;
  - `extra_info` — `{phone_number}` покупателя, на него придёт налоговый кешбэк; необязательно.

Поля `ofd.items[]`:

| Поле | Смысл |
|---|---|
| `name` | название товара/услуги, в конце — единица измерения |
| `barcode` | штрихкод |
| `label` | код маркировки |
| `spic` | ИКПУ (MXIK), определяется на tasnif.soliq.uz |
| `package_code` | код упаковки |
| `good_price` | цена одной единицы |
| `price` | сумма позиции с учётом количества, **без** скидок |
| `vat` | сумма НДС |
| `vat_percent` | ставка НДС |
| `amount` | количество |
| `discount` | скидка |
| `other` | прочие скидки (страховка и т.п.) |
| `commission_info` | `{tin, pinfl}` комитента |

```json
{
  "timestamp": "12.02.2002 124500",
  "data": {
    "additional": { "fio": "Anvar Sanayev", "k_name": "G'uncha", "group": "A18" },
    "ofd": {
      "items": [
        {
          "name": "name", "barcode": "barcode", "label": "label", "spic": "spic",
          "package_code": "packageCode", "good_price": 100000, "price": 100000,
          "vat": 12, "vat_percent": 12, "amount": 1, "discount": 100, "other": 10000,
          "commission_info": { "tin": "123213123", "pinfl": "12345678901234" }
        }
      ],
      "location": { "longitude": "45.34322", "latitude": "44.342234" },
      "extra_info": { "phone_number": "998956623636" }
    },
    "response_code": 0,
    "response_message": "Success"
  }
}
```

**Наша логика:**
1. Проверить Basic-авторизацию и что логин принадлежит кассе `kassa_id`.
2. Найти бронь по полям `body`.
3. Проверить: бронь существует, не оплачена, `amount` совпадает с суммой брони
   и укладывается в `min_amount`/`max_amount` кассы.
4. Вернуть `additional` и `ofd.items` с ИКПУ, НДС и ИНН турфирмы в `commission_info`.
5. Иначе — отрицательный `response_code` с понятным `response_message`.

---

## 2. Payment — уведомление об оплате

Вызывается **дважды** на одну транзакцию: сначала `IN_PROGRESS`, когда оплата началась,
затем `SUCCESS` или `ERROR`, когда закончилась.

**Запрос** `POST ${url}/payment`
```json
{
  "transaction_id": "123456",
  "time": "2024-01-25 14:30:00",
  "kassa_id": "6ba860d2-8df6-4fb3-a2e0-8e04b1615785",
  "amount": 1000,
  "status": "IN_PROGRESS",
  "description": "To'lov jarayonda",
  "payment_type": "PAYMENT",
  "body": { "pinfl": "12312312312312" }
}
```
- `transaction_id` — уникальный id в RealPay.
- `payment_type` — `HOLD` или `PAYMENT`. Как завершается `HOLD`, не описано.
- `status` — `IN_PROGRESS`, `SUCCESS`, `ERROR`.
- `time` — когда транзакция записана в RealPay.

**Ответ** `data`:
```json
{
  "time": "2024-01-26 12:09:38",
  "status": "SUCCESS",
  "transaction_id": "R10PB0000116",
  "external_id": "2b453c78-e781-4b7a-8357-1b9be65a67e7",
  "amount": 3000000,
  "additional": { "id": "2b453c78-e781-4b7a-8357-1b9be65a67e7", "message": "Success" },
  "response_code": 0,
  "response_message": "Success"
}
```
- `time` — когда транзакция записана у нас.
- `status` — статус у нас.
- `external_id` — наш уникальный id транзакции.
- `additional` — ключи из `payment_service_param_outs`.

**Наша логика:**
1. `transaction_id` — UNIQUE в БД. Upsert, а не insert.
2. `IN_PROGRESS` → создать транзакцию, связать с бронью. Бронь **ещё не оплачена**.
3. `SUCCESS` → отметить бронь оплаченной, выдать ваучер и т.п.
4. `ERROR` → закрыть транзакцию, бронь снова доступна для оплаты.
5. Повторный вызов с тем же статусом → вернуть тот же ответ, ничего не делать повторно.
6. Сверять `amount` и `kassa_id` с сохранёнными при `IN_PROGRESS`.

---

## 3. Check status — статус транзакции

**Запрос** `GET ${url}/check-status?transaction_id=R10PD0000083`

**Ответ** `data` — как у `/payment`: `time` (последнее изменение у нас), `status`,
`external_id`, `transaction_id`, `amount`, `additional`.

> [!important]
> Если транзакции у нас нет — **строго `response_code: -99999`**.

---

## 4. Cancel — отмена

Если мы подтверждаем отмену, клиенту возвращается **вся** сумма на карту,
а комиссию RealPay оплачивает мерчант.

**Запрос** `PUT ${url}/cancel`
```json
{ "transaction_id": "RP123456" }
```

**Ответ** `data`:
```json
{
  "time": "2024-01-26 12:09:38",
  "status": "CANCELLED",
  "transaction_id": "R10PB0000116",
  "external_id": "2b453c78-e781-4b7a-8357-1b9be65a67e7",
  "response_code": 0,
  "response_message": "Success"
}
```

**Наша логика:** отменять только из `SUCCESS`; отменить бронь. Может ли турфирма
отказать в отмене (например, тур уже прошёл) через отрицательный код — уточнить.

---

## 5. Reconciliation — сверка

**Запрос** `GET ${url}/reconciliation?from_date=…&to_date=…`
- Формат дат `yyyy-MM-dd HH:mm:ss`; пробел в query кодируется (`%20`).

**Ответ** `data`:
```json
{
  "transactions": [
    {
      "time": "2024-01-26 12:09:35",
      "status": "SUCCESS",
      "transaction_id": "R10PB0000115",
      "external_id": "1b453c78-e781-4b7a-8357-1b9be65a67e6",
      "amount": 1000000
    }
  ],
  "response_code": 0,
  "response_message": "Success"
}
```
- `time` — последнее изменение транзакции у нас.

**Наша логика:** отдавать транзакции **только кассы, от имени которой пришёл запрос**
(по Basic-логину). Фильтровать по времени создания или последнего изменения — уточнить.

---

## Огрехи в Google Doc

- У `location` перепутаны описания: `longitude` подписан как «kenglik» (широта),
  `latitude` — как «uzunlik» (долгота).
- Типы `longitude`, `latitude`, `phone_number` указаны NUMBER, а в примерах — строки.
- В примере `/info` бессмысленный `vat_percent: 123` (в заметке заменён на 12).
- В примере ответа `/payment` лишняя `}` и `...` — JSON невалиден.
- `kassa_id` есть в примерах запросов `/info` и `/payment`, но отсутствует в таблицах полей.
- У `/reconciliation` поле `transactions` описано как «id транзакции в RealPay», хотя это список.
- Единицы суммы (сумы или тийины) нигде не указаны.
- Из отрицательных кодов определён только `-99999`; остальные — на усмотрение мерчанта.
