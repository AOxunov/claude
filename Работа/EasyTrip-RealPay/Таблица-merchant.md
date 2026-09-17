---
tags: [работа, easy-trip, realpay, бд]
date: 2026-09-17
---

# Таблица `merchant`

Турфирма, подключённая к RealPay через easy-trip как агента. **Одна строка = одна турфирма
= один мерчант RealPay = одна касса.** Большая часть колонок — это поля запроса
`merchant/v1/create` и сохранённые куски его ответа.

Контекст: [[00-Обзор]], поля API — [[Agent-API-RealPay]] (раздел про `merchant/v1/create`).

Условные обозначения: ❓ — назначение не подтверждено, это предположение.

## DDL

```sql
-- auto-generated definition
create table merchant
(
    id                     uuid      default gen_random_uuid() not null
        primary key,
    state                  smallint  default 1,
    version                integer   default 1,
    created_at             timestamp default now(),
    updated_at             timestamp,
    created_by             uuid,
    updated_by             uuid,
    update_id              bigint,
    attributes             json,
    place_id               uuid,
    client_id              bigint,
    checkout_id            uuid,
    payment_purpose        varchar(20),
    status                 varchar(30),
    name                   varchar(255),
    name_uz                varchar(150),
    name_ru                varchar(150),
    name_en                varchar(150),
    business_form_id       smallint,
    business_category_id   smallint,
    brand_name             varchar(255),
    address                varchar(255),
    tin_or_pinfl           bigint,
    gov_reg_number         varchar(50),
    gov_reg_date           date,
    gov_reg_place          varchar(255),
    oked_code              varchar(5),
    owner_phone            varchar(15),
    owner_pinfl            bigint,
    owner_id_number        varchar(9),
    owner_full_name        varchar,
    owner_id_issuer        varchar,
    owner_id_date          date,
    owner_id_expiry_date   date,
    owner_email            varchar,
    bank_account           varchar(25),
    mfo                    varchar(5),
    bank_name              varchar,
    merchant_bank          jsonb,
    merchant_info_response jsonb,
    kassa_response         jsonb,
    type                   varchar,
    payment_type_id        integer,
    document_date          timestamp,
    company_signed_at      timestamp,
    merchant_signed_at     timestamp,
    is_commitent           boolean   default false,
    kassa_id               varchar(100),
    merchant_rp_id         integer,
    document_url           varchar(255)
);

comment on column merchant.merchant_rp_id is 'Мерчантни реалпейдаги ID си.
Шу ID орқали get-detail-by-id аписига мурожаат қилиш мумкин.';

alter table merchant
    owner to project;
```

Комментарий к `merchant_rp_id` в переводе: «ID мерчанта в RealPay. По нему можно
обращаться к API get-detail-by-id» (на деле эндпоинт называется `merchant/v1/get-by-id/{id}`).

`-- auto-generated definition` — так DataGrip подписывает выгруженный DDL, к платформе это не относится.

## Колонки по группам

### 1. Служебные колонки платформы
Типовой набор, который, судя по названиям, есть у таблиц конструктора.

| Колонка | Что это |
|---|---|
| `id` | первичный ключ easy-trip (UUID). **Не** id в RealPay — тот в `merchant_rp_id` |
| `state` | ❓ признак активности/мягкого удаления записи, по умолчанию `1` |
| `version` | ❓ номер версии записи (оптимистичная блокировка), по умолчанию `1` |
| `created_at`, `updated_at` | когда создана / изменена |
| `created_by`, `updated_by` | ❓ UUID пользователя платформы, создавшего / изменившего запись |
| `update_id` | ❓ служебный идентификатор изменения; в JWT easy-trip тоже есть claim `update_id` |
| `attributes` | ❓ произвольные доп. атрибуты (JSON) |

### 2. Связи внутри easy-trip
| Колонка | Что это |
|---|---|
| `place_id` | ❓ объект easy-trip (место / турфирма в каталоге), к которому привязан мерчант |
| `client_id` | ❓ клиент/организация в платформе |
| `checkout_id` | ❓ не ясно: касса оплаты платформы или сущность RealPay (`MERCHANT_CHECKOUT` есть среди типов пользователей RealPay) |
| `payment_type_id` | ❓ ссылка на справочник способов оплаты проекта |
| `payment_purpose` | ❓ назначение платежа; у кассы RealPay есть поле `payment_purpose` (`kassa/v1/{kassaId}`) |

### 3. Данные турфирмы → `merchant.merchant` в запросе создания
| Колонка | Поле API | Примечание |
|---|---|---|
| `name` | `name` | юридическое название |
| `brand_name` | `brand_name` | обязательно в API |
| `address` | `address` | |
| `tin_or_pinfl` | `tin_or_pinfl` | ИНН (9 цифр) или ПИНФЛ ИП (14 цифр). В API — **строка** |
| `business_form_id` | `business_form_id` | id из `GET /const/v1/business-forms` |
| `business_category_id` | `business_category_id` | id из `GET /const/v1/business-categories/{business_activity_id}` |
| `gov_reg_number`, `gov_reg_date`, `gov_reg_place` | те же | госрегистрация; формат даты в API не указан |
| `oked_code` | `oked_code` | код ОКЭД, 5 цифр |
| `type` | `type` | `PRIVATE` или `BUDGET`; турфирмы — `PRIVATE` |
| `is_commitent` | — | результат `GET /ofd/v1/check-commitent`: зарегистрирована ли фирма комитентом в ОФД |

### 4. Название кассы → `kassa` в запросе создания
| Колонка | Поле API | Примечание |
|---|---|---|
| `name_uz`, `name_ru`, `name_en` | `kassa.name_uz/ru/en` | ❓ скорее всего, название кассы — так турфирма видна клиентам в приложении RealPay |

### 5. Владелец → `merchant.merchant_owner`
Все поля обязательны в API, кроме `email`.

| Колонка | Поле API | Формат по API |
|---|---|---|
| `owner_full_name` | `full_name` | |
| `owner_phone` | `phone` | `998XXXXXXXXX`, 12 цифр |
| `owner_pinfl` | `pinfl` | 14 цифр, в API строка |
| `owner_id_number` | `id_number` | серия и номер паспорта `AA1234567` |
| `owner_id_issuer` | `id_issuer` | кем выдан |
| `owner_id_date`, `owner_id_expiry_date` | `id_date`, `id_expiry_date` | формат даты в API не указан |
| `owner_email` | `email` | необязательно |

### 6. Банковский счёт → `merchant.merchant_banks[0]`
| Колонка | Поле API | Примечание |
|---|---|---|
| `mfo` | `mfo` | МФО банка, 5 цифр |
| `bank_account` | `bank_account` | расчётный счёт, 20 цифр. Сюда RealPay переводит выплаты |
| `bank_name` | — | из `GET /const/v1/bank-details/{mfo}` → `bank_name` |
| `merchant_bank` | ответ `merchant_bank[]` | ❓ снимок списка счетов из ответа RealPay |

Бюджетного счёта (`budget_account`, 27 цифр) в таблице нет — для частных турфирм он не нужен.

### 7. Результат регистрации в RealPay (ответ `merchant/v1/create`)
| Колонка | Откуда в ответе | Зачем |
|---|---|---|
| `merchant_rp_id` | `data.merchant_response.merchant_info_response.id` | id мерчанта в RealPay → `merchant/v1/get-by-id/{id}` |
| `kassa_id` | `data.kassa_response.id` | UUID кассы. **Приходит в каждом `/info` и `/payment`** — по нему находим турфирму |
| `merchant_info_response` | `data.merchant_response.merchant_info_response` | снимок данных мерчанта (JSON) |
| `kassa_response` | `data.kassa_response` | снимок данных кассы (JSON): статус, лимиты, `credentials` |
| `status` | ❓ `merchant_info_response.status` | статус мерчанта: `NEW → MERCHANT_SIGNED → MODERATED → ACTIVE`, либо `REJECTED` / `INACTIVE` |

### 8. Договор
| Колонка | Откуда | Что это |
|---|---|---|
| `document_url` | `merchant_info_response.document_url` | ссылка на договор; турфирма подписывает его (EIMZO и т.п.) |
| `document_date` | `merchant_info_response.document_date` | дата договора |
| `merchant_signed_at` | `merchant_info_response.merchant_signed_at` | когда подписала турфирма |
| `company_signed_at` | `merchant_info_response.company_signed_at` | когда подписала другая сторона (RealPay / SMARTMARKETPLACE) |

## Как заполняется строка

1. **Анкета турфирмы** → группы 3–6 и связи (`place_id` и др.).
2. `ofd/v1/check-commitent` → `is_commitent`.
3. `merchant/v1/create` → `merchant_rp_id`, `kassa_id`, `document_url`, `status`, JSON-снимки ответа.
4. Турфирма подписывает договор → `merchant_signed_at`, затем `company_signed_at`,
   `status` двигается дальше. Обновлять опросом `merchant/v1/get-by-id/{merchant_rp_id}`
   или `merchant/v1/contract-status`.
5. RealPay активирует кассу → статус кассы `ACCEPTED`. Отдельной колонки для него нет,
   он виден только внутри `kassa_response` (снимок на момент сохранения).
6. С этого момента по `kassa_id` принимаем `/info` и `/payment` ([[Callback-API-RealPay]]).

## Замечания (на 2026-09-17, не исправлено)

- `merchant_rp_id integer` — в RealPay это `int64` → лучше `bigint`.
- `kassa_id varchar(100)` — в RealPay это UUID → тип `uuid` и **уникальный индекс**:
  каждый `/info` и `/payment` ищет мерчанта по этому полю.
- `status` один, а статусов три: мерчанта (`NEW…ACTIVE`), договора (`NEW/SIGNED/CANCELLED`),
  кассы (`NEW/ACCEPTED/REJECTED/MODIFIED/DELETED`). Платежи можно принимать только
  при кассе `ACCEPTED` → статус кассы стоит хранить отдельной колонкой, а не только в JSON.
- `tin_or_pinfl`, `owner_pinfl` — `bigint`, хотя это идентификаторы и API работает
  со строками. `varchar(14)` надёжнее (ведущих нулей у них, впрочем, не бывает).
- Одна касса на турфирму заложена в структуру. Если понадобится вторая
  (`kassa/v1/create`), кассы придётся вынести в отдельную таблицу.
- Логина/пароля кассы в таблице нет — они общие и задаются шаблоном кассы
  (`kassa-template`); хранить их в секретах, не в БД и не в git.
