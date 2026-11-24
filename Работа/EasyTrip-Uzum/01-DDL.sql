-- =====================================================================================
-- EasyTrip: доставка курьерами Uzum Tezkor (Cargo API, совместим с Yandex Delivery v2)
-- База microservice, схема project, PostgreSQL 17.
-- Проверено на PostgreSQL 17.11 с дампом прода от 02.11.2026 и на тестовом стенде Uzum
-- (эмулятор tools/emu.py ходит в настоящий cargo.stable.ufood.uz).
--
-- Запуск:  psql -v ON_ERROR_STOP=1 -d microservice -f 01-DDL.sql   (или DataGrip, весь файл)
--   * Одна транзакция: при любой ошибке не создаётся ничего.
--   * Существующие таблицы не меняются — только новые uzum_*.
--   * Скрипт сам переходит на роль project (set local role), все объекты принадлежат ей.
-- Откат: 02-Откат.sql. Эндпоинты platon: P01-Platon-API-Uzum.sql. Обзор: 00-Обзор.md.
--
-- Как устроено:
--   * Токен Uzum выдаётся на точку (филиал) — таблица uzum_points, одна активная точка на
--     объект или филиал. Токен наружу не отдаётся: его получает только JS-стадия platon.
--   * Операция — пара функций: *_prepare собирает вызовы Uzum (метод, url, тело, токен) в
--     JSON-массив calls, JS-стадия выполняет их и отдаёт ответы по ключам, *_save / *_result
--     разбирают ответы и пишут заявку.
--   * Ошибки Uzum — HTTP 4xx с телом {"code", "message"}. Платформа либо бросает
--     исключение (JS-стадия ловит его и кладёт текст в _error), либо отдаёт тело —
--     uzum_result_error понимает оба варианта.
--   * Источник истины — claims/info. Callback только сообщает, что статус сменился: по нему
--     запрашивается claims/info, поэтому поддельный callback ничего не испортит.
--   * Ключ идемпотентности request_id создаётся до вызова Uzum и хранится в заявке: повтор
--     create (кнопкой или cron) вернёт ту же заявку Uzum, второго курьера не будет.
--   * Время — timestamptz. Деньги — сумы, numeric(15, 2).
-- =====================================================================================

begin;
set local lock_timeout = '5s';
-- владелец всех новых таблиц, вью и функций — роль конструктора project
set local role project;


-- =====================================================================================
-- 1. Таблицы
-- =====================================================================================

create table project.uzum_settings
(
    code  varchar(50) primary key,
    value text,
    note  text not null
);
comment on table project.uzum_settings is 'Uzum Tezkor: адреса контуров и настройки интеграции';

insert into project.uzum_settings (code, value, note)
values ('base_url_test', 'https://cargo.stable.ufood.uz/b2b/cargo/integration',
        'Тестовый контур Uzum Tezkor (реальных курьеров нет)'),
       ('base_url_prod', 'https://cargo.uzumtezkor.uz/b2b/cargo/integration',
        'Боевой контур Uzum Tezkor'),
       ('callback_url', 'https://easy-trip.com/endpoint/api/v1/uzum/callback',
        'Куда Uzum шлёт смену статуса; к адресу добавляется secret заявки. Пусто — заявки без callback'),
       ('js_body_mode', 'string',
        'Как JS-стадия передаёт тело в http.post: string — JSON-текстом, object — объектом. Что работает — показывает GET v1/uzum/diag'),
       ('sync_after_seconds', '120',
        'Через сколько секунд без новостей cron спрашивает claims/info по активной заявке (у черновиков и доставленных — в 5 раз реже)'),
       ('sync_batch', '20', 'Сколько заявок cron проверяет за один запуск');


create table project.uzum_points
(
    id         uuid         default gen_random_uuid() primary key,
    place_id   uuid         not null,                     -- places.id (внешних ключей на places нет, как у merchant)
    branch_id  uuid,                                      -- place_branches.id, если точка — филиал
    env        varchar(4)   default 'test'    not null check (env in ('test', 'prod')),
    token      text         not null,                     -- Bearer-ключ Uzum этой точки; наружу не отдаётся
    name       varchar(255) not null,                     -- контакт на точке забора (видит курьер)
    phone      varchar(20)  not null,                     -- телефон точки забора
    address    varchar(500) not null,                     -- текстовый адрес забора (видит курьер)
    lon        numeric(9, 6) not null,                    -- координаты забора: по ним Uzum определяет город
    lat        numeric(9, 6) not null,
    comment    varchar(500),                              -- комментарий курьеру к точке забора
    taxi_class varchar(10)  default 'courier' not null check (taxi_class in ('courier', 'express')),
    state      smallint     default 1         not null,   -- 1 — работает, 0 — выключена
    note       text,
    created_at timestamptz  default now()     not null,
    updated_at timestamptz  default now()     not null,
    created_by uuid
);
comment on table project.uzum_points is 'Uzum Tezkor: точки забора (объект или филиал) и их токены. Одна активная точка на объект/филиал';
create unique index uzum_points_active_uindex
    on project.uzum_points (place_id, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
    where state = 1;


create table project.uzum_operators
(
    id         uuid        default gen_random_uuid() primary key,
    user_id    uuid        not null,                      -- id пользователя easy-trip (как его видит bearer, GET v1/uzum/me)
    place_id   uuid,                                      -- null — все объекты (администратор доставки)
    note       text,
    created_at timestamptz default now() not null
);
comment on table project.uzum_operators is 'Uzum Tezkor: кто может вызывать и отменять курьера. place_id null — все объекты';
create unique index uzum_operators_uindex
    on project.uzum_operators (user_id, coalesce(place_id, '00000000-0000-0000-0000-000000000000'::uuid));


create table project.uzum_claims
(
    id                  uuid          default gen_random_uuid() primary key, -- наш id доставки (его видит приложение)
    point_id            uuid          not null references project.uzum_points (id),
    place_id            uuid          not null,
    branch_id           uuid,
    env                 varchar(4)    not null,
    request_id          uuid          default gen_random_uuid() not null unique, -- ключ идемпотентности claims/create
    callback_secret     varchar(32)   not null,           -- секрет в callback_url этой заявки
    claim_id            varchar(32) unique,               -- id заявки в Uzum (32 hex), появляется после create
    order_ref           varchar(100),                     -- номер заказа, который прислал клиент
    external_order_id   varchar(100)  not null,           -- номер, который курьер называет на кассе
    status              varchar(40)   default 'new' not null, -- статус Uzum; свои: new — ещё не создана, error — не создалась
    version             integer,
    revision            integer,
    taxi_class          varchar(10)   not null,
    auto_accept         boolean       default false not null,
    price               numeric(15, 2),                   -- стоимость доставки (pricing.final_price)
    currency            varchar(3),
    eta_minutes         integer,                          -- прогноз длительности доставки
    display_id          varchar(50),                      -- номер заказа у Uzum — его называть поддержке
    performer_name      varchar(255),
    performer_transport varchar(50),
    performer_legal     varchar(255),
    sharing_link        varchar(1000),                    -- ссылка отслеживания для покупателя
    cancel_state        varchar(20),                      -- последний ответ cancel-info: free / paid / unavailable
    cancel_price        numeric(15, 2),
    recipient_name      varchar(255)  not null,
    recipient_phone     varchar(20)   not null,
    address             varchar(500)  not null,
    lon                 numeric(9, 6) not null,
    lat                 numeric(9, 6) not null,
    items_total         numeric(15, 2),                   -- Σ цена × количество (справочно: заказ оплачен заранее)
    request             jsonb         not null,           -- тело claims/create, как ушло в Uzum
    response            jsonb,                            -- последняя заявка из Uzum целиком
    uzum_updated_ts     timestamptz,                      -- updated_ts последней применённой заявки
    error_code          varchar(100),                     -- последняя ошибка (сбрасывается следующей удачной операцией)
    error_message       text,
    create_attempts     integer       default 0 not null,
    created_by          uuid,
    created_at          timestamptz   default now() not null,
    updated_at          timestamptz   default now() not null,
    status_changed_at   timestamptz   default now() not null,
    accepted_at         timestamptz,
    picked_up_at        timestamptz,
    delivered_at        timestamptz,
    finished_at         timestamptz,                      -- финальный статус: дальше заявка не меняется
    last_info_at        timestamptz,                      -- последний удачный claims/info
    last_callback_at    timestamptz,
    sync_at             timestamptz                       -- последняя попытка cron
);
comment on table project.uzum_claims is 'Uzum Tezkor: доставки (одна строка — одна заявка Uzum)';
create index uzum_claims_place_index on project.uzum_claims (place_id, created_at desc);
create index uzum_claims_active_index on project.uzum_claims (sync_at) where finished_at is null;
-- один активный курьер на заказ: повтор с тем же order_ref вернёт ту же доставку
create unique index uzum_claims_order_ref_uindex on project.uzum_claims (place_id, order_ref)
    where order_ref is not null and finished_at is null;


create table project.uzum_claim_events
(
    id         bigint generated always as identity primary key,
    claim_row  uuid,                                      -- uzum_claims.id; null — callback по неизвестной заявке
    claim_id   varchar(64),
    source     varchar(20) not null,                      -- create, accept, info, cancel, callback, sync
    status     varchar(40),
    old_status varchar(40),
    updated_ts varchar(40),                               -- callback: как прислал Uzum
    secret_ok  boolean,                                   -- callback: секрет совпал; null — секрета в запросе не было
    note       text,
    created_at timestamptz default now() not null
);
comment on table project.uzum_claim_events is 'Uzum Tezkor: смены статуса, ошибки и входящие callback-и';
create index uzum_claim_events_row_index on project.uzum_claim_events (claim_row, id);
-- повтор одного и того же callback-а отбрасывается
create unique index uzum_claim_events_callback_uindex on project.uzum_claim_events (claim_id, status, updated_ts)
    where source = 'callback';


-- =====================================================================================
-- 2. Справочные функции
-- =====================================================================================

create function project.uzum_setting(p_code varchar) returns text
    language sql
    stable as
$$
select s.value
from project.uzum_settings s
where s.code = p_code
$$;

create function project.uzum_base_url(p_env varchar) returns text
    language sql
    stable as
$$
select project.uzum_setting(case when p_env = 'prod' then 'base_url_prod' else 'base_url_test' end)
$$;

-- безопасные приведения: мусор → null, а не ошибка всей стадии
create function project.uzum_num(p text) returns numeric
    language plpgsql
    immutable as
$$
begin
    return nullif(btrim(p), '')::numeric;
exception
    when others then return null;
end
$$;

create function project.uzum_int(p text) returns integer
    language sql
    immutable as
$$
select round(project.uzum_num(p))::integer
$$;

create function project.uzum_uuid(p text) returns uuid
    language plpgsql
    immutable as
$$
begin
    return nullif(btrim(p), '')::uuid;
exception
    when others then return null;
end
$$;

create function project.uzum_ts(p text) returns timestamptz
    language plpgsql
    stable as
$$
begin
    return nullif(btrim(p), '')::timestamptz;
exception
    when others then return null;
end
$$;

-- ответ JS-стадии (JSON-текст) → jsonb; если платформа подставила что-то не то — _bad_result
create function project.uzum_parse(p text) returns jsonb
    language plpgsql
    immutable as
$$
begin
    return coalesce(nullif(btrim(p), '')::jsonb, '{}'::jsonb);
exception
    when others then return jsonb_build_object('_bad_result', left(p, 1000));
end
$$;

-- телефон: 9 цифр → +998…, 998 и ещё 9 цифр → +998…, остальное как есть
create function project.uzum_phone(p text) returns varchar
    language sql
    immutable as
$$
select case
           when nullif(btrim(p), '') is null then null
           when length(regexp_replace(p, '[^0-9]', '', 'g')) = 9
               then '+998' || regexp_replace(p, '[^0-9]', '', 'g')
           when length(regexp_replace(p, '[^0-9]', '', 'g')) = 12 and regexp_replace(p, '[^0-9]', '', 'g') like '998%'
               then '+' || regexp_replace(p, '[^0-9]', '', 'g')
           else btrim(p)
           end::varchar
$$;

-- деньги для cost_value: строка без хвостов плавающей точки — «89000» или «89000.50»
create function project.uzum_money(p numeric) returns text
    language sql
    immutable as
$$
select case
           when p is null then '0'
           when round(p, 2) = trunc(p) then trunc(p)::bigint::text
           else round(p, 2)::text
           end
$$;

create function project.uzum_is_final(p_status varchar) returns boolean
    language sql
    immutable as
$$
select coalesce(p_status in ('delivered_finish', 'cancelled', 'cancelled_with_payment',
                             'cancelled_with_items_on_hands', 'failed', 'error'), false)
$$;

-- порядок статусов основного пути; у финальных отмен и ошибок — null
create function project.uzum_status_rank(p_status varchar) returns integer
    language sql
    immutable as
$$
select case p_status
           when 'new' then 0
           when 'ready_for_approval' then 1
           when 'accepted' then 2
           when 'performer_lookup' then 3
           when 'performer_draft' then 4
           when 'performer_found' then 5
           when 'pickup_arrived' then 6
           when 'pickuped' then 7
           when 'delivery_arrived' then 8
           when 'delivered' then 9
           when 'delivered_finish' then 10
           end
$$;

-- крупный этап для приложения
create function project.uzum_stage(p_status varchar) returns varchar
    language sql
    immutable as
$$
select case
           when p_status = 'new' then 'creating'
           when p_status = 'ready_for_approval' then 'draft'
           when p_status in ('accepted', 'performer_lookup', 'performer_draft') then 'searching'
           when p_status in ('performer_found', 'pickup_arrived') then 'to_pickup'
           when p_status in ('pickuped', 'delivery_arrived') then 'delivering'
           when p_status in ('delivered', 'delivered_finish') then 'delivered'
           when p_status like 'cancelled%' then 'cancelled'
           when p_status in ('failed', 'error') then 'failed'
           else 'unknown'
           end::varchar
$$;

create function project.uzum_is_operator(p_user uuid, p_place uuid) returns boolean
    language sql
    stable as
$$
select p_user is not null
           and exists(select 1
                      from project.uzum_operators o
                      where o.user_id = p_user
                        and (o.place_id is null or o.place_id = p_place))
$$;

create function project.uzum_is_admin(p_user uuid) returns boolean
    language sql
    stable as
$$
select p_user is not null
           and exists(select 1 from project.uzum_operators o where o.user_id = p_user and o.place_id is null)
$$;

-- ошибка в ответе Uzum или null, если ответ удачный.
-- Понимает оба поведения платформы: исключение (текст в _error) и тело ошибки как ответ.
create function project.uzum_result_error(r jsonb) returns jsonb
    language sql
    immutable as
$$
select case
           when r is null or jsonb_typeof(r) <> 'object' then
               jsonb_build_object('code', 'no_response', 'message', 'Uzum не ответил', 'http', null)
           when r ? '_error' then
               jsonb_build_object(
                       'code', coalesce(substring(r ->> '_error' from 'code\W{1,6}([a-z][a-z0-9_.]*)'),
                                        case when r ->> '_error' ~ '\m40[13]\M' then 'unauthorized' end,
                                        case when r ->> '_error' ~ '\m404\M' then 'not_found' end,
                                        'http_error'),
                       'message', coalesce(substring(r ->> '_error' from 'message\W{1,6}([^"\\]{1,250})'),
                                           left(r ->> '_error', 500)),
                       'http', substring(r ->> '_error' from '\m([45][0-9][0-9])\M'))
           when r ? 'message' and (r ? 'code' or r ? 'status')
               and not r ?| array ['id', 'offers', 'cancel_state', 'position', 'phone'] then
               jsonb_build_object(
                       'code', case
                                   when r ->> 'code' ~ '^[a-z][a-z0-9_.]*$' then r ->> 'code'
                                   when coalesce(r ->> 'status', r ->> 'code') in ('401', '403') then 'unauthorized'
                                   else 'http_' || coalesce(r ->> 'status', r ->> 'code')
                                   end,
                       'message', r ->> 'message',
                       'http', coalesce(r ->> 'status', case when r ->> 'code' ~ '^[0-9]+$' then r ->> 'code' end))
           end
$$;

-- временная ли ошибка create (тогда cron повторит тем же request_id)
create function project.uzum_is_transient(err jsonb) returns boolean
    language sql
    immutable as
$$
select coalesce(err ->> 'code', '') in ('http_error', 'no_response', 'platform_result')
           or coalesce(err ->> 'http', '') like '5%'
           or (err ->> 'code' = 'unknown_error' and coalesce(err ->> 'message', '') not ilike '%schedule%')
$$;

create function project.uzum_check_coords(p_lon numeric, p_lat numeric) returns void
    language plpgsql
    immutable as
$$
begin
    if p_lon is null or p_lat is null or p_lon = 0 or p_lat = 0 then
        raise exception 'uzum_bad_request: нужны координаты доставки lon и lat';
    end if;
    if p_lon not between 55 and 74 or p_lat not between 37 and 46 then
        raise exception 'uzum_bad_request: координаты (lon %, lat %) вне Узбекистана — проверьте порядок: lon — долгота (около 69), lat — широта (около 41)',
            p_lon, p_lat;
    end if;
end
$$;

create function project.uzum_taxi_class(p_class varchar, p_default varchar) returns varchar
    language plpgsql
    immutable as
$$
declare
    v varchar := coalesce(nullif(btrim(p_class), ''), p_default, 'courier');
begin
    if v not in ('courier', 'express') then
        raise exception 'uzum_bad_request: taxi_class — courier (любой курьер) или express (на машине), а не %', v;
    end if;
    return v;
end
$$;

-- активная точка объекта (или филиала)
create function project.uzum_point_pick(p_place uuid, p_branch uuid) returns project.uzum_points
    language plpgsql
    stable as
$$
declare
    pt project.uzum_points;
    n  integer;
begin
    if p_place is null then
        raise exception 'uzum_bad_request: нужен place_id';
    end if;
    if p_branch is not null then
        select * into pt from project.uzum_points p where p.state = 1 and p.place_id = p_place and p.branch_id = p_branch;
    else
        select count(*) into n from project.uzum_points p where p.state = 1 and p.place_id = p_place;
        if n > 1 then
            select * into pt from project.uzum_points p where p.state = 1 and p.place_id = p_place and p.branch_id is null;
            if not found then
                raise exception 'uzum_branch_required: у объекта % несколько точек Uzum — укажите branch_id', p_place;
            end if;
            return pt;
        end if;
        select * into pt from project.uzum_points p where p.state = 1 and p.place_id = p_place;
    end if;
    if not found then
        raise exception 'uzum_no_point: объект % не подключён к доставке Uzum', p_place;
    end if;
    return pt;
end
$$;

-- заявка с проверкой доступа: управлять — оператор объекта; смотреть — ещё и тот, кто создал
create function project.uzum_claim_for(p_user uuid, p_id uuid, p_manage boolean) returns project.uzum_claims
    language plpgsql
    stable as
$$
declare
    r project.uzum_claims;
begin
    if p_id is null then
        raise exception 'uzum_bad_request: нужен id доставки';
    end if;
    select * into r from project.uzum_claims c where c.id = p_id;
    if not found then
        raise exception 'uzum_not_found: доставка % не найдена', p_id;
    end if;
    if not (project.uzum_is_operator(p_user, r.place_id)
        or (not p_manage and p_user is not null and r.created_by = p_user)) then
        raise exception 'uzum_no_access: нет доступа к доставке % (пользователь %)', p_id, p_user;
    end if;
    return r;
end
$$;

-- один вызов Uzum для JS-стадии
create function project.uzum_call(p_key text, p_point project.uzum_points, p_method text, p_path text, p_body jsonb)
    returns jsonb
    language plpgsql
    stable as
$$
begin
    return jsonb_build_object(
            'key', p_key,
            'method', p_method,
            'url', project.uzum_base_url(p_point.env) || p_path,
            'token', p_point.token,
            'body', p_body::text,
            'body_mode', coalesce(nullif(project.uzum_setting('js_body_mode'), ''), 'string'));
end
$$;


-- =====================================================================================
-- 3. Вью для ответов (без токенов, секретов и сырых тел)
-- =====================================================================================

create view project.uzum_claims_v as
select c.id,
       c.claim_id,
       c.display_id,
       c.place_id,
       c.branch_id,
       c.point_id,
       c.env,
       c.order_ref,
       c.external_order_id,
       c.status,
       project.uzum_stage(c.status)           as stage,
       c.finished_at is not null              as is_final,
       c.taxi_class,
       c.price,
       c.currency,
       c.eta_minutes,
       c.performer_name,
       c.performer_transport,
       c.sharing_link,
       c.cancel_state,
       c.cancel_price,
       c.recipient_name,
       c.recipient_phone,
       c.address,
       c.lon,
       c.lat,
       c.items_total,
       c.error_code is null                   as ok,
       c.error_code,
       c.error_message,
       c.created_by,
       c.created_at,
       c.updated_at,
       c.status_changed_at,
       c.accepted_at,
       c.picked_up_at,
       c.delivered_at,
       c.finished_at
from project.uzum_claims c;


-- =====================================================================================
-- 4. Применение ответов Uzum к заявке
-- =====================================================================================

create function project.uzum_note_error(p_id uuid, p_source varchar, err jsonb) returns void
    language sql as
$$
update project.uzum_claims c
set error_code    = left(err ->> 'code', 100),
    error_message = left(err ->> 'message', 1000),
    updated_at    = now()
where c.id = p_id;
insert into project.uzum_claim_events (claim_row, claim_id, source, note)
select c.id, c.claim_id, p_source, left('error ' || err::text, 1000)
from project.uzum_claims c
where c.id = p_id;
$$;

-- заявка Uzum (полная — из create/info, или короткий ответ accept/cancel) → наша строка
create function project.uzum_apply(p_id uuid, c jsonb, p_source varchar) returns void
    language plpgsql as
$$
declare
    r        project.uzum_claims;
    v_status varchar;
    v_ts     timestamptz;
    v_rank   integer;
    v_full   boolean := c ? 'route_points';
begin
    select * into r from project.uzum_claims x where x.id = p_id for update;
    if not found then
        return;
    end if;
    v_status := coalesce(nullif(c ->> 'status', ''), r.status);
    if v_status = 'ready_for_approval' and r.accepted_at is not null then
        v_status := 'accepted';   -- accept прошёл, а Uzum ещё показывает черновик
    end if;
    if project.uzum_is_final(r.status) and not project.uzum_is_final(v_status) then
        v_status := r.status;     -- из финального статуса назад не возвращаемся
    end if;
    v_ts := project.uzum_ts(c ->> 'updated_ts');
    if v_full and v_ts is not null and r.uzum_updated_ts is not null and v_ts < r.uzum_updated_ts then
        return;                   -- ответ устарел: уже применён более новый
    end if;
    v_rank := project.uzum_status_rank(v_status);

    update project.uzum_claims x
    set claim_id            = coalesce(x.claim_id, c ->> 'id'),
        status              = v_status,
        version             = coalesce(project.uzum_int(c ->> 'version'), x.version),
        revision            = coalesce(project.uzum_int(c ->> 'revision'), x.revision),
        price               = coalesce(project.uzum_num(c -> 'pricing' ->> 'final_price'), x.price),
        currency            = coalesce(c -> 'pricing' ->> 'currency', x.currency),
        eta_minutes         = coalesce(project.uzum_int(c ->> 'eta'), x.eta_minutes),
        display_id          = coalesce(c ->> 'display_id', x.display_id),
        performer_name      = coalesce(c -> 'performer_info' ->> 'courier_name', x.performer_name),
        performer_transport = coalesce(c -> 'performer_info' ->> 'transport_type', x.performer_transport),
        performer_legal     = coalesce(c -> 'performer_info' ->> 'legal_name', x.performer_legal),
        response            = case when v_full then c else x.response end,
        uzum_updated_ts     = coalesce(v_ts, x.uzum_updated_ts),
        status_changed_at   = case when v_status is distinct from x.status then now() else x.status_changed_at end,
        accepted_at         = case when x.accepted_at is null and v_rank between 2 and 10 then now() else x.accepted_at end,
        picked_up_at        = case when x.picked_up_at is null and v_rank between 7 and 10 then now() else x.picked_up_at end,
        delivered_at        = case when x.delivered_at is null and v_rank between 9 and 10 then now() else x.delivered_at end,
        finished_at         = case when x.finished_at is null and project.uzum_is_final(v_status) then now() else x.finished_at end,
        error_code          = null,
        error_message       = null,
        updated_at          = now()
    where x.id = p_id;

    if v_status is distinct from r.status then
        insert into project.uzum_claim_events (claim_row, claim_id, source, status, old_status)
        values (p_id, coalesce(r.claim_id, c ->> 'id'), p_source, v_status, r.status);
    end if;
end
$$;

-- ответы JS-стадии по ключам create / accept / info / cancel → заявка
create function project.uzum_apply_results(p_id uuid, res jsonb, p_source varchar) returns void
    language plpgsql as
$$
declare
    x   jsonb;
    err jsonb;
begin
    if res ? '_bad_result' then
        perform project.uzum_note_error(p_id, p_source,
                                        jsonb_build_object('code', 'platform_result', 'message', res ->> '_bad_result'));
        return;
    end if;

    if res ? 'create' then
        x := res -> 'create';
        err := project.uzum_result_error(x);
        update project.uzum_claims c
        set create_attempts = c.create_attempts + 1,
            sync_at         = now()
        where c.id = p_id;
        if err is null then
            perform project.uzum_apply(p_id, x, 'create');
            update project.uzum_claims c set last_info_at = now() where c.id = p_id;
        else
            perform project.uzum_note_error(p_id, 'create', err);
            if not project.uzum_is_transient(err) then
                update project.uzum_claims c
                set status            = 'error',
                    finished_at       = now(),
                    status_changed_at = now()
                where c.id = p_id
                  and c.status = 'new';
                if found then
                    insert into project.uzum_claim_events (claim_row, source, status, old_status, note)
                    values (p_id, 'create', 'error', 'new', err ->> 'code');
                end if;
            end if;
        end if;
    end if;

    if res ? 'accept' then
        x := res -> 'accept';
        err := project.uzum_result_error(x);
        if err is null then
            update project.uzum_claims c
            set accepted_at = coalesce(c.accepted_at, now()),
                display_id  = coalesce(x ->> 'display_id', c.display_id)
            where c.id = p_id;
            perform project.uzum_apply(p_id, x, 'accept');
        else
            perform project.uzum_note_error(p_id, 'accept', err);
        end if;
    end if;

    if res ? 'info' then
        x := res -> 'info';
        err := project.uzum_result_error(x);
        if err is null then
            perform project.uzum_apply(p_id, x, p_source);
            update project.uzum_claims c set last_info_at = now() where c.id = p_id;
        else
            perform project.uzum_note_error(p_id, p_source, err);
        end if;
    end if;

    if res ? 'cancel' then
        x := res -> 'cancel';
        err := project.uzum_result_error(x);
        if err is null then
            perform project.uzum_apply(p_id, x, 'cancel');
        else
            perform project.uzum_note_error(p_id, 'cancel', err);
        end if;
    end if;
end
$$;


-- =====================================================================================
-- 5. Операции (вызываются стадиями platon, см. P01-Platon-API-Uzum.sql)
-- =====================================================================================

-- 5.1 Цена доставки до адреса: POST v1/uzum/calculate. Ничего не создаёт.
create function project.uzum_calc_prepare(p_user uuid, p_place uuid, p_branch uuid, p_lon numeric, p_lat numeric,
                                          p_address varchar, p_taxi_class varchar, p_weight numeric)
    returns table
            (
                calls      text,
                point_id   uuid,
                taxi_class varchar
            )
    language plpgsql
    stable as
$$
declare
    pt      project.uzum_points;
    v_class varchar;
    v_body  jsonb;
begin
    if p_user is null then
        raise exception 'uzum_no_access: нужен вход в easy-trip';
    end if;
    pt := project.uzum_point_pick(p_place, p_branch);
    perform project.uzum_check_coords(p_lon, p_lat);
    v_class := project.uzum_taxi_class(p_taxi_class, pt.taxi_class);
    v_body := jsonb_build_object(
            'selected_taxi_class', v_class,
            'items', jsonb_build_array(jsonb_build_object('quantity', 1, 'weight', coalesce(nullif(p_weight, 0), 1),
                                                          'pickup_point', 1, 'dropoff_point', 2)),
            'route_points', jsonb_build_array(
                    jsonb_build_object('id', 1, 'coordinates', jsonb_build_array(pt.lon, pt.lat), 'fullname', pt.address),
                    jsonb_build_object('id', 2, 'coordinates', jsonb_build_array(p_lon, p_lat),
                                       'fullname', coalesce(nullif(btrim(p_address), ''), 'Адрес доставки'))));
    return query select jsonb_build_array(project.uzum_call('calc', pt, 'POST', '/v2/offers/calculate', v_body))::text,
                        pt.id,
                        v_class;
end
$$;

create function project.uzum_calc_result(p_result text, p_taxi_class varchar)
    returns table
            (
                ok            boolean,
                price         numeric,
                currency      varchar,
                taxi_class    varchar,
                pickup_from   timestamptz,
                pickup_to     timestamptz,
                delivery_from timestamptz,
                delivery_to   timestamptz,
                error_code    varchar,
                error_message text
            )
    language plpgsql
    stable as
$$
declare
    res jsonb := project.uzum_parse(p_result);
    x   jsonb := res -> 'calc';
    err jsonb;
    o   jsonb;
begin
    err := case
               when res ? '_bad_result' then jsonb_build_object('code', 'platform_result', 'message', res ->> '_bad_result')
               else project.uzum_result_error(x) end;
    if err is null then
        select e into o from jsonb_array_elements(x -> 'offers') e where e ->> 'taxi_class' = p_taxi_class limit 1;
        o := coalesce(o, x -> 'offers' -> 0);
        if o is null then
            err := jsonb_build_object('code', 'no_offers', 'message', 'Uzum не вернул цену');
        end if;
    end if;
    if err is not null then
        return query select false, null::numeric, null::varchar, p_taxi_class, null::timestamptz, null::timestamptz,
                            null::timestamptz, null::timestamptz, (err ->> 'code')::varchar, (err ->> 'message')::text;
        return;
    end if;
    return query select true,
                        project.uzum_num(o -> 'price' ->> 'total_price'),
                        (o -> 'price' ->> 'currency')::varchar,
                        (o ->> 'taxi_class')::varchar,
                        project.uzum_ts(o -> 'pickup_interval' ->> 'from'),
                        project.uzum_ts(o -> 'pickup_interval' ->> 'to'),
                        project.uzum_ts(o -> 'delivery_interval' ->> 'from'),
                        project.uzum_ts(o -> 'delivery_interval' ->> 'to'),
                        null::varchar,
                        null::text;
end
$$;


-- 5.2 Вызвать курьера: POST v1/uzum/claim/create. Строка заявки пишется ДО вызова Uzum —
--     с request_id, поэтому сбой связи не потеряет заявку и не создаст вторую.
create function project.uzum_create_prepare(p_user uuid, p_place uuid, p_branch uuid, p_order_ref varchar,
                                            p_recipient_name varchar, p_recipient_phone varchar,
                                            p_address varchar, p_lon numeric, p_lat numeric,
                                            p_porch varchar, p_sfloor varchar, p_sflat varchar,
                                            p_door_code varchar, p_address_comment varchar,
                                            p_comment varchar, p_items text, p_taxi_class varchar,
                                            p_optional_return boolean, p_auto_accept boolean)
    returns table
            (
                id    uuid,
                calls text
            )
    language plpgsql as
$$
declare
    pt        project.uzum_points;
    ex        project.uzum_claims;
    v_id      uuid    := gen_random_uuid();
    v_req     uuid    := gen_random_uuid();
    v_secret  varchar := replace(gen_random_uuid()::text, '-', '');
    v_ref     varchar := nullif(btrim(p_order_ref), '');
    v_shown   varchar;
    v_phone   varchar := project.uzum_phone(p_recipient_phone);
    v_class   varchar;
    v_items   jsonb;
    v_uz      jsonb;
    v_total   numeric;
    v_bad     boolean;
    v_cb      text    := nullif(btrim(project.uzum_setting('callback_url')), '');
    v_body    jsonb;
begin
    pt := project.uzum_point_pick(p_place, p_branch);
    if not project.uzum_is_operator(p_user, pt.place_id) then
        raise exception 'uzum_no_access: вызывать курьера для объекта % может только оператор (пользователь %)',
            pt.place_id, p_user;
    end if;
    if nullif(btrim(p_recipient_name), '') is null then
        raise exception 'uzum_bad_request: нужно имя получателя (recipient_name)';
    end if;
    if v_phone is null or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 9 then
        raise exception 'uzum_bad_request: нужен телефон получателя (recipient_phone), например +998901234567';
    end if;
    if nullif(btrim(p_address), '') is null then
        raise exception 'uzum_bad_request: нужен адрес доставки (address) — его видит курьер';
    end if;
    perform project.uzum_check_coords(p_lon, p_lat);
    v_class := project.uzum_taxi_class(p_taxi_class, pt.taxi_class);

    -- повтор по тому же заказу: та же доставка, второго курьера не будет
    if v_ref is not null then
        select * into ex from project.uzum_claims c
        where c.place_id = pt.place_id and c.order_ref = v_ref and c.finished_at is null;
        if found then
            if ex.recipient_phone is distinct from v_phone
                or round(ex.lon, 5) <> round(p_lon, 5) or round(ex.lat, 5) <> round(p_lat, 5) then
                raise exception 'uzum_order_busy: по заказу % уже есть доставка % (статус %) на другой адрес — отмените её или укажите другой order_ref',
                    v_ref, ex.id, ex.status;
            end if;
            select * into pt from project.uzum_points p where p.id = ex.point_id;
            return query select ex.id,
                                case
                                    when ex.claim_id is null then jsonb_build_array(
                                            project.uzum_call('create', pt, 'POST',
                                                              '/v2/claims/create?request_id=' || ex.request_id, ex.request))
                                    else '[]'::jsonb end::text;
            return;
        end if;
    end if;

    -- позиции: [{"title", "quantity", "price" (за единицу), "weight" (кг за единицу)}]
    begin
        v_items := coalesce(nullif(btrim(p_items), '')::jsonb, '[]'::jsonb);
        if jsonb_typeof(v_items) <> 'array' then
            raise exception 'не массив';
        end if;
        select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                     'title', left(coalesce(nullif(btrim(s.i ->> 'title'), ''), 'Позиция ' || s.n), 255),
                                     'quantity', s.q,
                                     'cost_value', project.uzum_money(s.pr),
                                     'cost_currency', 'UZS',
                                     -- Uzum складывает weight позиций без умножения на quantity
                                     'weight', case when s.w > 0 then round(s.w * s.q, 3) end,
                                     'pickup_point', 1,
                                     'dropoff_point', 2)) order by s.n), '[]'::jsonb),
               sum(s.pr * s.q),
               bool_or(s.q < 1 or s.pr < 0)
        into v_uz, v_total, v_bad
        from (select t.i, t.n,
                     coalesce((t.i ->> 'quantity')::numeric, 1)::integer as q,
                     coalesce((t.i ->> 'price')::numeric, 0)             as pr,
                     (t.i ->> 'weight')::numeric                         as w
              from jsonb_array_elements(v_items) with ordinality as t(i, n)) s;
    exception
        when others then
            raise exception 'uzum_bad_request: items — массив позиций [{"title", "quantity", "price", "weight"}]: %', sqlerrm;
    end;
    if v_bad then
        raise exception 'uzum_bad_request: в items quantity — от 1, price — не меньше 0';
    end if;

    v_shown := coalesce(v_ref, 'ET-' || upper(left(replace(v_id::text, '-', ''), 6)));
    if jsonb_array_length(v_uz) = 0 then
        v_uz := jsonb_build_array(jsonb_build_object('title', 'Заказ ' || v_shown, 'quantity', 1, 'cost_value', '0',
                                                     'cost_currency', 'UZS', 'pickup_point', 1, 'dropoff_point', 2));
    end if;

    v_body := jsonb_strip_nulls(jsonb_build_object(
            'client_requirements', jsonb_build_object('taxi_class', v_class),
            'callback_properties', case
                                       when v_cb is not null then jsonb_build_object(
                                               'callback_url', v_cb || case when v_cb like '%?%' then '&' else '?' end
                                                                   || 'secret=' || v_secret) end,
            'auto_accept', case when p_auto_accept then true end,
            'optional_return', case when p_optional_return then true end,
            'comment', nullif(btrim(p_comment), ''),
            'items', v_uz,
            'route_points', jsonb_build_array(
                    jsonb_build_object(
                            'point_id', 1, 'type', 'source', 'visit_order', 1,
                            'contact', jsonb_build_object('name', pt.name, 'phone', pt.phone),
                            'address', jsonb_build_object('fullname', pt.address,
                                                          'coordinates', jsonb_build_array(pt.lon, pt.lat),
                                                          'comment', pt.comment)),
                    jsonb_build_object(
                            'point_id', 2, 'type', 'destination', 'visit_order', 2,
                            'external_order_id', v_shown,
                            'contact', jsonb_build_object('name', btrim(p_recipient_name), 'phone', v_phone),
                            'address', jsonb_build_object('fullname', btrim(p_address),
                                                          'coordinates', jsonb_build_array(p_lon, p_lat),
                                                          'porch', nullif(btrim(p_porch), ''),
                                                          'sfloor', nullif(btrim(p_sfloor), ''),
                                                          'sflat', nullif(btrim(p_sflat), ''),
                                                          'door_code', nullif(btrim(p_door_code), ''),
                                                          'comment', nullif(btrim(p_address_comment), ''))))));

    insert into project.uzum_claims (id, point_id, place_id, branch_id, env, request_id, callback_secret, order_ref,
                                     external_order_id, status, taxi_class, auto_accept, recipient_name,
                                     recipient_phone, address, lon, lat, items_total, request, created_by)
    values (v_id, pt.id, pt.place_id, pt.branch_id, pt.env, v_req, v_secret, v_ref, v_shown, 'new', v_class,
            coalesce(p_auto_accept, false), btrim(p_recipient_name), v_phone, btrim(p_address), p_lon, p_lat,
            v_total, v_body, p_user);
    insert into project.uzum_claim_events (claim_row, source, status)
    values (v_id, 'create', 'new');

    return query select v_id,
                        jsonb_build_array(project.uzum_call('create', pt, 'POST',
                                                            '/v2/claims/create?request_id=' || v_req, v_body))::text;
end
$$;


-- 5.3 Вызовы по существующей заявке: accept, info, cancel_info, courier
create function project.uzum_op_prepare(p_user uuid, p_id uuid, p_op varchar)
    returns table
            (
                id    uuid,
                calls text
            )
    language plpgsql
    stable as
$$
declare
    r      project.uzum_claims;
    pt     project.uzum_points;
    v      jsonb := '[]'::jsonb;
    v_rank integer;
begin
    if p_op not in ('accept', 'info', 'cancel_info', 'courier') then
        raise exception 'uzum_bad_request: неизвестная операция %', p_op;
    end if;
    r := project.uzum_claim_for(p_user, p_id, p_op in ('accept', 'cancel_info'));
    select * into pt from project.uzum_points p where p.id = r.point_id;

    if r.claim_id is null then
        -- в Uzum заявки ещё нет: info повторяет create тем же request_id, остальное — ошибка
        if p_op = 'info' and r.status = 'new' then
            v := jsonb_build_array(project.uzum_call('create', pt, 'POST',
                                                     '/v2/claims/create?request_id=' || r.request_id, r.request));
        elsif p_op <> 'info' then
            raise exception 'uzum_inappropriate_status: доставка % ещё не создана в Uzum (статус %)', r.id, r.status;
        end if;
        return query select r.id, v::text;
        return;
    end if;

    if p_op = 'accept' then
        if r.status <> 'ready_for_approval' or r.accepted_at is not null then
            raise exception 'uzum_inappropriate_status: подтвердить можно только черновик (ready_for_approval), сейчас %',
                r.status;
        end if;
        v := jsonb_build_array(project.uzum_call('accept', pt, 'POST', '/v2/claims/accept?claim_id=' || r.claim_id,
                                                 jsonb_build_object('version', coalesce(r.version, 1))));
    elsif p_op = 'info' then
        v := jsonb_build_array(project.uzum_call('info', pt, 'POST', '/v2/claims/info?claim_id=' || r.claim_id, null));
    elsif p_op = 'cancel_info' then
        if r.finished_at is not null then
            raise exception 'uzum_inappropriate_status: доставка % уже завершена (статус %)', r.id, r.status;
        end if;
        v := jsonb_build_array(project.uzum_call('cancel_info', pt, 'POST',
                                                 '/v2/claims/cancel-info?claim_id=' || r.claim_id, null));
    else
        -- courier: свежий статус + координаты и телефон, если курьер уже есть
        v := jsonb_build_array(project.uzum_call('info', pt, 'POST', '/v2/claims/info?claim_id=' || r.claim_id, null));
        v_rank := project.uzum_status_rank(r.status);
        if v_rank between 2 and 8 then
            v := v || project.uzum_call('position', pt, 'GET',
                                        '/v2/claims/performer-position?claim_id=' || r.claim_id, null);
        end if;
        if v_rank between 2 and 9 then
            v := v || project.uzum_call('phone', pt, 'POST', '/v2/driver-voiceforwarding',
                                        jsonb_build_object('claim_id', r.claim_id));
        end if;
    end if;
    return query select r.id, v::text;
end
$$;

-- ответ по заявке — строка uzum_claims_v
create function project.uzum_save(p_user uuid, p_id uuid, p_op varchar, p_result text)
    returns setof project.uzum_claims_v
    language plpgsql as
$$
begin
    if p_id is null then
        raise exception 'uzum_bad_request: нет id доставки';
    end if;
    perform project.uzum_apply_results(p_id, project.uzum_parse(p_result), p_op);
    return query select * from project.uzum_claims_v v where v.id = p_id;
end
$$;


-- 5.4 Отмена: POST v1/uzum/claim/cancel. Сначала cancel-info; платную отмену — только с allow_paid
create function project.uzum_cancel_decide(p_user uuid, p_id uuid, p_result text, p_allow_paid boolean)
    returns table
            (
                id    uuid,
                calls text
            )
    language plpgsql as
$$
declare
    r    project.uzum_claims;
    pt   project.uzum_points;
    res  jsonb := project.uzum_parse(p_result);
    x    jsonb := res -> 'cancel_info';
    err  jsonb;
    v_st varchar;
begin
    r := project.uzum_claim_for(p_user, p_id, true);
    err := case
               when res ? '_bad_result' then jsonb_build_object('code', 'platform_result', 'message', res ->> '_bad_result')
               else project.uzum_result_error(x) end;
    if err is not null then
        perform project.uzum_note_error(r.id, 'cancel', err);
        return query select r.id, '[]'::text;
        return;
    end if;

    v_st := x ->> 'cancel_state';
    update project.uzum_claims c
    set cancel_state = v_st,
        cancel_price = project.uzum_num(x ->> 'price'),
        updated_at   = now()
    where c.id = r.id;

    if v_st = 'free' or (v_st = 'paid' and coalesce(p_allow_paid, false)) then
        select * into pt from project.uzum_points p where p.id = r.point_id;
        return query select r.id,
                            jsonb_build_array(project.uzum_call('cancel', pt, 'POST',
                                                                '/v2/claims/cancel?claim_id=' || r.claim_id,
                                                                jsonb_build_object('cancel_state', v_st,
                                                                                   'version', coalesce(r.version, 1))))::text;
        return;
    end if;

    perform project.uzum_note_error(r.id, 'cancel', jsonb_build_object(
            'code', case when v_st = 'paid' then 'paid_cancel_not_confirmed' else 'cancel_unavailable' end,
            'message', case
                           when v_st = 'paid' then 'Курьер уже забрал заказ: отмена платная, ' || coalesce(x ->> 'price', '?')
                                                       || ' сум. Чтобы отменить, повторите с allow_paid = true'
                           else 'Отменить уже нельзя (cancel_state ' || coalesce(v_st, '?') || ')' end));
    return query select r.id, '[]'::text;
end
$$;


-- 5.5 Курьер: GET v1/uzum/claim/courier — имя, телефон, координаты, ссылка отслеживания
create function project.uzum_courier_save(p_user uuid, p_id uuid, p_result text)
    returns table
            (
                id                  uuid,
                status              varchar,
                stage               varchar,
                performer_name      varchar,
                performer_transport varchar,
                phone               varchar,
                lat                 numeric,
                lon                 numeric,
                position_at         timestamptz,
                sharing_link        varchar,
                ok                  boolean,
                error_code          varchar,
                error_message       text
            )
    language plpgsql as
$$
declare
    res     jsonb := project.uzum_parse(p_result);
    pos     jsonb := res -> 'position';
    ph      jsonb := res -> 'phone';
    v_link  varchar;
    v_phone varchar;
begin
    if p_id is null then
        raise exception 'uzum_bad_request: нет id доставки';
    end if;
    perform project.uzum_apply_results(p_id, res - 'position' - 'phone', 'info');

    -- 409 inappropriate_status до назначения курьера — не ошибка: просто ещё нет данных
    if pos is not null and project.uzum_result_error(pos) is null then
        select rp ->> 'sharing_link'
        into v_link
        from jsonb_array_elements(pos -> 'route_points') rp
        where rp ->> 'type' = 'destination'
          and rp ->> 'sharing_link' is not null
        limit 1;
        if v_link is not null then
            update project.uzum_claims c set sharing_link = v_link where c.id = p_id;
        end if;
    else
        pos := null;
    end if;
    if ph is not null and project.uzum_result_error(ph) is null then
        v_phone := ph ->> 'phone';
    end if;

    return query
        select v.id,
               v.status,
               v.stage,
               v.performer_name,
               v.performer_transport,
               v_phone,
               project.uzum_num(pos -> 'position' ->> 'lat'),
               project.uzum_num(pos -> 'position' ->> 'lon'),
               to_timestamp(project.uzum_num(pos -> 'position' ->> 'timestamp')::double precision),
               v.sharing_link,
               v.ok,
               v.error_code,
               v.error_message
        from project.uzum_claims_v v
        where v.id = p_id;
end
$$;


-- 5.6 Callback от Uzum: POST v1/uzum/callback (без авторизации). Пишем событие, отбрасываем
--     повторы и чужие заявки, а статус берём из claims/info.
create function project.uzum_callback_receive(p_secret varchar, p_claim_id varchar, p_status varchar,
                                              p_updated_ts varchar)
    returns table
            (
                id    uuid,
                calls text,
                note  text
            )
    language plpgsql as
$$
declare
    r      project.uzum_claims;
    pt     project.uzum_points;
    v_ok   boolean;
    v_note text;
begin
    if nullif(btrim(p_claim_id), '') is null then
        insert into project.uzum_claim_events (source, status, updated_ts, note)
        values ('callback', left(p_status, 40), left(p_updated_ts, 40), 'no claim_id');
        return query select null::uuid, '[]'::text, 'no claim_id'::text;
        return;
    end if;

    select * into r from project.uzum_claims c where c.claim_id = btrim(p_claim_id);
    v_ok := case when p_secret is null then null when r.id is null then false else p_secret = r.callback_secret end;
    v_note := case when r.id is null then 'unknown claim' when v_ok is false then 'wrong secret' end;

    -- подделка (чужой секрет, неизвестная заявка) пишется как callback_bad: под защиту от
    -- повторов попадают только настоящие, иначе подделка заглушила бы настоящий callback
    insert into project.uzum_claim_events (claim_row, claim_id, source, status, updated_ts, secret_ok, note)
    values (r.id, left(btrim(p_claim_id), 64), case when v_note is null then 'callback' else 'callback_bad' end,
            left(p_status, 40), left(p_updated_ts, 40), v_ok, v_note)
    on conflict (claim_id, status, updated_ts) where source = 'callback' do nothing;
    if not found then
        v_note := 'duplicate';
    end if;

    if v_note is not null then
        return query select null::uuid, '[]'::text, v_note;   -- последняя стадия ответит ignored
        return;
    end if;

    update project.uzum_claims c set last_callback_at = now() where c.id = r.id;
    select * into pt from project.uzum_points p where p.id = r.point_id;
    return query select r.id,
                        jsonb_build_array(project.uzum_call('info', pt, 'POST',
                                                            '/v2/claims/info?claim_id=' || r.claim_id, null))::text,
                        'info'::text;
end
$$;

create function project.uzum_callback_done(p_id uuid, p_result text)
    returns table
            (
                ok   boolean,
                note text
            )
    language plpgsql as
$$
begin
    if p_id is null then
        return query select true, 'ignored'::text;
        return;
    end if;
    perform project.uzum_apply_results(p_id, project.uzum_parse(p_result), 'callback');
    return query select true, 'applied'::text;
exception
    when others then
        -- отвечаем 200 в любом случае: состояние догонит cron, а ошибку видно в событиях
        insert into project.uzum_claim_events (claim_row, source, note)
        values (p_id, 'callback', left('apply failed: ' || sqlerrm, 1000));
        return query select true, 'apply failed'::text;
end
$$;


-- 5.7 Cron: POST v1/uzum/sync — опрос активных заявок без новостей и повтор create для new
create function project.uzum_sync_prepare()
    returns table
            (
                calls text,
                n     integer
            )
    language plpgsql as
$$
declare
    v_after integer := coalesce(project.uzum_int(project.uzum_setting('sync_after_seconds')), 120);
    v_batch integer := coalesce(project.uzum_int(project.uzum_setting('sync_batch')), 20);
    v       jsonb   := '[]'::jsonb;
    rec     record;
    pt      project.uzum_points;
begin
    -- за 10 минут (или 5 попыток) так и не создалась в Uzum — больше не пробуем
    with gone as (
        update project.uzum_claims c
            set status = 'error',
                finished_at = now(),
                status_changed_at = now(),
                updated_at = now(),
                error_code = coalesce(c.error_code, 'create_timeout'),
                error_message = coalesce(c.error_message, 'Заявка не создалась в Uzum за 10 минут')
            where c.status = 'new'
                and c.finished_at is null
                and (c.created_at < now() - interval '10 minutes' or c.create_attempts >= 5)
            returning c.id)
    insert
    into project.uzum_claim_events (claim_row, source, status, old_status, note)
    select g.id, 'sync', 'error', 'new', 'create_timeout'
    from gone g;

    for rec in
        select c.id, c.point_id, c.claim_id, c.request_id, c.request
        from project.uzum_claims c
        where c.finished_at is null
          and ((c.claim_id is null and c.status = 'new'
            and greatest(c.sync_at, c.updated_at) < now() - interval '20 seconds')
            or (c.claim_id is not null
                and not (c.status = 'ready_for_approval' and c.created_at < now() - interval '1 day')
                and greatest(c.sync_at, c.last_callback_at, c.last_info_at, c.created_at)
                    < now() - make_interval(secs => case
                                                        when c.status in ('ready_for_approval', 'delivered')
                                                            then v_after * 5
                                                        else v_after end)))
        order by coalesce(c.sync_at, c.created_at)
        limit v_batch for update skip locked
        loop
            select * into pt from project.uzum_points p where p.id = rec.point_id;
            if rec.claim_id is null then
                v := v || project.uzum_call(rec.id::text || '|create', pt, 'POST',
                                            '/v2/claims/create?request_id=' || rec.request_id, rec.request);
            else
                v := v || project.uzum_call(rec.id::text || '|info', pt, 'POST',
                                            '/v2/claims/info?claim_id=' || rec.claim_id, null);
            end if;
            update project.uzum_claims c set sync_at = now() where c.id = rec.id;
        end loop;
    return query select v::text, jsonb_array_length(v);
end
$$;

create function project.uzum_sync_save(p_result text)
    returns table
            (
                checked integer,
                changed integer,
                errors  integer
            )
    language plpgsql as
$$
declare
    res   jsonb   := project.uzum_parse(p_result);
    k     text;
    x     jsonb;
    v_id  uuid;
    v_old varchar;
    v_new varchar;
    n_chk integer := 0;
    n_chg integer := 0;
    n_err integer := 0;
begin
    if res ? '_bad_result' then
        insert into project.uzum_claim_events (source, note)
        values ('sync', left('bad result ' || (res ->> '_bad_result'), 1000));
        return query select 0, 0, 1;
        return;
    end if;
    for k, x in select e.key, e.value from jsonb_each(res) e
        loop
            v_id := project.uzum_uuid(split_part(k, '|', 1));
            continue when v_id is null;
            select c.status into v_old from project.uzum_claims c where c.id = v_id;
            perform project.uzum_apply_results(v_id, jsonb_build_object(split_part(k, '|', 2), x), 'sync');
            select c.status into v_new from project.uzum_claims c where c.id = v_id;
            n_chk := n_chk + 1;
            if v_new is distinct from v_old then
                n_chg := n_chg + 1;
            end if;
            if project.uzum_result_error(x) is not null then
                n_err := n_err + 1;
            end if;
        end loop;
    return query select n_chk, n_chg, n_err;
end
$$;


-- 5.8 Диагностика платформы: GET v1/uzum/diag (администратор). Показывает, как http.post
--     ведёт себя на 404 и какой режим тела (строка или объект) понимает Uzum.
create function project.uzum_diag_prepare(p_user uuid, p_place uuid)
    returns table
            (
                calls    text,
                env      varchar,
                point_id uuid,
                base_url text
            )
    language plpgsql
    stable as
$$
declare
    pt     project.uzum_points;
    v_body jsonb;
begin
    if not project.uzum_is_admin(p_user) then
        raise exception 'uzum_no_access: диагностика — только администратору доставки (uzum_operators без place_id), пользователь %',
            p_user;
    end if;
    if p_place is not null then
        pt := project.uzum_point_pick(p_place, null);
    else
        select * into pt from project.uzum_points p where p.state = 1 order by p.created_at limit 1;
        if not found then
            raise exception 'uzum_no_point: нет ни одной активной точки Uzum';
        end if;
    end if;
    -- адрес доставки — примерно в километре от точки забора
    v_body := jsonb_build_object(
            'selected_taxi_class', 'courier',
            'items', jsonb_build_array(jsonb_build_object('quantity', 1, 'weight', 1, 'pickup_point', 1, 'dropoff_point', 2)),
            'route_points', jsonb_build_array(
                    jsonb_build_object('id', 1, 'coordinates', jsonb_build_array(pt.lon, pt.lat), 'fullname', pt.address),
                    jsonb_build_object('id', 2, 'coordinates', jsonb_build_array(pt.lon + 0.01, pt.lat - 0.005),
                                       'fullname', 'Проверка easy-trip')));
    return query select jsonb_build_array(
                                project.uzum_call('info404', pt, 'POST',
                                                  '/v2/claims/info?claim_id=00000000000000000000000000000000', null),
                                project.uzum_call('calc_string', pt, 'POST', '/v2/offers/calculate', v_body)
                                    || jsonb_build_object('body_mode', 'string'),
                                project.uzum_call('calc_object', pt, 'POST', '/v2/offers/calculate', v_body)
                                    || jsonb_build_object('body_mode', 'object'))::text,
                        pt.env,
                        pt.id,
                        project.uzum_base_url(pt.env);
end
$$;

create function project.uzum_diag_result(p_result text)
    returns table
            (
                info404_code             varchar,
                info404_how              varchar,
                calc_string_ok           boolean,
                calc_string_price        numeric,
                calc_string_error        text,
                calc_object_ok           boolean,
                calc_object_error        text,
                js_body_mode             varchar,
                recommended_js_body_mode varchar,
                raw_info404              text
            )
    language plpgsql
    stable as
$$
declare
    res jsonb := project.uzum_parse(p_result);
    i4  jsonb := res -> 'info404';
    cs  jsonb := res -> 'calc_string';
    co  jsonb := res -> 'calc_object';
    e4  jsonb := project.uzum_result_error(i4);
    es  jsonb := project.uzum_result_error(cs);
    eo  jsonb := project.uzum_result_error(co);
begin
    return query select (e4 ->> 'code')::varchar,
                        (case
                             when res ? '_bad_result' then 'platform_result'
                             when i4 ? '_error' then 'exception'
                             when e4 is not null then 'body'
                             else 'unexpected' end)::varchar,
                        es is null,
                        project.uzum_num(cs -> 'offers' -> 0 -> 'price' ->> 'total_price'),
                        (es ->> 'code') || ': ' || (es ->> 'message'),
                        eo is null,
                        (eo ->> 'code') || ': ' || (eo ->> 'message'),
                        project.uzum_setting('js_body_mode')::varchar,
                        (case when es is null then 'string' when eo is null then 'object' end)::varchar,
                        left(coalesce(i4 ->> '_error', i4::text, res ->> '_bad_result'), 1000);
end
$$;


-- 5.9 Списки
create function project.uzum_claims_list(p_user uuid, p_place uuid, p_status varchar, p_active boolean,
                                         p_limit integer, p_offset integer)
    returns setof project.uzum_claims_v
    language sql
    stable as
$$
select v.*
from project.uzum_claims_v v
where project.uzum_is_operator(p_user, v.place_id)
  and (p_place is null or v.place_id = p_place)
  and (nullif(p_status, '') is null or v.status = p_status or v.stage = p_status)
  and (p_active is null or (v.finished_at is null) = p_active)
order by v.created_at desc
limit least(coalesce(p_limit, 50), 500) offset coalesce(p_offset, 0)
$$;

-- где доступна доставка (без токенов) — для приложения
create function project.uzum_points_list(p_place uuid)
    returns table
            (
                id         uuid,
                place_id   uuid,
                branch_id  uuid,
                env        varchar,
                place_name varchar,
                name       varchar,
                address    varchar,
                lon        numeric,
                lat        numeric,
                taxi_class varchar
            )
    language sql
    stable as
$$
select p.id,
       p.place_id,
       p.branch_id,
       p.env,
       coalesce(pl.name_ru, pl.name_uz, pl.name_en)::varchar,
       p.name,
       p.address,
       p.lon,
       p.lat,
       p.taxi_class
from project.uzum_points p
         left join project.places pl on pl.id = p.place_id
where p.state = 1
  and (p_place is null or p.place_id = p_place)
order by 5 nulls last, p.name
$$;

create function project.uzum_me(p_user uuid, p_username varchar)
    returns table
            (
                user_id         uuid,
                username        varchar,
                is_admin        boolean,
                operator_places integer,
                points          integer
            )
    language sql
    stable as
$$
select p_user,
       p_username,
       project.uzum_is_admin(p_user),
       (select count(*)::integer from project.uzum_operators o where o.user_id = p_user and o.place_id is not null),
       (select count(*)::integer from project.uzum_points p where p.state = 1)
$$;

commit;
