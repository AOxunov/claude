-- =====================================================================================
-- EasyTrip: скидочные карты X2 / X5 / X10 и розыгрыши призов
-- База microservice, схема project, PostgreSQL 17.
-- Проверено на PostgreSQL 17.11 с дампом прода от 02.11.2026 (03-Тесты-локально.sql).
--
-- Запуск:  psql -v ON_ERROR_STOP=1 -d microservice -f 01-DDL.sql
--   * Одна транзакция: при любой ошибке не создаётся ничего.
--   * lock_timeout 5 с: если places или realpay_transaction заняты дольше, скрипт упадёт
--     сам, а не повесит очередь запросов к ним. Тогда просто запустить ещё раз.
--   * Запускать можно под своим пользователем: скрипт сам переходит на роль project
--     (set local role), и все объекты сразу принадлежат ей, как после
--     «alter … owner to project». Нужно право на эту роль — проверка 2 в
--     04-Проверки-на-сервере.sql. После commit пользователь снова свой.
--
-- Что меняется в существующих таблицах:
--   places              + колонка card_discount_max_usd, триггер истории скидки;
--   realpay_transaction + триггер на смену status: подтверждает, снимает и возвращает
--                         скидки, активирует и отзывает карты.
-- Откат: 02-Откат.sql. Модель, решения и вызовы из конструктора: 00-Обзор.md.
--
-- Деньги:
--   * Остатки, веса и фонды — в долларах. В каждой операции с деньгами в сумах хранятся
--     сумма в сумах и курс ЦБ на дату (таблица ti_currency_rates).
--   * Первоисточник — журналы (ti_bonus_card_ledger, ti_bonus_prize_fund_ledger), строки
--     только добавляются. Остаток на карте — кеш, сверка: view ti_bonus_card_mismatches.
--   * Все изменения — функциями. Карты туриста блокируются всегда в одном порядке
--     (старые первыми), поэтому параллельные оплаты не задваивают списание и не ловят
--     взаимную блокировку.
--   * Время — timestamptz; границы дня и «через месяц» — по Asia/Tashkent.
-- =====================================================================================

begin;
set local lock_timeout = '5s';
-- владелец всех новых таблиц, вью и функций — роль конструктора project
set local role project;


-- =====================================================================================
-- 1. Курсы ЦБ
-- =====================================================================================

create table project.ti_currency_rates
(
    currency   varchar(3)     not null,
    rate_date  date           not null,
    rate       numeric(14, 4) not null check (rate > 0),
    source     varchar(20)    not null default 'CBU',
    created_at timestamptz    not null default now(),
    updated_at timestamptz,
    primary key (currency, rate_date)
);
comment on table project.ti_currency_rates is 'Курсы ЦБ Узбекистана по датам: сколько сумов за 1 единицу валюты';
comment on column project.ti_currency_rates.rate_date is 'Дата, с которой действует курс (поле Date в ответе cbu.uz)';


-- Загрузка ответа https://cbu.uz/uz/arkhiv-kursov-valyut/json/ (массив или один элемент).
-- Повторный вызов с теми же данными ничего не меняет.
create function project.ti_currency_rates_load_cbu(p_json jsonb)
    returns integer
    language plpgsql
as
$$
declare
    v_rows integer;
begin
    insert into project.ti_currency_rates (currency, rate_date, rate, source)
    select upper(e ->> 'Ccy'),
           to_date(e ->> 'Date', 'DD.MM.YYYY'),
           round((e ->> 'Rate')::numeric / coalesce(nullif(e ->> 'Nominal', '')::numeric, 1), 4),
           'CBU'
    from jsonb_array_elements(case jsonb_typeof(p_json)
                                  when 'array' then p_json
                                  else jsonb_build_array(p_json) end) as e
    where e ->> 'Ccy' is not null
      and e ->> 'Rate' is not null
      and e ->> 'Date' is not null
    on conflict (currency, rate_date) do update
        set rate       = excluded.rate,
            updated_at = now()
    where project.ti_currency_rates.rate is distinct from excluded.rate;

    get diagnostics v_rows = row_count;
    return v_rows;
end;
$$;


-- Курс на момент p_at: последний не позже этого дня по Ташкенту.
-- Старше 7 дней — ошибка: значит, курсы перестали загружаться.
create function project.ti_currency_rate(p_currency varchar, p_at timestamptz default now(),
                                      out rate numeric, out rate_date date)
    language plpgsql
    stable
as
$$
declare
    v_day  date := (p_at at time zone 'Asia/Tashkent')::date;
    v_rate numeric;
    v_date date;
begin
    select r.rate, r.rate_date
    into v_rate, v_date
    from project.ti_currency_rates r
    where r.currency = upper(p_currency)
      and r.rate_date <= v_day
    order by r.rate_date desc
    limit 1;

    if v_rate is null or v_date < v_day - 7 then
        raise exception 'Нет свежего курса % на %: последний от %', upper(p_currency), v_day, v_date;
    end if;
    rate := v_rate;
    rate_date := v_date;
end;
$$;


-- =====================================================================================
-- 2. Типы карт
-- =====================================================================================

create table project.ti_bonus_card_types
(
    id                uuid           not null default gen_random_uuid() primary key,
    state             smallint       not null default 1,
    version           integer                 default 1,
    created_at        timestamptz             default now(),
    updated_at        timestamptz,
    created_by        uuid,
    updated_by        uuid,
    update_id         bigint,
    attributes        json,
    code              varchar(20)    not null unique,
    name_uz           varchar(150),
    name_ru           varchar(150),
    name_en           varchar(150),
    price_usd         numeric(12, 2) not null check (price_usd > 0),
    total_usd         numeric(12, 2) not null check (total_usd > 0),
    initial_usd       numeric(12, 2) not null,
    accrual_usd       numeric(12, 2) not null check (accrual_usd > 0),
    accrual_interval  interval       not null default '7 days',
    burn_usd          numeric(12, 2) not null check (burn_usd > 0),
    burn_interval     interval       not null default '1 month',
    fund_tourist_rate numeric(6, 4)  not null,
    fund_object_rate  numeric(6, 4)  not null,
    is_on_sale        boolean        not null default true,
    sort_order        smallint,
    check (initial_usd >= 0 and initial_usd <= total_usd),
    check (accrual_interval > interval '0' and burn_interval > interval '0'),
    check (fund_tourist_rate >= 0 and fund_object_rate >= 0 and fund_tourist_rate + fund_object_rate <= 1)
);
comment on table project.ti_bonus_card_types is 'Типы скидочных карт и их условия. Купленная карта копирует условия к себе: смена типа не меняет уже проданные карты';
comment on column project.ti_bonus_card_types.price_usd is 'Цена = номинал, $';
comment on column project.ti_bonus_card_types.total_usd is 'Всего скидочных средств после полного накопления, $';
comment on column project.ti_bonus_card_types.initial_usd is 'Начисляется сразу после оплаты, $';
comment on column project.ti_bonus_card_types.accrual_usd is 'Прибавка за каждый accrual_interval, пока не наберётся total_usd';
comment on column project.ti_bonus_card_types.burn_usd is 'Сгорает за раз после полного накопления (или весь остаток, если он меньше)';
comment on column project.ti_bonus_card_types.burn_interval is 'Сгорание — каждый такой срок от даты полного накопления, по графику; покупки его не сдвигают';
comment on column project.ti_bonus_card_types.fund_tourist_rate is 'Доля потраченного и сгоревшего в призовой фонд туристов: 1 / кратность / 2 (X2 — 0.25, X5 — 0.1, X10 — 0.05)';
comment on column project.ti_bonus_card_types.fund_object_rate is 'То же в призовой фонд объектов. Вместе две доли = 1 / кратность: за жизнь карты в фонды уходит вся её цена';

-- Схема из статьи: при покупке 1× номинала, дальше +1× в неделю до 2× / 5× / 10×.
-- В фонды — потраченное и сгоревшее, делённое на кратность, пополам туристам и объектам.
insert into project.ti_bonus_card_types (code, name_uz, name_ru, name_en, price_usd, total_usd, initial_usd,
                                      accrual_usd, burn_usd, fund_tourist_rate, fund_object_rate, sort_order)
values ('X2', 'X2 chegirma kartasi', 'Скидочная карта X2', 'X2 discount card', 20, 40, 20, 20, 20, 0.25, 0.25, 1),
       ('X5', 'X5 chegirma kartasi', 'Скидочная карта X5', 'X5 discount card', 50, 250, 50, 50, 50, 0.1, 0.1, 2),
       ('X10', 'X10 chegirma kartasi', 'Скидочная карта X10', 'X10 discount card', 100, 1000, 100, 100, 100, 0.05, 0.05, 3);


-- =====================================================================================
-- 3. Карты
-- =====================================================================================

create table project.ti_bonus_cards
(
    id               uuid           not null default gen_random_uuid() primary key,
    state            smallint       not null default 1,
    version          integer                 default 1,
    created_at       timestamptz             default now(),
    updated_at       timestamptz,
    created_by       uuid,
    updated_by       uuid,
    update_id        bigint,
    attributes       json,
    card_number      varchar(16) unique check (card_number ~ '^[0-9]{16}$'),
    card_type_id     uuid           not null references project.ti_bonus_card_types (id),
    user_id          uuid           not null,
    referrer_user_id uuid,
    status           varchar(20)    not null default 'PENDING'
        check (status in ('PENDING', 'ACTIVE', 'CANCELLED', 'REVOKED')),
    -- условия на момент покупки
    price_usd        numeric(12, 2) not null,
    total_usd        numeric(12, 2) not null,
    initial_usd      numeric(12, 2) not null,
    accrual_usd      numeric(12, 2) not null,
    accrual_interval interval       not null,
    burn_usd         numeric(12, 2) not null,
    burn_interval    interval       not null,
    -- оплата карты
    payment_id       uuid unique references project.realpay_transaction (id),
    pay_amount       numeric(15, 2),
    pay_currency     varchar(10)             default 'UZS',
    rate             numeric(14, 4),
    rate_date        date,
    -- состояние
    activated_at     timestamptz,
    accrued_usd      numeric(12, 2) not null default 0,
    balance_usd      numeric(12, 2) not null default 0,
    next_accrual_at  timestamptz,
    fully_accrued_at timestamptz,
    last_spent_at    timestamptz,
    last_burned_at   timestamptz,
    burn_count       smallint       not null default 0,
    next_burn_at     timestamptz,
    next_event_at    timestamptz generated always as (least(next_accrual_at, next_burn_at)) stored,
    closed_at        timestamptz,
    check (balance_usd >= 0),
    check (accrued_usd >= 0 and accrued_usd <= total_usd),
    check (referrer_user_id is distinct from user_id),
    check (status <> 'ACTIVE' or (activated_at is not null and card_number is not null))
);
create index ti_bonus_cards_user_idx on project.ti_bonus_cards (user_id, activated_at);
create index ti_bonus_cards_due_idx on project.ti_bonus_cards (next_event_at) where status = 'ACTIVE' and next_event_at is not null;
create index ti_bonus_cards_referrer_idx on project.ti_bonus_cards (referrer_user_id) where referrer_user_id is not null;

comment on table project.ti_bonus_cards is 'Скидочные карты туристов (виртуальные). Строка появляется при заказе (PENDING), активируется после оплаты RealPay';
comment on column project.ti_bonus_cards.card_number is '16 цифр, последняя — контрольная по Луну; выдаётся при активации, случайный (соседние номера не угадать)';
comment on column project.ti_bonus_cards.user_id is 'Владелец: auth_users.user_id (как в realpay_transaction)';
comment on column project.ti_bonus_cards.referrer_user_id is 'Кто привёл туриста (для реферальной программы, пока не используется)';
comment on column project.ti_bonus_cards.status is 'PENDING — ждёт оплаты; ACTIVE — оплачена; CANCELLED — оплата не прошла; REVOKED — платёж за карту отменён, остаток списан';
comment on column project.ti_bonus_cards.payment_id is 'Платёж RealPay за карту';
comment on column project.ti_bonus_cards.pay_amount is 'Цена карты в сумах по курсу ЦБ на день покупки';
comment on column project.ti_bonus_cards.balance_usd is 'Доступный остаток, $ (кеш: сумма ti_bonus_card_ledger по карте)';
comment on column project.ti_bonus_cards.accrued_usd is 'Всего начислено, $';
comment on column project.ti_bonus_cards.last_spent_at is 'Когда средствами карты последний раз оплатили покупку (на сгорание не влияет)';
comment on column project.ti_bonus_cards.burn_count is 'Сколько раз уже сгорало: следующее сгорание = полное накопление + (burn_count + 1) × burn_interval';
comment on column project.ti_bonus_cards.next_burn_at is 'Следующее сгорание по графику от полного накопления; покупки его не сдвигают. NULL — не накоплено полностью или остаток 0';
comment on column project.ti_bonus_cards.next_event_at is 'Ближайшее начисление или сгорание — по нему cron выбирает карты';


-- =====================================================================================
-- 4. Скидки по карте при оплате объекту
-- =====================================================================================

create table project.ti_bonus_discounts
(
    id               uuid           not null default gen_random_uuid() primary key,
    state            smallint       not null default 1,
    version          integer                 default 1,
    created_at       timestamptz             default now(),
    updated_at       timestamptz,
    created_by       uuid,
    updated_by       uuid,
    update_id        bigint,
    attributes       json,
    user_id          uuid           not null,
    place_id         uuid           not null references project.places (id),
    payment_id       uuid           not null unique references project.realpay_transaction (id),
    status           varchar(20)    not null default 'RESERVED'
        check (status in ('RESERVED', 'CONFIRMED', 'RELEASED', 'REFUNDED')),
    currency         varchar(10)    not null default 'UZS',
    price_amount     numeric(15, 2) not null check (price_amount > 0),
    discount_percent smallint       not null check (discount_percent between 1 and 100),
    max_discount_usd numeric(12, 2),
    discount_amount  numeric(15, 2) not null check (discount_amount > 0),
    pay_amount       numeric(15, 2) not null check (pay_amount > 0),
    rate             numeric(14, 4) not null check (rate > 0),
    rate_date        date           not null,
    discount_usd     numeric(12, 2) not null check (discount_usd > 0),
    shortfall_usd    numeric(12, 2) not null default 0 check (shortfall_usd >= 0 and shortfall_usd <= discount_usd),
    returned_usd     numeric(12, 2) check (returned_usd >= 0),
    reserved_at      timestamptz    not null default now(),
    confirmed_at     timestamptz,
    released_at      timestamptz,
    refunded_at      timestamptz,
    check (pay_amount = price_amount - discount_amount),
    check (status not in ('CONFIRMED', 'REFUNDED') or confirmed_at is not null)
);
create index ti_bonus_discounts_user_idx on project.ti_bonus_discounts (user_id, reserved_at);
create index ti_bonus_discounts_place_idx on project.ti_bonus_discounts (place_id, confirmed_at);
create index ti_bonus_discounts_confirmed_idx on project.ti_bonus_discounts (confirmed_at) where status = 'CONFIRMED';
create index ti_bonus_discounts_reserved_idx on project.ti_bonus_discounts (reserved_at) where status = 'RESERVED';

comment on table project.ti_bonus_discounts is 'Скидка по карте в оплате RealPay: одна строка на платёж. Средства резервируются при создании платежа, списание подтверждается оплатой';
comment on column project.ti_bonus_discounts.status is 'RESERVED — средства сняты с карт, ждём оплату; CONFIRMED — оплачено; RELEASED — оплата не прошла, средства вернулись; REFUNDED — оплату отменили (средства вернулись, только если чек ещё не попал в розыгрыш)';
comment on column project.ti_bonus_discounts.returned_usd is 'Сколько вернулось на карты при RELEASED / REFUNDED; 0 у REFUNDED — отмена после розыгрыша, средства не вернулись';
comment on column project.ti_bonus_discounts.price_amount is 'Полная цена, сумы (то, что ввёл турист)';
comment on column project.ti_bonus_discounts.discount_percent is 'Скидка объекта на момент оплаты, %';
comment on column project.ti_bonus_discounts.max_discount_usd is 'Потолок скидки объекта за чек на момент оплаты, $';
comment on column project.ti_bonus_discounts.discount_amount is 'Скидка, целые сумы';
comment on column project.ti_bonus_discounts.pay_amount is 'К оплате в RealPay = цена − скидка (это же пишется в realpay_transaction.amount)';
comment on column project.ti_bonus_discounts.discount_usd is 'Скидка в $ по курсу ЦБ: столько снято с карт; это же вес в розыгрышах';
comment on column project.ti_bonus_discounts.shortfall_usd is 'Сколько не удалось снять с карт, если оплата пришла уже после снятия резерва';


-- =====================================================================================
-- 5. Журнал операций по картам
-- =====================================================================================

create table project.ti_bonus_card_ledger
(
    id                uuid           not null default gen_random_uuid() primary key,
    created_at        timestamptz    not null default clock_timestamp(),
    created_by        uuid,
    card_id           uuid           not null references project.ti_bonus_cards (id),
    user_id           uuid           not null,
    op_type           varchar(20)    not null
        check (op_type in ('ISSUE', 'ACCRUAL', 'SPEND', 'RELEASE', 'REFUND', 'BURN', 'REVOKE', 'ADJUST')),
    amount_usd        numeric(12, 2) not null check (amount_usd <> 0),
    balance_after_usd numeric(12, 2) not null check (balance_after_usd >= 0),
    discount_id       uuid references project.ti_bonus_discounts (id),
    occurred_at       timestamptz    not null,
    comment           varchar(255),
    check (case
               when op_type in ('ISSUE', 'ACCRUAL', 'RELEASE', 'REFUND') then amount_usd > 0
               when op_type in ('SPEND', 'BURN', 'REVOKE') then amount_usd < 0
               else true end),
    check ((op_type in ('SPEND', 'RELEASE', 'REFUND')) = (discount_id is not null))
);
create index ti_bonus_card_ledger_card_idx on project.ti_bonus_card_ledger (card_id, created_at);
create index ti_bonus_card_ledger_discount_idx on project.ti_bonus_card_ledger (discount_id) where discount_id is not null;
create index ti_bonus_card_ledger_burn_idx on project.ti_bonus_card_ledger (occurred_at) where op_type = 'BURN';
-- начисление и сгорание по графику не задвоятся, даже если cron запустится дважды
create unique index ti_bonus_card_ledger_schedule_uidx on project.ti_bonus_card_ledger (card_id, op_type, occurred_at)
    where op_type in ('ACCRUAL', 'BURN');

comment on table project.ti_bonus_card_ledger is 'Все движения средств по картам, $. Строки только добавляются; остаток карты = сумма amount_usd';
comment on column project.ti_bonus_card_ledger.op_type is 'ISSUE — сразу после оплаты; ACCRUAL — по графику; SPEND — скидка; RELEASE — резерв снят; REFUND — возврат покупки; BURN — сгорание; REVOKE — списание при отмене оплаты карты; ADJUST — ручная правка';
comment on column project.ti_bonus_card_ledger.occurred_at is 'Время по бизнес-смыслу: для начислений и сгораний — по графику, даже если cron обработал позже';


-- =====================================================================================
-- 6. Розыгрыши
-- =====================================================================================

create table project.ti_bonus_draws
(
    id                 uuid        not null default gen_random_uuid() primary key,
    state              smallint    not null default 1,
    version            integer              default 1,
    created_at         timestamptz          default now(),
    updated_at         timestamptz,
    created_by         uuid,
    updated_by         uuid,
    update_id          bigint,
    attributes         json,
    audience           varchar(10) not null check (audience in ('TOURIST', 'OBJECT')),
    kind               varchar(10) not null default 'PERIOD' check (kind in ('DAILY', 'PERIOD')),
    title              varchar(255),
    period_from        timestamptz not null,
    period_to          timestamptz not null,
    status             varchar(20) not null default 'DRAFT' check (status in ('DRAFT', 'FROZEN', 'DONE', 'CANCELLED')),
    entries_count      integer,
    total_weight_cents bigint,
    prizes_count       integer,
    prize_total_usd    numeric(14, 2),
    entries_hash       varchar(64),
    random_response    text,
    prev_hash          varchar(64),
    hash               varchar(64) unique,
    frozen_at          timestamptz,
    drawn_at           timestamptz,
    check (period_to > period_from),
    check (status not in ('FROZEN', 'DONE') or (frozen_at is not null and entries_hash is not null)),
    check (status <> 'DONE' or (drawn_at is not null and hash is not null))
);
create unique index ti_bonus_draws_daily_uidx on project.ti_bonus_draws (audience, period_from)
    where kind = 'DAILY' and status <> 'CANCELLED';
create index ti_bonus_draws_status_idx on project.ti_bonus_draws (status, period_to);
create index ti_bonus_draws_chain_idx on project.ti_bonus_draws (drawn_at, id) where status = 'DONE';

comment on table project.ti_bonus_draws is 'Розыгрыши: отдельно для туристов и для объектов, ежедневные и за период, который задаёт компания';
comment on column project.ti_bonus_draws.period_to is 'Конец периода, не включительно';
comment on column project.ti_bonus_draws.status is 'DRAFT — призы можно менять; FROZEN — участники и веса зафиксированы, призы списаны из фонда; DONE — проведён; CANCELLED — отменён';
comment on column project.ti_bonus_draws.prizes_count is 'Сколько мест реально разыгрывается: не больше, чем участников';
comment on column project.ti_bonus_draws.prize_total_usd is 'Сколько списано из фонда на призы при фиксации';
comment on column project.ti_bonus_draws.entries_hash is 'sha256 списка участников с весами и диапазонами; передаётся в random.org в userData';
comment on column project.ti_bonus_draws.random_response is 'Ответ random.org как есть (с подписью)';
comment on column project.ti_bonus_draws.prev_hash is 'Хеш предыдущего проведённого розыгрыша (цепочка)';
comment on column project.ti_bonus_draws.hash is 'sha256 содержимого розыгрыша вместе с prev_hash; публиковать, чтобы правку задним числом было видно';


create table project.ti_bonus_draw_prizes
(
    id         uuid           not null default gen_random_uuid() primary key,
    state      smallint       not null default 1,
    version    integer                 default 1,
    created_at timestamptz             default now(),
    updated_at timestamptz,
    created_by uuid,
    updated_by uuid,
    update_id  bigint,
    attributes json,
    draw_id    uuid           not null references project.ti_bonus_draws (id),
    place_no   smallint       not null check (place_no > 0),
    amount_usd numeric(12, 2) not null check (amount_usd > 0),
    unique (draw_id, place_no)
);
comment on table project.ti_bonus_draw_prizes is 'Призовые места розыгрыша и суммы, $ (вводит компания). Меняются только пока розыгрыш DRAFT';


create table project.ti_bonus_draw_entries
(
    draw_id      uuid           not null references project.ti_bonus_draws (id),
    entry_no     integer        not null check (entry_no > 0),
    user_id      uuid,
    place_id     uuid references project.places (id),
    spent_usd    numeric(14, 2) not null default 0,
    burned_usd   numeric(14, 2) not null default 0,
    weight_cents bigint         not null check (weight_cents > 0),
    range_from   bigint         not null,
    range_to     bigint         not null,
    primary key (draw_id, entry_no),
    unique (draw_id, user_id),
    unique (draw_id, place_id),
    check (num_nonnulls(user_id, place_id) = 1),
    check (range_to - range_from + 1 = weight_cents)
);
comment on table project.ti_bonus_draw_entries is 'Участники розыгрыша, зафиксированные при FROZEN. Вес в центах; диапазоны билетов подряд: 1..w1, w1+1..w1+w2, ...';
comment on column project.ti_bonus_draw_entries.spent_usd is 'Турист: потраченные скидочные средства за период; объект: выданные скидки';
comment on column project.ti_bonus_draw_entries.burned_usd is 'Турист: сгоревшие за период средства';


create table project.ti_bonus_draw_winners
(
    id                uuid           not null default gen_random_uuid() primary key,
    state             smallint       not null default 1,
    version           integer                 default 1,
    created_at        timestamptz             default now(),
    updated_at        timestamptz,
    created_by        uuid,
    updated_by        uuid,
    update_id         bigint,
    attributes        json,
    draw_id           uuid           not null references project.ti_bonus_draws (id),
    prize_id          uuid           not null unique references project.ti_bonus_draw_prizes (id),
    entry_no          integer        not null,
    user_id           uuid,
    place_id          uuid references project.places (id),
    amount_usd        numeric(12, 2) not null,
    round_no          smallint       not null,
    random_value      numeric        not null,
    round_total_cents bigint         not null,
    ticket            bigint         not null,
    payout_status     varchar(20)    not null default 'PENDING' check (payout_status in ('PENDING', 'PAID', 'CANCELLED')),
    paid_at           timestamptz,
    paid_amount       numeric(15, 2),
    paid_currency     varchar(10),
    paid_rate         numeric(14, 4),
    payout_ref        varchar(100),
    foreign key (draw_id, entry_no) references project.ti_bonus_draw_entries (draw_id, entry_no),
    unique (draw_id, entry_no),
    unique (draw_id, round_no)
);
comment on table project.ti_bonus_draw_winners is 'Победители: один приз на участника. Меняются только поля выплаты';
comment on column project.ti_bonus_draw_winners.random_value is 'Число random.org для этого тура, [0; 1)';
comment on column project.ti_bonus_draw_winners.round_total_cents is 'Сумма весов участников, ещё не выигравших к этому туру';
comment on column project.ti_bonus_draw_winners.ticket is 'Выпавший билет: floor(random_value × round_total_cents) + 1 среди оставшихся участников по порядку entry_no';


-- =====================================================================================
-- 7. Призовые фонды
-- =====================================================================================

create table project.ti_bonus_prize_fund_ledger
(
    id             uuid           not null default gen_random_uuid() primary key,
    created_at     timestamptz    not null default clock_timestamp(),
    created_by     uuid,
    fund           varchar(10)    not null check (fund in ('TOURIST', 'OBJECT')),
    op_type        varchar(20)    not null check (op_type in ('SPEND', 'BURN', 'REFUND', 'PRIZE', 'PRIZE_RETURN', 'ADJUST')),
    amount_usd     numeric(14, 4) not null check (amount_usd <> 0),
    card_id        uuid references project.ti_bonus_cards (id),
    discount_id    uuid references project.ti_bonus_discounts (id),
    card_ledger_id uuid references project.ti_bonus_card_ledger (id),
    draw_id        uuid references project.ti_bonus_draws (id),
    occurred_at    timestamptz    not null,
    comment        varchar(255),
    check (case
               when op_type in ('SPEND', 'BURN', 'PRIZE_RETURN') then amount_usd > 0
               when op_type in ('REFUND', 'PRIZE') then amount_usd < 0
               else true end)
);
create index ti_bonus_prize_fund_ledger_fund_idx on project.ti_bonus_prize_fund_ledger (fund, occurred_at);
create index ti_bonus_prize_fund_ledger_discount_idx on project.ti_bonus_prize_fund_ledger (discount_id) where discount_id is not null;
-- защита от двойного взноса при повторных вызовах
create unique index ti_bonus_prize_fund_ledger_spend_uidx on project.ti_bonus_prize_fund_ledger (discount_id, card_id, fund) where op_type = 'SPEND';
create unique index ti_bonus_prize_fund_ledger_refund_uidx on project.ti_bonus_prize_fund_ledger (discount_id, card_id, fund) where op_type = 'REFUND';
create unique index ti_bonus_prize_fund_ledger_burn_uidx on project.ti_bonus_prize_fund_ledger (card_ledger_id, fund) where op_type = 'BURN';
create unique index ti_bonus_prize_fund_ledger_prize_uidx on project.ti_bonus_prize_fund_ledger (draw_id, op_type) where op_type in ('PRIZE', 'PRIZE_RETURN');

comment on table project.ti_bonus_prize_fund_ledger is 'Движения призовых фондов, $. Взносы — доля потраченного и сгоревшего (по типу карты), расходы — призы. Строки только добавляются';
comment on column project.ti_bonus_prize_fund_ledger.op_type is 'SPEND / BURN — взнос от покупки / сгорания; REFUND — снятие взноса при возврате покупки; PRIZE — призы розыгрыша; PRIZE_RETURN — возврат при отмене розыгрыша; ADJUST — ручное пополнение или правка';

create view project.ti_bonus_prize_fund_balance as
select f.fund,
       coalesce(sum(l.amount_usd), 0)                                                         as balance_usd,
       coalesce(sum(l.amount_usd) filter (where l.op_type in ('SPEND', 'BURN', 'REFUND')), 0) as collected_usd,
       coalesce(-sum(l.amount_usd) filter (where l.op_type in ('PRIZE', 'PRIZE_RETURN')), 0)  as prizes_usd,
       coalesce(sum(l.amount_usd) filter (where l.op_type = 'ADJUST'), 0)                     as adjusted_usd
from (values ('TOURIST'::varchar), ('OBJECT'::varchar)) as f(fund)
         left join project.ti_bonus_prize_fund_ledger l on l.fund = f.fund
group by f.fund;
comment on view project.ti_bonus_prize_fund_balance is 'Остатки призовых фондов туристов и объектов, $';


-- =====================================================================================
-- 8. Скидка объекта: потолок за чек и история изменений
-- =====================================================================================

alter table project.places
    add column card_discount_max_usd numeric(12, 2)
        constraint ti_chk_card_discount_max_usd check (card_discount_max_usd > 0);
comment on column project.places.card_discount_max_usd is 'Потолок скидки по карте easy-trip за один чек, $; NULL — без потолка';

create table project.ti_bonus_place_discount_history
(
    id               uuid        not null default gen_random_uuid() primary key,
    created_at       timestamptz not null default now(),
    place_id         uuid        not null references project.places (id) on delete cascade,
    discount_percent smallint    not null,
    max_discount_usd numeric(12, 2),
    changed_by       uuid
);
create index ti_bonus_place_discount_history_place_idx on project.ti_bonus_place_discount_history (place_id, created_at);
comment on table project.ti_bonus_place_discount_history is 'История скидки объекта для держателей карты: % и потолок за чек; новая строка при каждом изменении';

create function project.ti_bonus_trg_place_discount_history()
    returns trigger
    language plpgsql
as
$$
begin
    if (tg_op = 'INSERT' and (coalesce(new.card_discount_percentage, 0) > 0 or new.card_discount_max_usd is not null))
        or (tg_op = 'UPDATE' and (new.card_discount_percentage is distinct from old.card_discount_percentage
                                  or new.card_discount_max_usd is distinct from old.card_discount_max_usd)) then
        insert into project.ti_bonus_place_discount_history (place_id, discount_percent, max_discount_usd, changed_by)
        values (new.id, coalesce(new.card_discount_percentage, 0), new.card_discount_max_usd,
                coalesce(new.updated_by, new.created_by));
    end if;
    return null;
end;
$$;

create trigger ti_trg_bonus_place_discount_history
    after insert or update of card_discount_percentage, card_discount_max_usd
    on project.places
    for each row
execute function project.ti_bonus_trg_place_discount_history();

-- стартовая точка истории — текущие скидки
insert into project.ti_bonus_place_discount_history (place_id, discount_percent, max_discount_usd)
select p.id, p.card_discount_percentage, p.card_discount_max_usd
from project.places p
where p.card_discount_percentage > 0;


-- =====================================================================================
-- 9. Журнал сбоев
-- =====================================================================================

create table project.ti_bonus_errors
(
    id         uuid        not null default gen_random_uuid() primary key,
    created_at timestamptz not null default clock_timestamp(),
    source     varchar(50) not null,
    payment_id uuid,
    message    text,
    detail     text
);
create index ti_bonus_errors_created_idx on project.ti_bonus_errors (created_at);
comment on table project.ti_bonus_errors is 'Сбои бонусной логики в триггере платежа. Платёж при этом сохраняется, расхождение потом исправляет ti_bonus_sync()';


-- =====================================================================================
-- 10. Вспомогательные функции
-- =====================================================================================

-- Календарная арифметика по Ташкенту: «через месяц» — то же число следующего месяца.
create function project.ti_bonus_add_interval(p_at timestamptz, p_interval interval)
    returns timestamptz
    language sql
    stable
as
$$
select ((p_at at time zone 'Asia/Tashkent') + p_interval) at time zone 'Asia/Tashkent'
$$;


-- Следующее сгорание по графику: полное накопление + 1, + 2, ... burn_interval.
-- Покупки график не сдвигают. До полного накопления и при нулевом остатке сгорания нет.
-- Точка, пропущенная из-за нулевого остатка, сработает задним числом, когда средства вернутся:
-- зарезервировать всё неоплаченным платежом перед сгоранием и снять резерв после — не спасает.
create function project.ti_bonus_next_burn(p_fully_accrued_at timestamptz, p_burn_count integer,
                                        p_balance_usd numeric, p_burn_interval interval)
    returns timestamptz
    language sql
    stable
as
$$
select case
           when p_fully_accrued_at is not null and p_balance_usd > 0
               then project.ti_bonus_add_interval(p_fully_accrued_at, p_burn_interval * (p_burn_count + 1))
           end
$$;


-- Контрольная цифра Луна: удваивается каждая вторая цифра справа, начиная с последней.
create function project.ti_bonus_luhn_digit(p_digits varchar)
    returns char
    language sql
    immutable
as
$$
select ((10 - sum(case
                      when (length(p_digits) - s.i) % 2 = 0 then (s.d * 2) / 10 + (s.d * 2) % 10
                      else s.d end) % 10) % 10)::char
from (select g.i, substr(p_digits, g.i, 1)::integer as d
      from generate_series(1, length(p_digits)) as g(i)) s
$$;


-- Новый номер карты: 15 случайных цифр + контрольная.
-- Случайность — из gen_random_uuid (криптостойкий генератор); 13-й символ uuid — версия, его пропускаем.
create function project.ti_bonus_card_number_new()
    returns varchar
    language plpgsql
as
$$
declare
    v_hex    text;
    v_body   varchar;
    v_number varchar;
begin
    loop
        v_hex := replace(gen_random_uuid()::text, '-', '');
        v_body := lpad(((('x' || substr(v_hex, 1, 12) || substr(v_hex, 14, 3))::bit(60)::bigint)
                        % 1000000000000000)::text, 15, '0');
        v_number := v_body || project.ti_bonus_luhn_digit(v_body);
        exit when not exists (select 1 from project.ti_bonus_cards c where c.card_number = v_number);
    end loop;
    return v_number;
end;
$$;


-- Взнос в призовые фонды: доли по типу карты. p_amount_usd — сколько потрачено или сгорело (> 0).
create function project.ti_bonus_fund_contribute(p_op_type varchar, p_card_id uuid, p_amount_usd numeric,
                                              p_occurred_at timestamptz, p_discount_id uuid default null,
                                              p_card_ledger_id uuid default null)
    returns void
    language sql
as
$$
insert into project.ti_bonus_prize_fund_ledger (fund, op_type, amount_usd, card_id, discount_id, card_ledger_id, occurred_at)
select f.fund, p_op_type, round(p_amount_usd * f.share, 4), p_card_id, p_discount_id, p_card_ledger_id, p_occurred_at
from project.ti_bonus_cards c
         join project.ti_bonus_card_types t on t.id = c.card_type_id
         cross join lateral (values ('TOURIST', t.fund_tourist_rate), ('OBJECT', t.fund_object_rate)) as f(fund, share)
where c.id = p_card_id
  and round(p_amount_usd * f.share, 4) > 0
on conflict do nothing
$$;


-- =====================================================================================
-- 11. Карты: заказ, активация, начисления, сгорания
-- =====================================================================================

-- Начисления и сгорания по графику до p_until. Повторный вызов ничего не задваивает.
create function project.ti_bonus_card_process(p_card_id uuid, p_until timestamptz default now())
    returns void
    language plpgsql
as
$$
declare
    c         project.ti_bonus_cards%rowtype;
    v_amount  numeric;
    v_burn_at timestamptz;
    v_ledger  uuid;
    v_changed boolean := false;
begin
    select * into c from project.ti_bonus_cards where id = p_card_id for update;
    if not found or c.status <> 'ACTIVE' then
        return;
    end if;

    -- начисления: каждое — отдельной строкой со временем по графику
    while c.next_accrual_at is not null and c.next_accrual_at <= p_until and c.accrued_usd < c.total_usd
        loop
            v_amount := least(c.accrual_usd, c.total_usd - c.accrued_usd);
            c.accrued_usd := c.accrued_usd + v_amount;
            c.balance_usd := c.balance_usd + v_amount;
            insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd, occurred_at)
            values (c.id, c.user_id, 'ACCRUAL', v_amount, c.balance_usd, c.next_accrual_at);
            if c.accrued_usd >= c.total_usd then
                c.fully_accrued_at := c.next_accrual_at;
                c.next_accrual_at := null;
            else
                c.next_accrual_at := project.ti_bonus_add_interval(c.next_accrual_at, c.accrual_interval);
            end if;
            v_changed := true;
        end loop;

    -- сгорания по графику от полного накопления: номинал или весь остаток, если он меньше
    loop
        v_burn_at := project.ti_bonus_next_burn(c.fully_accrued_at, c.burn_count, c.balance_usd, c.burn_interval);
        exit when v_burn_at is null or v_burn_at > p_until;
        v_amount := least(c.burn_usd, c.balance_usd);
        c.balance_usd := c.balance_usd - v_amount;
        c.last_burned_at := v_burn_at;
        c.burn_count := c.burn_count + 1;
        insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd, occurred_at)
        values (c.id, c.user_id, 'BURN', -v_amount, c.balance_usd, v_burn_at)
        returning id into v_ledger;
        perform project.ti_bonus_fund_contribute('BURN', c.id, v_amount, v_burn_at, null, v_ledger);
        v_changed := true;
    end loop;

    v_burn_at := project.ti_bonus_next_burn(c.fully_accrued_at, c.burn_count, c.balance_usd, c.burn_interval);
    if v_changed or v_burn_at is distinct from c.next_burn_at then
        update project.ti_bonus_cards
        set accrued_usd      = c.accrued_usd,
            balance_usd      = c.balance_usd,
            next_accrual_at  = c.next_accrual_at,
            fully_accrued_at = c.fully_accrued_at,
            last_burned_at   = c.last_burned_at,
            burn_count       = c.burn_count,
            next_burn_at     = v_burn_at,
            updated_at       = now()
        where id = c.id;
    end if;
end;
$$;


-- Для cron: карты, у которых подошло начисление или сгорание. Возвращает число обработанных.
-- p_limit = null — без ограничения; p_skip_locked = false — ждать карты, занятые оплатой.
create function project.ti_bonus_cards_process_due(p_until timestamptz default now(), p_limit integer default 1000,
                                                p_skip_locked boolean default true)
    returns integer
    language plpgsql
as
$$
declare
    v_id    uuid;
    v_count integer := 0;
begin
    if p_skip_locked then
        for v_id in
            select c.id
            from project.ti_bonus_cards c
            where c.status = 'ACTIVE'
              and c.next_event_at <= p_until
            order by c.next_event_at
            limit p_limit for update skip locked
            loop
                perform project.ti_bonus_card_process(v_id, p_until);
                v_count := v_count + 1;
            end loop;
    else
        for v_id in
            select c.id
            from project.ti_bonus_cards c
            where c.status = 'ACTIVE'
              and c.next_event_at <= p_until
            order by c.next_event_at
            limit p_limit for update
            loop
                perform project.ti_bonus_card_process(v_id, p_until);
                v_count := v_count + 1;
            end loop;
    end if;
    return v_count;
end;
$$;


-- Блокирует активные карты туриста в одном и том же порядке (старые первыми),
-- по желанию догоняет начисления и сгорания. Возвращает общий остаток, $.
create function project.ti_bonus_lock_user_cards(p_user_id uuid, p_process boolean default true)
    returns numeric
    language plpgsql
as
$$
declare
    v_id      uuid;
    v_balance numeric;
begin
    for v_id in
        select c.id
        from project.ti_bonus_cards c
        where c.user_id = p_user_id
          and c.status = 'ACTIVE'
        order by c.activated_at, c.id
        for update
        loop
            if p_process then
                perform project.ti_bonus_card_process(v_id);
            end if;
        end loop;

    select coalesce(sum(c.balance_usd), 0)
    into v_balance
    from project.ti_bonus_cards c
    where c.user_id = p_user_id
      and c.status = 'ACTIVE';
    return v_balance;
end;
$$;


-- Цена карты в сумах по курсу ЦБ (целые сумы). Пусто — карта не найдена или не продаётся.
create function project.ti_bonus_card_quote(p_type_code varchar, p_at timestamptz default now())
    returns table
            (
                card_type_id uuid,
                code         varchar,
                price_usd    numeric,
                total_usd    numeric,
                rate         numeric,
                rate_date    date,
                pay_amount   numeric,
                pay_currency varchar
            )
    language sql
    stable
as
$$
select t.id, t.code, t.price_usd, t.total_usd, r.rate, r.rate_date, round(t.price_usd * r.rate, 0), 'UZS'::varchar
from project.ti_bonus_card_types t
         cross join project.ti_currency_rate('USD', p_at) r
where t.code = upper(p_type_code)
  and t.state = 1
  and t.is_on_sale
$$;


-- Заказ карты к уже созданному платежу RealPay (статус NEW, сумма = цена из ti_bonus_card_quote).
-- Владелец — пользователь платежа. Повторный вызов возвращает ту же карту.
create function project.ti_bonus_card_order(p_payment_id uuid, p_type_code varchar, p_referrer_user_id uuid default null)
    returns uuid
    language plpgsql
as
$$
declare
    t    project.realpay_transaction%rowtype;
    q    record;
    v_id uuid;
begin
    select * into t from project.realpay_transaction where id = p_payment_id for update;
    if not found or t.state is distinct from 1 then
        raise exception 'Платёж % не найден', p_payment_id;
    end if;

    select c.id into v_id from project.ti_bonus_cards c where c.payment_id = p_payment_id;
    if found then
        return v_id;
    end if;
    if t.status <> 'NEW' then
        raise exception 'Платёж % уже в статусе %', p_payment_id, t.status;
    end if;
    if exists (select 1 from project.ti_bonus_discounts d where d.payment_id = p_payment_id) then
        raise exception 'Платёж % — оплата объекту, а не покупка карты', p_payment_id;
    end if;

    select * into q from project.ti_bonus_card_quote(p_type_code);
    if not found then
        raise exception 'Карта % не найдена или не продаётся', p_type_code;
    end if;
    if t.amount <> q.pay_amount then
        raise exception 'Сумма платежа % не равна цене карты %: % сум по курсу %', t.amount, q.code, q.pay_amount, q.rate;
    end if;

    insert into project.ti_bonus_cards (card_type_id, user_id, referrer_user_id, price_usd, total_usd, initial_usd,
                                     accrual_usd, accrual_interval, burn_usd, burn_interval,
                                     payment_id, pay_amount, pay_currency, rate, rate_date)
    select ct.id, t.user_id, nullif(p_referrer_user_id, t.user_id), ct.price_usd, ct.total_usd, ct.initial_usd,
           ct.accrual_usd, ct.accrual_interval, ct.burn_usd, ct.burn_interval,
           t.id, t.amount, 'UZS', q.rate, q.rate_date
    from project.ti_bonus_card_types ct
    where ct.id = q.card_type_id
    returning id into v_id;
    return v_id;
end;
$$;


-- Активация после оплаты: номер, сразу initial_usd, график начислений от p_at.
-- Из CANCELLED тоже: оплата могла прийти после того, как заказ сочли брошенным.
create function project.ti_bonus_card_activate(p_card_id uuid, p_at timestamptz default now())
    returns void
    language plpgsql
as
$$
declare
    c project.ti_bonus_cards%rowtype;
begin
    select * into c from project.ti_bonus_cards where id = p_card_id for update;
    if not found then
        raise exception 'Карта % не найдена', p_card_id;
    end if;
    if c.status = 'ACTIVE' then
        return;
    end if;
    if c.status not in ('PENDING', 'CANCELLED') then
        raise exception 'Карту % в статусе % нельзя активировать', p_card_id, c.status;
    end if;

    update project.ti_bonus_cards
    set status           = 'ACTIVE',
        card_number      = project.ti_bonus_card_number_new(),
        activated_at     = p_at,
        accrued_usd      = c.initial_usd,
        balance_usd      = c.initial_usd,
        next_accrual_at  = case
                               when c.initial_usd < c.total_usd
                                   then project.ti_bonus_add_interval(p_at, c.accrual_interval) end,
        fully_accrued_at = case when c.initial_usd >= c.total_usd then p_at end,
        burn_count       = 0,
        next_burn_at     = case
                               when c.initial_usd >= c.total_usd
                                   then project.ti_bonus_next_burn(p_at, 0, c.initial_usd, c.burn_interval) end,
        closed_at        = null,
        updated_at       = now()
    where id = p_card_id;

    if c.initial_usd > 0 then
        insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd, occurred_at)
        values (c.id, c.user_id, 'ISSUE', c.initial_usd, c.initial_usd, p_at);
    end if;

    -- активация задним числом (p_at в прошлом) — сразу догоняем график
    perform project.ti_bonus_card_process(p_card_id);
end;
$$;


-- Оплата карты не прошла.
create function project.ti_bonus_card_cancel(p_card_id uuid)
    returns void
    language sql
as
$$
update project.ti_bonus_cards
set status     = 'CANCELLED',
    closed_at  = now(),
    updated_at = now()
where id = p_card_id
  and status = 'PENDING'
$$;


-- Платёж за карту отменён: остаток списывается, начисления прекращаются.
create function project.ti_bonus_card_revoke(p_card_id uuid, p_reason varchar default null)
    returns void
    language plpgsql
as
$$
declare
    c project.ti_bonus_cards%rowtype;
begin
    select * into c from project.ti_bonus_cards where id = p_card_id for update;
    if not found or c.status in ('REVOKED', 'CANCELLED') then
        return;
    end if;
    if c.status = 'PENDING' then
        perform project.ti_bonus_card_cancel(p_card_id);
        return;
    end if;

    if c.balance_usd > 0 then
        insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd, occurred_at, comment)
        values (c.id, c.user_id, 'REVOKE', -c.balance_usd, 0, now(), p_reason);
    end if;
    update project.ti_bonus_cards
    set status          = 'REVOKED',
        balance_usd     = 0,
        next_accrual_at = null,
        next_burn_at    = null,
        closed_at       = now(),
        updated_at      = now()
    where id = p_card_id;
end;
$$;


-- Карты туриста для приложения: сначала догоняет начисления и сгорания.
create function project.ti_bonus_user_cards(p_user_id uuid)
    returns setof project.ti_bonus_cards
    language plpgsql
as
$$
begin
    perform project.ti_bonus_lock_user_cards(p_user_id);
    return query
        select *
        from project.ti_bonus_cards c
        where c.user_id = p_user_id
          and c.status in ('ACTIVE', 'REVOKED')
        order by c.activated_at, c.id;
end;
$$;


-- =====================================================================================
-- 12. Скидки: резерв, подтверждение, снятие резерва, возврат
-- =====================================================================================

-- Списать со старых карт, остаток — со следующих. Карты уже заблокированы вызывающей функцией.
-- Возвращает, сколько удалось списать.
create function project.ti_bonus_debit_cards(p_user_id uuid, p_amount_usd numeric, p_discount_id uuid)
    returns numeric
    language plpgsql
as
$$
declare
    c      record;
    v_left numeric := p_amount_usd;
    v_take numeric;
begin
    for c in
        select bc.id, bc.balance_usd
        from project.ti_bonus_cards bc
        where bc.user_id = p_user_id
          and bc.status = 'ACTIVE'
          and bc.balance_usd > 0
        order by bc.activated_at, bc.id
        loop
            exit when v_left <= 0;
            v_take := least(c.balance_usd, v_left);
            update project.ti_bonus_cards
            set balance_usd  = balance_usd - v_take,
                next_burn_at = project.ti_bonus_next_burn(fully_accrued_at, burn_count, balance_usd - v_take, burn_interval),
                updated_at   = now()
            where id = c.id;
            insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd,
                                                   discount_id, occurred_at)
            values (c.id, p_user_id, 'SPEND', -v_take, c.balance_usd - v_take, p_discount_id, now());
            v_left := v_left - v_take;
        end loop;
    return p_amount_usd - v_left;
end;
$$;


-- Вернуть на каждую карту то, что с неё чистыми списано по чеку. Отозванным картам не возвращается.
create function project.ti_bonus_credit_back(p_discount_id uuid, p_op_type varchar, p_comment varchar default null)
    returns numeric
    language plpgsql
as
$$
declare
    r       record;
    v_bal   numeric;
    v_total numeric := 0;
begin
    for r in
        select l.card_id, l.user_id, -sum(l.amount_usd) as net
        from project.ti_bonus_card_ledger l
        where l.discount_id = p_discount_id
        group by l.card_id, l.user_id
        having -sum(l.amount_usd) > 0
        order by l.card_id
        loop
            update project.ti_bonus_cards
            set balance_usd  = balance_usd + r.net,
                next_burn_at = project.ti_bonus_next_burn(fully_accrued_at, burn_count, balance_usd + r.net, burn_interval),
                updated_at   = now()
            where id = r.card_id
              and status = 'ACTIVE'
            returning balance_usd into v_bal;
            if found then
                insert into project.ti_bonus_card_ledger (card_id, user_id, op_type, amount_usd, balance_after_usd,
                                                       discount_id, occurred_at, comment)
                values (r.card_id, r.user_id, p_op_type, r.net, v_bal, p_discount_id, now(), p_comment);
                v_total := v_total + r.net;
            end if;
        end loop;
    return v_total;
end;
$$;


-- Скидка к новому платежу объекту (вызывать в payment/create сразу после вставки платежа).
-- Резервирует средства карт и уменьшает realpay_transaction.amount до суммы к оплате.
-- Нет карты, остатка или скидки у объекта — возвращает discount_id = null и полную сумму.
-- p_min_pay — сколько минимум должно остаться к оплате (min_amount кассы RealPay).
create function project.ti_bonus_discount_apply(p_payment_id uuid, p_min_pay numeric default 1000)
    returns table
            (
                discount_id     uuid,
                price_amount    numeric,
                discount_amount numeric,
                pay_amount      numeric,
                discount_usd    numeric,
                balance_usd     numeric
            )
    language plpgsql
as
$$
declare
    t           project.realpay_transaction%rowtype;
    d           project.ti_bonus_discounts%rowtype;
    r           record;
    v_pct       smallint;
    v_cap       numeric;
    v_rate      numeric;
    v_rate_date date;
    v_balance   numeric;
    v_limit_usd numeric;
    v_disc      numeric;
    v_disc_usd  numeric;
begin
    select * into t from project.realpay_transaction rt where rt.id = p_payment_id for update;
    if not found or t.state is distinct from 1 then
        raise exception 'Платёж % не найден', p_payment_id;
    end if;

    -- повторный вызов: отдаём уже зафиксированную скидку
    select * into d from project.ti_bonus_discounts bd where bd.payment_id = p_payment_id;
    if found then
        return query
            select d.id, d.price_amount, d.discount_amount, d.pay_amount, d.discount_usd,
                   (select coalesce(sum(c.balance_usd), 0)
                    from project.ti_bonus_cards c
                    where c.user_id = d.user_id
                      and c.status = 'ACTIVE');
        return;
    end if;
    if t.status <> 'NEW' then
        raise exception 'Платёж % уже в статусе %', p_payment_id, t.status;
    end if;
    if exists (select 1 from project.ti_bonus_cards c where c.payment_id = p_payment_id) then
        raise exception 'Платёж % — покупка карты, скидка к нему не применяется', p_payment_id;
    end if;

    -- прежние неоплаченные платежи туриста со скидкой снимаем с резерва: платит он сейчас этот
    for r in
        select bd.id
        from project.ti_bonus_discounts bd
                 join project.realpay_transaction rt on rt.id = bd.payment_id
        where bd.user_id = t.user_id
          and bd.status = 'RESERVED'
          and rt.status = 'NEW'
        order by bd.reserved_at
        for update of rt
        loop
            perform project.ti_bonus_discount_release(r.id, 'новый платёж туриста');
        end loop;

    -- объект действует, прошёл модерацию и даёт скидку по карте
    select p.card_discount_percentage, p.card_discount_max_usd
    into v_pct, v_cap
    from project.places p
    where p.id = t.place_id
      and p.state = 1
      and p.moderator_status = 'ACCEPTED';

    -- карты туриста: блокируем, догоняем начисления и сгорания, берём остаток
    v_balance := project.ti_bonus_lock_user_cards(t.user_id);

    if coalesce(v_pct, 0) > 0 and v_balance > 0 then
        select cr.rate, cr.rate_date into v_rate, v_rate_date from project.ti_currency_rate('USD') cr;
        v_limit_usd := least(v_balance, coalesce(v_cap, v_balance));
        -- целые сумы: % объекта, но не больше остатка и потолка, и к оплате не меньше минимума
        v_disc := least(floor(t.amount * v_pct / 100), floor(v_limit_usd * v_rate), t.amount - p_min_pay);
        v_disc_usd := least(round(v_disc / v_rate, 2), v_limit_usd);
    end if;

    if coalesce(v_disc, 0) <= 0 or coalesce(v_disc_usd, 0) <= 0 then
        return query select null::uuid, t.amount, 0::numeric, t.amount, 0::numeric, v_balance;
        return;
    end if;

    insert into project.ti_bonus_discounts (user_id, place_id, payment_id, status, currency, price_amount,
                                         discount_percent, max_discount_usd, discount_amount, pay_amount,
                                         rate, rate_date, discount_usd)
    values (t.user_id, t.place_id, t.id, 'RESERVED', 'UZS', t.amount,
            v_pct, v_cap, v_disc, t.amount - v_disc,
            v_rate, v_rate_date, v_disc_usd)
    returning * into d;

    perform project.ti_bonus_debit_cards(t.user_id, v_disc_usd, d.id);

    -- в RealPay уходит сумма со скидкой: её сверяет callback /info
    update project.realpay_transaction rt
    set amount     = d.pay_amount,
        updated_at = now()
    where rt.id = t.id;

    return query select d.id, d.price_amount, d.discount_amount, d.pay_amount, d.discount_usd, v_balance - v_disc_usd;
end;
$$;


-- Оплата прошла. Обычно вызывается триггером платежа.
create function project.ti_bonus_discount_confirm(p_discount_id uuid)
    returns void
    language plpgsql
as
$$
declare
    d       project.ti_bonus_discounts%rowtype;
    r       record;
    v_short numeric := 0;
begin
    select * into d from project.ti_bonus_discounts where id = p_discount_id for update;
    if not found then
        raise exception 'Скидка % не найдена', p_discount_id;
    end if;
    if d.status in ('CONFIRMED', 'REFUNDED') then
        return;
    end if;

    perform project.ti_bonus_lock_user_cards(d.user_id);

    if d.status = 'RELEASED' then
        -- оплата пришла после снятия резерва: списываем заново, сколько есть
        v_short := d.discount_usd - project.ti_bonus_debit_cards(d.user_id, d.discount_usd, d.id);
    end if;

    update project.ti_bonus_discounts
    set status        = 'CONFIRMED',
        confirmed_at  = now(),
        shortfall_usd = v_short,
        updated_at    = now()
    where id = d.id;

    -- отметка «когда платили» на картах, с которых списано; график сгорания покупка не сдвигает
    update project.ti_bonus_cards c
    set last_spent_at = now(),
        updated_at    = now()
    where c.id in (select l.card_id
                   from project.ti_bonus_card_ledger l
                   where l.discount_id = d.id
                   group by l.card_id
                   having sum(l.amount_usd) < 0);

    -- в призовые фонды — доли от того, что фактически списано с каждой карты
    for r in
        select l.card_id, -sum(l.amount_usd) as net
        from project.ti_bonus_card_ledger l
        where l.discount_id = d.id
        group by l.card_id
        having -sum(l.amount_usd) > 0
        loop
            perform project.ti_bonus_fund_contribute('SPEND', r.card_id, r.net, now(), d.id, null);
        end loop;
end;
$$;


-- Оплата не прошла или резерв истёк: средства возвращаются на карты.
create function project.ti_bonus_discount_release(p_discount_id uuid, p_reason varchar default null)
    returns void
    language plpgsql
as
$$
declare
    d          project.ti_bonus_discounts%rowtype;
    v_returned numeric;
begin
    select * into d from project.ti_bonus_discounts where id = p_discount_id for update;
    if not found or d.status <> 'RESERVED' then
        return;
    end if;

    perform project.ti_bonus_lock_user_cards(d.user_id, false);
    v_returned := project.ti_bonus_credit_back(d.id, 'RELEASE', p_reason);

    update project.ti_bonus_discounts
    set status       = 'RELEASED',
        released_at  = now(),
        returned_usd = v_returned,
        updated_at   = now()
    where id = d.id;
end;
$$;


-- Оплату отменили (RealPay cancel). Шанс в будущих розыгрышах пропадает всегда: они берут
-- только CONFIRMED.
-- Чек ещё не попал в зафиксированный розыгрыш — скидка возвращается на карты, взносы в фонды
-- снимаются.
-- Уже попал (есть FROZEN или DONE розыгрыш, чей период накрывает чек) — средства не
-- возвращаются и взносы остаются: иначе «оплата → розыгрыш → отмена» давала бы шансы даром.
create function project.ti_bonus_discount_refund(p_discount_id uuid)
    returns void
    language plpgsql
as
$$
declare
    d          project.ti_bonus_discounts%rowtype;
    v_returned numeric := 0;
begin
    select * into d from project.ti_bonus_discounts where id = p_discount_id for update;
    if not found or d.status in ('REFUNDED', 'RELEASED') then
        return;
    end if;
    if d.status = 'RESERVED' then
        perform project.ti_bonus_discount_release(d.id, 'платёж отменён до подтверждения');
        return;
    end if;

    -- та же блокировка, что у фиксации розыгрыша: возврат и фиксация не пересекаются
    perform pg_advisory_xact_lock(hashtext('project.ti_bonus_draw_freeze'));
    if not exists (select 1
                   from project.ti_bonus_draws dr
                   where dr.status in ('FROZEN', 'DONE')
                     and d.confirmed_at >= dr.period_from
                     and d.confirmed_at < dr.period_to) then
        perform project.ti_bonus_lock_user_cards(d.user_id, false);
        v_returned := project.ti_bonus_credit_back(d.id, 'REFUND', 'возврат покупки');

        insert into project.ti_bonus_prize_fund_ledger (fund, op_type, amount_usd, card_id, discount_id, occurred_at, comment)
        select f.fund, 'REFUND', -f.amount_usd, f.card_id, f.discount_id, now(), 'возврат покупки'
        from project.ti_bonus_prize_fund_ledger f
        where f.discount_id = d.id
          and f.op_type = 'SPEND'
        on conflict do nothing;
    end if;

    update project.ti_bonus_discounts
    set status       = 'REFUNDED',
        refunded_at  = now(),
        returned_usd = v_returned,
        updated_at   = now()
    where id = d.id;
end;
$$;


-- =====================================================================================
-- 13. Связь с платежами RealPay
-- =====================================================================================

-- Реакция на новый статус платежа: карта или скидка, если платёж к ним относится.
create function project.ti_bonus_on_payment_status(p_payment_id uuid, p_status varchar)
    returns void
    language plpgsql
as
$$
declare
    v_card     uuid;
    v_discount uuid;
begin
    select c.id into v_card from project.ti_bonus_cards c where c.payment_id = p_payment_id;
    if found then
        case p_status
            when 'SUCCESS' then perform project.ti_bonus_card_activate(v_card);
            when 'ERROR' then perform project.ti_bonus_card_cancel(v_card);
            when 'CANCELLED' then perform project.ti_bonus_card_revoke(v_card, 'платёж за карту отменён');
            else null;
            end case;
        return;
    end if;

    select d.id into v_discount from project.ti_bonus_discounts d where d.payment_id = p_payment_id;
    if found then
        case p_status
            when 'SUCCESS' then perform project.ti_bonus_discount_confirm(v_discount);
            when 'ERROR' then perform project.ti_bonus_discount_release(v_discount, 'оплата не прошла');
            when 'CANCELLED' then perform project.ti_bonus_discount_refund(v_discount);
            else null;
            end case;
    end if;
end;
$$;


-- Триггер на realpay_transaction. Сбой бонусов не мешает сохранить статус платежа:
-- ошибка пишется в ti_bonus_errors, расхождение потом исправляет ti_bonus_sync().
create function project.ti_bonus_trg_payment_status()
    returns trigger
    language plpgsql
as
$$
begin
    begin
        perform project.ti_bonus_on_payment_status(new.id, new.status);
    exception
        when others then
            insert into project.ti_bonus_errors (source, payment_id, message, detail)
            values ('payment_status', new.id, sqlerrm, old.status || ' -> ' || new.status);
    end;
    return null;
end;
$$;

create trigger ti_trg_bonus_payment_status
    after update of status
    on project.realpay_transaction
    for each row
    when (old.status is distinct from new.status)
execute function project.ti_bonus_trg_payment_status();


-- Для cron раз в 10–15 минут: сводит статусы карт и скидок со статусами платежей,
-- снимает резервы старше p_reserve_ttl у неоплаченных платежей, проводит начисления и сгорания.
-- Платежи, которые сейчас обрабатывает callback, пропускает до следующего запуска.
create function project.ti_bonus_sync(p_reserve_ttl interval default '30 minutes')
    returns jsonb
    language plpgsql
as
$$
declare
    r           record;
    v_cards     integer := 0;
    v_discounts integer := 0;
    v_due       integer;
begin
    for r in
        select c.id, c.status, rt.status as pay_status, c.created_at
        from project.ti_bonus_cards c
                 join project.realpay_transaction rt on rt.id = c.payment_id
        where (c.status = 'PENDING' and (rt.status in ('SUCCESS', 'ERROR', 'CANCELLED')
            or c.created_at < now() - p_reserve_ttl))
           or (c.status = 'CANCELLED' and rt.status = 'SUCCESS')
           or (c.status = 'ACTIVE' and rt.status = 'CANCELLED')
        for update of rt skip locked
        loop
            if r.pay_status = 'SUCCESS' then
                perform project.ti_bonus_card_activate(r.id);
            elsif r.pay_status = 'CANCELLED' then
                perform project.ti_bonus_card_revoke(r.id, 'платёж за карту отменён');
            elsif r.pay_status = 'ERROR' or (r.pay_status = 'NEW' and r.created_at < now() - p_reserve_ttl) then
                perform project.ti_bonus_card_cancel(r.id);
            else
                continue; -- IN_PROGRESS: ждём RealPay
            end if;
            v_cards := v_cards + 1;
        end loop;

    for r in
        select d.id, d.status, rt.status as pay_status, d.reserved_at
        from project.ti_bonus_discounts d
                 join project.realpay_transaction rt on rt.id = d.payment_id
        where (d.status = 'RESERVED' and (rt.status in ('SUCCESS', 'ERROR', 'CANCELLED')
            or d.reserved_at < now() - p_reserve_ttl))
           or (d.status = 'RELEASED' and rt.status = 'SUCCESS')
           or (d.status = 'CONFIRMED' and rt.status = 'CANCELLED')
        for update of rt skip locked
        loop
            if r.pay_status = 'SUCCESS' then
                perform project.ti_bonus_discount_confirm(r.id);
            elsif r.pay_status = 'CANCELLED' then
                perform project.ti_bonus_discount_refund(r.id);
            elsif r.pay_status = 'ERROR' then
                perform project.ti_bonus_discount_release(r.id, 'оплата не прошла');
            elsif r.pay_status = 'NEW' then
                perform project.ti_bonus_discount_release(r.id, 'резерв истёк');
            else
                continue; -- IN_PROGRESS: ждём RealPay
            end if;
            v_discounts := v_discounts + 1;
        end loop;

    v_due := project.ti_bonus_cards_process_due();

    return jsonb_build_object('cards', v_cards, 'discounts', v_discounts, 'cards_processed', v_due);
end;
$$;


-- =====================================================================================
-- 14. Розыгрыши: создание, фиксация, проведение, проверка цепочки
-- =====================================================================================

-- Розыгрыш с призами (суммы в $, по порядку мест). p_kind: PERIOD или DAILY.
create function project.ti_bonus_draw_create(p_audience varchar, p_period_from timestamptz, p_period_to timestamptz,
                                          p_prizes_usd numeric[], p_title varchar default null,
                                          p_kind varchar default 'PERIOD', p_created_by uuid default null)
    returns uuid
    language plpgsql
as
$$
declare
    v_id uuid;
begin
    if p_prizes_usd is null or cardinality(p_prizes_usd) = 0 then
        raise exception 'Нужен хотя бы один приз';
    end if;

    insert into project.ti_bonus_draws (audience, kind, title, period_from, period_to, created_by)
    values (upper(p_audience), upper(p_kind), p_title, p_period_from, p_period_to, p_created_by)
    returning id into v_id;

    insert into project.ti_bonus_draw_prizes (draw_id, place_no, amount_usd, created_by)
    select v_id, u.ord, u.amount, p_created_by
    from unnest(p_prizes_usd) with ordinality as u(amount, ord);

    return v_id;
end;
$$;


-- Ежедневный розыгрыш за день по Ташкенту. Уже есть — возвращает его.
-- Без призов — берёт призы последнего ежедневного розыгрыша той же аудитории.
create function project.ti_bonus_draw_create_daily(p_audience varchar, p_day date, p_prizes_usd numeric[] default null,
                                                p_created_by uuid default null)
    returns uuid
    language plpgsql
as
$$
declare
    v_from timestamptz := p_day::timestamp at time zone 'Asia/Tashkent';
    v_to   timestamptz := (p_day + 1)::timestamp at time zone 'Asia/Tashkent';
    v_id   uuid;
begin
    select d.id
    into v_id
    from project.ti_bonus_draws d
    where d.kind = 'DAILY'
      and d.audience = upper(p_audience)
      and d.period_from = v_from
      and d.status <> 'CANCELLED';
    if found then
        return v_id;
    end if;

    if p_prizes_usd is null then
        select array_agg(pz.amount_usd order by pz.place_no)
        into p_prizes_usd
        from project.ti_bonus_draw_prizes pz
        where pz.state = 1
          and pz.draw_id = (select d.id
                            from project.ti_bonus_draws d
                            where d.kind = 'DAILY'
                              and d.audience = upper(p_audience)
                              and d.status <> 'CANCELLED'
                            order by d.period_from desc
                            limit 1);
    end if;

    return project.ti_bonus_draw_create(p_audience, v_from, v_to, p_prizes_usd,
                                     'Ежедневный розыгрыш ' || to_char(p_day, 'DD.MM.YYYY'), 'DAILY', p_created_by);
end;
$$;


-- sha256 списка участников: номер, участник, вес, диапазон.
create function project.ti_bonus_draw_entries_hash(p_draw_id uuid)
    returns varchar
    language sql
    stable
as
$$
select encode(sha256(convert_to(coalesce(string_agg(e.entry_no || ':' || coalesce(e.user_id::text, e.place_id::text)
                                                        || ':' || e.weight_cents || ':' || e.range_from || ':' || e.range_to,
                                                    E'\n' order by e.entry_no), ''), 'UTF8')), 'hex')
from project.ti_bonus_draw_entries e
where e.draw_id = p_draw_id
$$;


-- Содержимое проведённого розыгрыша для хеша цепочки.
create function project.ti_bonus_draw_payload(p_draw_id uuid)
    returns text
    language sql
    stable
as
$$
select concat_ws(E'\n',
                 'prev=' || coalesce(d.prev_hash, ''),
                 'draw=' || d.id,
                 'audience=' || d.audience || ';kind=' || d.kind,
                 'period=' || to_char(d.period_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '/' ||
                 to_char(d.period_to at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'entries=' || coalesce(d.entries_count, 0) || ';weight=' || coalesce(d.total_weight_cents, 0) ||
                 ';hash=' || coalesce(d.entries_hash, ''),
                 'prizes=' || coalesce((select string_agg(p.place_no || ':' || p.amount_usd, ',' order by p.place_no)
                                        from project.ti_bonus_draw_prizes p
                                        where p.draw_id = d.id
                                          and p.state = 1), ''),
                 'random=' || coalesce(d.random_response, ''),
                 'winners=' || coalesce((select string_agg(w.round_no || ':' || w.entry_no || ':' || w.ticket || ':' ||
                                                           w.amount_usd, ',' order by w.round_no)
                                         from project.ti_bonus_draw_winners w
                                         where w.draw_id = d.id), ''),
                 'drawn=' || to_char(d.drawn_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
from project.ti_bonus_draws d
where d.id = p_draw_id
$$;


-- Фиксация после конца периода: участники и веса, диапазоны билетов, списание призов из фонда.
-- Возвращает в random_request параметры запроса к random.org (добавить только apiKey).
-- Фонда не хватает — ошибка, розыгрыш остаётся DRAFT: уменьшить призы или пополнить фонд (ADJUST).
create function project.ti_bonus_draw_freeze(p_draw_id uuid)
    returns table
            (
                entries_count      integer,
                total_weight_cents bigint,
                prizes_count       integer,
                prize_total_usd    numeric,
                entries_hash       varchar,
                random_request     jsonb
            )
    language plpgsql
as
$$
declare
    d       project.ti_bonus_draws%rowtype;
    v_cnt   integer;
    v_total bigint;
    v_pcnt  integer;
    v_psum  numeric;
    v_fund  numeric;
begin
    select * into d from project.ti_bonus_draws x where x.id = p_draw_id for update;
    if not found then
        raise exception 'Розыгрыш % не найден', p_draw_id;
    end if;

    if d.status = 'DRAFT' then
        if now() < d.period_to then
            raise exception 'Период розыгрыша ещё не закончился: до %', d.period_to;
        end if;

        -- отмена оплаты ждёт конца фиксации, иначе чек мог бы и сыграть, и вернуть средства
        perform pg_advisory_xact_lock(hashtext('project.ti_bonus_draw_freeze'));

        if d.audience = 'TOURIST' then
            -- сгорания по графику до конца периода должны попасть в веса
            perform project.ti_bonus_cards_process_due(d.period_to, null, false);

            insert into project.ti_bonus_draw_entries (draw_id, entry_no, user_id, spent_usd, burned_usd,
                                                    weight_cents, range_from, range_to)
            select p_draw_id, n.rn, n.user_id, n.spent, n.burned, n.cents,
                   sum(n.cents) over (order by n.rn) - n.cents + 1,
                   sum(n.cents) over (order by n.rn)
            from (select w.*, row_number() over (order by w.first_at, w.user_id) as rn
                  from (select x.user_id,
                               sum(x.spent)                              as spent,
                               sum(x.burned)                             as burned,
                               ((sum(x.spent) + sum(x.burned)) * 100)::bigint as cents,
                               min(x.at)                                 as first_at
                        from (select bd.user_id, bd.discount_usd - bd.shortfall_usd as spent,
                                     0::numeric as burned, bd.confirmed_at as at
                              from project.ti_bonus_discounts bd
                              where bd.status = 'CONFIRMED'
                                and bd.confirmed_at >= d.period_from
                                and bd.confirmed_at < d.period_to
                              union all
                              select l.user_id, 0, -l.amount_usd, l.occurred_at
                              from project.ti_bonus_card_ledger l
                              where l.op_type = 'BURN'
                                and l.occurred_at >= d.period_from
                                and l.occurred_at < d.period_to) x
                        group by x.user_id) w
                  where w.cents > 0) n;
        else
            insert into project.ti_bonus_draw_entries (draw_id, entry_no, place_id, spent_usd,
                                                    weight_cents, range_from, range_to)
            select p_draw_id, n.rn, n.place_id, n.spent, n.cents,
                   sum(n.cents) over (order by n.rn) - n.cents + 1,
                   sum(n.cents) over (order by n.rn)
            from (select w.*, row_number() over (order by w.first_at, w.place_id) as rn
                  from (select bd.place_id,
                               sum(bd.discount_usd - bd.shortfall_usd)                  as spent,
                               (sum(bd.discount_usd - bd.shortfall_usd) * 100)::bigint  as cents,
                               min(bd.confirmed_at)                                     as first_at
                        from project.ti_bonus_discounts bd
                        where bd.status = 'CONFIRMED'
                          and bd.confirmed_at >= d.period_from
                          and bd.confirmed_at < d.period_to
                        group by bd.place_id) w
                  where w.cents > 0) n;
        end if;

        select count(*), coalesce(sum(e.weight_cents), 0)
        into v_cnt, v_total
        from project.ti_bonus_draw_entries e
        where e.draw_id = p_draw_id;

        -- мест разыгрывается не больше, чем участников: первые по порядку
        select count(*), coalesce(sum(s.amount_usd), 0)
        into v_pcnt, v_psum
        from (select pz.amount_usd
              from project.ti_bonus_draw_prizes pz
              where pz.draw_id = p_draw_id
                and pz.state = 1
              order by pz.place_no
              limit v_cnt) s;

        -- деньги на призы списываются из фонда до обращения к random.org
        if v_psum > 0 then
            perform pg_advisory_xact_lock(hashtext('project.ti_bonus_prize_fund'));
            select coalesce(sum(f.amount_usd), 0)
            into v_fund
            from project.ti_bonus_prize_fund_ledger f
            where f.fund = d.audience;
            if v_fund < v_psum then
                raise exception 'В фонде % $%, а на призы нужно $%', d.audience, round(v_fund, 2), v_psum;
            end if;
            insert into project.ti_bonus_prize_fund_ledger (fund, op_type, amount_usd, draw_id, occurred_at, comment)
            values (d.audience, 'PRIZE', -v_psum, d.id, now(), 'призы розыгрыша');
        end if;

        update project.ti_bonus_draws x
        set status             = 'FROZEN',
            frozen_at          = now(),
            entries_count      = v_cnt,
            total_weight_cents = v_total,
            prizes_count       = v_pcnt,
            prize_total_usd    = v_psum,
            entries_hash       = project.ti_bonus_draw_entries_hash(p_draw_id),
            updated_at         = now()
        where x.id = p_draw_id
        returning * into d;
    elsif d.status <> 'FROZEN' then
        raise exception 'Розыгрыш % уже в статусе %', p_draw_id, d.status;
    end if;

    return query
        select d.entries_count, d.total_weight_cents, d.prizes_count, d.prize_total_usd, d.entries_hash,
               jsonb_build_object('jsonrpc', '2.0',
                                  'method', 'generateSignedDecimalFractions',
                                  'params', jsonb_build_object('n', greatest(d.prizes_count, 1),
                                                               'decimalPlaces', 14,
                                                               'replacement', true,
                                                               'userData', jsonb_build_object('draw_id', d.id,
                                                                                              'entries_hash', d.entries_hash)),
                                  'id', 1);
end;
$$;


-- Проведение по ответу random.org (generateSignedDecimalFractions, userData из ti_bonus_draw_freeze).
-- Тур k: билет = floor(число_k × сумма весов оставшихся) + 1; победители прошлых туров выбывают.
-- Повторный вызов для проведённого розыгрыша возвращает тех же победителей.
create function project.ti_bonus_draw_run(p_draw_id uuid, p_random_response text)
    returns table
            (
                round_no   integer,
                place_no   integer,
                amount_usd numeric,
                entry_no   integer,
                user_id    uuid,
                place_id   uuid,
                ticket     bigint
            )
    language plpgsql
as
$$
declare
    d        project.ti_bonus_draws%rowtype;
    v_resp   jsonb;
    v_data   jsonb;
    v_left   bigint;
    v_round  integer;
    v_value  numeric;
    v_ticket bigint;
    v_prev   varchar;
    e        record;
    pz       record;
begin
    select * into d from project.ti_bonus_draws x where x.id = p_draw_id for update;
    if not found then
        raise exception 'Розыгрыш % не найден', p_draw_id;
    end if;

    if d.status = 'FROZEN' then
        if d.prizes_count > 0 then
            begin
                v_resp := p_random_response::jsonb;
            exception
                when others then
                    raise exception 'Ответ random.org — не JSON';
            end;
            if v_resp #>> '{result,random,userData,draw_id}' is distinct from d.id::text
                or v_resp #>> '{result,random,userData,entries_hash}' is distinct from d.entries_hash then
                raise exception 'Ответ random.org получен не для этого розыгрыша: userData не совпадает';
            end if;
            v_data := v_resp #> '{result,random,data}';
            if jsonb_typeof(v_data) is distinct from 'array' or jsonb_array_length(v_data) < d.prizes_count then
                raise exception 'В ответе random.org меньше % чисел', d.prizes_count;
            end if;

            v_left := d.total_weight_cents;
            for v_round in 1..d.prizes_count
                loop
                    v_value := (v_data ->> (v_round - 1))::numeric;
                    if v_value is null or v_value < 0 or v_value >= 1 then
                        raise exception 'Число random.org № % вне [0; 1): %', v_round, v_value;
                    end if;
                    v_ticket := floor(v_value * v_left)::bigint + 1;

                    select s.entry_no, s.user_id, s.place_id, s.weight_cents
                    into e
                    from (select x.entry_no, x.user_id, x.place_id, x.weight_cents,
                                 sum(x.weight_cents) over (order by x.entry_no) as cum
                          from project.ti_bonus_draw_entries x
                          where x.draw_id = p_draw_id
                            and not exists (select 1
                                            from project.ti_bonus_draw_winners w
                                            where w.draw_id = p_draw_id
                                              and w.entry_no = x.entry_no)) s
                    where s.cum >= v_ticket
                    order by s.entry_no
                    limit 1;

                    select p.id, p.amount_usd
                    into pz
                    from project.ti_bonus_draw_prizes p
                    where p.draw_id = p_draw_id
                      and p.state = 1
                    order by p.place_no
                    offset v_round - 1 limit 1;

                    insert into project.ti_bonus_draw_winners (draw_id, prize_id, entry_no, user_id, place_id, amount_usd,
                                                            round_no, random_value, round_total_cents, ticket)
                    values (p_draw_id, pz.id, e.entry_no, e.user_id, e.place_id, pz.amount_usd,
                            v_round, v_value, v_left, v_ticket);
                    v_left := v_left - e.weight_cents;
                end loop;
        end if;

        -- цепочка: каждый проведённый розыгрыш хранит хеш предыдущего
        perform pg_advisory_xact_lock(hashtext('project.ti_bonus_draw_chain'));
        select x.hash
        into v_prev
        from project.ti_bonus_draws x
        where x.status = 'DONE'
        order by x.drawn_at desc, x.id desc
        limit 1;

        update project.ti_bonus_draws x
        set random_response = p_random_response,
            prev_hash       = v_prev,
            drawn_at        = clock_timestamp(),
            updated_at      = now()
        where x.id = p_draw_id;

        update project.ti_bonus_draws x
        set status = 'DONE',
            hash   = encode(sha256(convert_to(project.ti_bonus_draw_payload(p_draw_id), 'UTF8')), 'hex')
        where x.id = p_draw_id;
    elsif d.status <> 'DONE' then
        raise exception 'Розыгрыш % в статусе %: сначала ti_bonus_draw_freeze', p_draw_id, d.status;
    end if;

    return query
        select w.round_no::integer, p.place_no::integer, w.amount_usd, w.entry_no, w.user_id, w.place_id, w.ticket
        from project.ti_bonus_draw_winners w
                 join project.ti_bonus_draw_prizes p on p.id = w.prize_id
        where w.draw_id = p_draw_id
        order by w.round_no;
end;
$$;


-- Отмена до проведения. Если призы уже списаны из фонда — возвращаются.
create function project.ti_bonus_draw_cancel(p_draw_id uuid, p_reason varchar default null)
    returns void
    language plpgsql
as
$$
declare
    d project.ti_bonus_draws%rowtype;
begin
    select * into d from project.ti_bonus_draws where id = p_draw_id for update;
    if not found or d.status = 'CANCELLED' then
        return;
    end if;
    if d.status = 'DONE' then
        raise exception 'Проведённый розыгрыш % отменить нельзя', p_draw_id;
    end if;

    if d.status = 'FROZEN' and d.prize_total_usd > 0 then
        insert into project.ti_bonus_prize_fund_ledger (fund, op_type, amount_usd, draw_id, occurred_at, comment)
        values (d.audience, 'PRIZE_RETURN', d.prize_total_usd, d.id, now(), coalesce(p_reason, 'розыгрыш отменён'));
    end if;

    update project.ti_bonus_draws
    set status     = 'CANCELLED',
        attributes = (coalesce(attributes::jsonb, '{}'::jsonb) || jsonb_build_object('cancel_reason', p_reason))::json,
        updated_at = now()
    where id = p_draw_id;
end;
$$;


-- Проверка цепочки: пересчитать хеши всех проведённых розыгрышей.
-- Всё в порядке — во всех строках три true.
create function project.ti_bonus_draw_chain_check()
    returns table
            (
                draw_id    uuid,
                drawn_at   timestamptz,
                hash_ok    boolean,
                chain_ok   boolean,
                entries_ok boolean
            )
    language sql
    stable
as
$$
select d.id,
       d.drawn_at,
       d.hash = encode(sha256(convert_to(project.ti_bonus_draw_payload(d.id), 'UTF8')), 'hex'),
       d.prev_hash is not distinct from lag(d.hash) over (order by d.drawn_at, d.id),
       d.entries_hash = project.ti_bonus_draw_entries_hash(d.id)
from project.ti_bonus_draws d
where d.status = 'DONE'
order by d.drawn_at, d.id
$$;


-- =====================================================================================
-- 15. Защита от правок задним числом
-- =====================================================================================

create function project.ti_bonus_trg_append_only()
    returns trigger
    language plpgsql
as
$$
begin
    raise exception 'В % строки только добавляются: исправление — новой строкой', tg_table_name;
end;
$$;

create trigger ti_trg_bonus_card_ledger_append_only
    before update or delete
    on project.ti_bonus_card_ledger
    for each row
execute function project.ti_bonus_trg_append_only();

create trigger ti_trg_bonus_prize_fund_ledger_append_only
    before update or delete
    on project.ti_bonus_prize_fund_ledger
    for each row
execute function project.ti_bonus_trg_append_only();

create trigger ti_trg_bonus_draw_entries_append_only
    before update or delete
    on project.ti_bonus_draw_entries
    for each row
execute function project.ti_bonus_trg_append_only();


create function project.ti_bonus_trg_draws_guard()
    returns trigger
    language plpgsql
as
$$
begin
    if old.status = 'DONE' then
        raise exception 'Проведённый розыгрыш не меняют и не удаляют';
    end if;
    if tg_op = 'DELETE' and old.status <> 'DRAFT' then
        raise exception 'Удалить можно только черновик розыгрыша';
    end if;
    return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger ti_trg_bonus_draws_guard
    before update or delete
    on project.ti_bonus_draws
    for each row
execute function project.ti_bonus_trg_draws_guard();


create function project.ti_bonus_trg_prizes_guard()
    returns trigger
    language plpgsql
as
$$
declare
    v_status varchar;
begin
    if tg_op = 'UPDATE' and new.draw_id <> old.draw_id then
        raise exception 'Приз нельзя перенести в другой розыгрыш';
    end if;
    select d.status
    into v_status
    from project.ti_bonus_draws d
    where d.id = case when tg_op = 'DELETE' then old.draw_id else new.draw_id end;
    if v_status is distinct from 'DRAFT' then
        raise exception 'Призы меняются только до фиксации розыгрыша (сейчас %)', v_status;
    end if;
    return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger ti_trg_bonus_draw_prizes_guard
    before insert or update or delete
    on project.ti_bonus_draw_prizes
    for each row
execute function project.ti_bonus_trg_prizes_guard();


create function project.ti_bonus_trg_winners_guard()
    returns trigger
    language plpgsql
as
$$
begin
    if tg_op = 'DELETE' then
        raise exception 'Победителей не удаляют';
    end if;
    if (new.draw_id, new.prize_id, new.entry_no, new.user_id, new.place_id, new.amount_usd, new.round_no,
        new.random_value, new.round_total_cents, new.ticket)
        is distinct from
       (old.draw_id, old.prize_id, old.entry_no, old.user_id, old.place_id, old.amount_usd, old.round_no,
        old.random_value, old.round_total_cents, old.ticket) then
        raise exception 'У победителя меняются только поля выплаты';
    end if;
    return new;
end;
$$;

create trigger ti_trg_bonus_draw_winners_guard
    before update or delete
    on project.ti_bonus_draw_winners
    for each row
execute function project.ti_bonus_trg_winners_guard();


-- =====================================================================================
-- 16. Сверка
-- =====================================================================================

create view project.ti_bonus_card_mismatches as
select c.id,
       c.user_id,
       c.balance_usd,
       coalesce(sum(l.amount_usd), 0)                                                     as ledger_balance_usd,
       c.accrued_usd,
       coalesce(sum(l.amount_usd) filter (where l.op_type in ('ISSUE', 'ACCRUAL')), 0)    as ledger_accrued_usd
from project.ti_bonus_cards c
         left join project.ti_bonus_card_ledger l on l.card_id = c.id
where c.status in ('ACTIVE', 'REVOKED')
group by c.id, c.user_id, c.balance_usd, c.accrued_usd
having c.balance_usd <> coalesce(sum(l.amount_usd), 0)
    or c.accrued_usd <> coalesce(sum(l.amount_usd) filter (where l.op_type in ('ISSUE', 'ACCRUAL')), 0);
comment on view project.ti_bonus_card_mismatches is 'Карты, у которых кеш остатка или начисленного разошёлся с журналом. Должно быть пусто';


-- =====================================================================================
-- Права, если конструктор работает не под ролью project (подставить роль и раскомментировать):
-- grant select, insert, update on project.ti_currency_rates, project.ti_bonus_card_types, project.ti_bonus_cards,
--     project.ti_bonus_discounts, project.ti_bonus_draws, project.ti_bonus_draw_prizes, project.ti_bonus_draw_winners
--     to <роль>;
-- grant select, insert on project.ti_bonus_card_ledger, project.ti_bonus_prize_fund_ledger,
--     project.ti_bonus_draw_entries, project.ti_bonus_place_discount_history, project.ti_bonus_errors to <роль>;
-- grant select on project.ti_bonus_prize_fund_balance, project.ti_bonus_card_mismatches to <роль>;
-- grant execute on all functions in schema project to <роль>;
-- =====================================================================================

commit;
