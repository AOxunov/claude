-- =====================================================================================
-- Миграция 07 (06.11.2026): ежедневные розыгрыши по cron и API админки бонусных карт.
--
-- Добавляет:
--   - ti_bonus_settings — настройки: ключ random.org и для кого идут ежедневные розыгрыши;
--   - ti_bonus_admins — кому открыты API админки (id пользователя платформы из токена);
--   - функции для cron ежедневных розыгрышей: создать сегодняшние, провести закончившиеся;
--   - функции для API админки: розыгрыши за период и призы, проведение через random.org,
--     фонд и ADJUST, выплаты победителям, мониторинг. Каждая сама проверяет администратора;
--   - первые ежедневные розыгрыши на сегодня: туристам и объектам по одному месту, приз 1 доллар
--     (временно, для проверки). Дальше cron копирует призы последнего ежедневного.
-- Существующие таблицы и функции не меняются. Повторный запуск ничего не задвоит.
--
-- Запуск: база microservice, весь файл одним прогоном (DataGrip: консоль на microservice,
-- Ctrl+A, Ctrl+Enter; psql: -v ON_ERROR_STOP=1 -f). Скрипт сам переходит на роль project.
-- Потом — проверочные запросы в конце файла.
--
-- После накатки, по одному запросу со своими значениями:
--   1. Администраторы. Свой id пользователя показывает GET v1/ti/bonus/admin/me (P02)
--      или текст ошибки доступа:
--        insert into project.ti_bonus_admins (user_id, note) values ('<id пользователя>', 'Муталиб');
--   2. Ключ random.org, когда будет (в заметки и git не писать):
--        update project.ti_bonus_settings set value = '<ключ>', updated_at = now()
--        where code = 'random_org_api_key';
--   3. Пауза ежедневных розыгрышей — value = '' у daily_draws; включить — 'TOURIST,OBJECT'.
-- =====================================================================================

begin;
set local lock_timeout = '5s';
set local role project;


-- =====================================================================================
-- 1. Настройки и администраторы
-- =====================================================================================

create table if not exists project.ti_bonus_settings
(
    code       varchar(50) not null primary key,
    value      text,
    comment    varchar(255),
    updated_at timestamptz,
    updated_by uuid
);
comment on table project.ti_bonus_settings is 'Настройки бонусного модуля, меняются update-ом. Значения-секреты в заметки и git не писать';

insert into project.ti_bonus_settings (code, value, comment)
values ('random_org_api_key', null,
        'Ключ API random.org из личного кабинета api.random.org. Пусто — розыгрыши с участниками ждут ключа'),
       ('daily_draws', 'TOURIST,OBJECT',
        'Для кого cron создаёт ежедневные розыгрыши: TOURIST, OBJECT через запятую. Пусто — пауза')
on conflict (code) do nothing;


create table if not exists project.ti_bonus_admins
(
    user_id    uuid        not null primary key,
    state      smallint    not null default 1 check (state in (0, 1)),
    note       varchar(255),
    created_at timestamptz not null default now()
);
comment on table project.ti_bonus_admins is 'Кому открыты API админки бонусных карт: id пользователя платформы из токена. state = 0 — доступ снят';

comment on column project.ti_bonus_draws.attributes is 'cancel_reason — причина отмены; auto_error, auto_error_at, retry_at — последняя ошибка cron ежедневных розыгрышей и когда пробовать снова';


-- =====================================================================================
-- 2. Вспомогательные функции
-- =====================================================================================

-- Значение настройки; пустая строка — как null.
create or replace function project.ti_bonus_setting(p_code varchar)
    returns text
    language sql
    stable
as
$$
select nullif(btrim(s.value), '')
from project.ti_bonus_settings s
where s.code = p_code
$$;


create or replace function project.ti_bonus_is_admin(p_user_id uuid)
    returns boolean
    language sql
    stable
as
$$
select exists (select 1
               from project.ti_bonus_admins a
               where a.user_id = p_user_id
                 and a.state = 1)
$$;


-- Первая строка каждой функции админки. В тексте ошибки — id пользователя, чтобы его добавить.
create or replace function project.ti_bonus_admin_check(p_user_id uuid)
    returns void
    language plpgsql
    stable
as
$$
begin
    if not project.ti_bonus_is_admin(p_user_id) then
        raise exception 'Нет доступа к админке бонусных карт: пользователь % не в ti_bonus_admins',
            coalesce(p_user_id::text, 'без id');
    end if;
end;
$$;


-- Суммы призов из запроса: JSON-массив [10, 5, 1] или строка «10, 5, 1». Пусто — null.
create or replace function project.ti_bonus_parse_amounts(p_value text)
    returns numeric[]
    language plpgsql
    immutable
as
$$
declare
    v_text text := regexp_replace(translate(coalesce(p_value, ''), '[]"', ''), '\s', '', 'g');
    v_item text;
    v_num  numeric;
    v_out  numeric[] := '{}';
begin
    if v_text = '' then
        return null;
    end if;
    foreach v_item in array string_to_array(v_text, ',')
        loop
            begin
                v_num := v_item::numeric;
            exception
                when others then
                    raise exception 'Сумма приза «%» — не число', v_item;
            end;
            if v_num <= 0 or v_num <> round(v_num, 2) then
                raise exception 'Сумма приза должна быть больше нуля и с точностью до центов: %', v_item;
            end if;
            v_out := v_out || v_num;
        end loop;
    return v_out;
end;
$$;


-- Дата из запроса: 2026-11-01 или 01.11.2026. Пусто — null.
create or replace function project.ti_bonus_parse_date(p_value text)
    returns date
    language plpgsql
    immutable
as
$$
declare
    v_text text := btrim(coalesce(p_value, ''));
begin
    if v_text = '' then
        return null;
    elsif v_text ~ '^\d{4}-\d{2}-\d{2}' then
        return to_date(left(v_text, 10), 'YYYY-MM-DD');
    elsif v_text ~ '^\d{2}\.\d{2}\.\d{4}$' then
        return to_date(v_text, 'DD.MM.YYYY');
    end if;
    raise exception 'Дата «%» — нужна в виде 2026-11-01 или 01.11.2026', v_text;
end;
$$;


-- Текст в jsonb; не JSON — null.
create or replace function project.ti_bonus_try_jsonb(p_value text)
    returns jsonb
    language plpgsql
    immutable
as
$$
begin
    return p_value::jsonb;
exception
    when others then
        return null;
end;
$$;


-- =====================================================================================
-- 3. Операции: призы, фонд, выплаты
-- =====================================================================================

-- Новые призы черновика (суммы в $, по порядку мест). После фиксации — ошибка.
create or replace function project.ti_bonus_draw_set_prizes(p_draw_id uuid, p_prizes_usd numeric[], p_by uuid default null)
    returns void
    language plpgsql
as
$$
declare
    d project.ti_bonus_draws%rowtype;
begin
    if p_prizes_usd is null or cardinality(p_prizes_usd) = 0 then
        raise exception 'Нужен хотя бы один приз';
    end if;
    select * into d from project.ti_bonus_draws x where x.id = p_draw_id for update;
    if not found then
        raise exception 'Розыгрыш % не найден', p_draw_id;
    end if;
    if d.status <> 'DRAFT' then
        raise exception 'Призы меняются только у черновика, а розыгрыш в статусе %', d.status;
    end if;

    delete from project.ti_bonus_draw_prizes pz where pz.draw_id = p_draw_id;
    insert into project.ti_bonus_draw_prizes (draw_id, place_no, amount_usd, created_by)
    select p_draw_id, u.ord, u.amount, p_by
    from unnest(p_prizes_usd) with ordinality as u(amount, ord);

    update project.ti_bonus_draws x
    set updated_at = now(),
        updated_by = p_by
    where x.id = p_draw_id;
end;
$$;


-- Ручное движение фонда: плюс — пополнение, минус — на другие нужды. Комментарий обязателен.
-- В минус фонд не уйдёт. Возвращает новый остаток.
create or replace function project.ti_bonus_fund_adjust(p_fund varchar, p_amount_usd numeric, p_comment varchar,
                                                        p_by uuid default null)
    returns numeric
    language plpgsql
as
$$
declare
    v_fund    varchar := upper(btrim(coalesce(p_fund, '')));
    v_balance numeric;
begin
    if v_fund not in ('TOURIST', 'OBJECT') then
        raise exception 'Фонд — TOURIST или OBJECT, а не «%»', coalesce(p_fund, '');
    end if;
    if p_amount_usd is null or p_amount_usd = 0 or p_amount_usd <> round(p_amount_usd, 2) then
        raise exception 'Сумма должна быть не нулём и с точностью до центов: %', coalesce(p_amount_usd::text, 'пусто');
    end if;
    if nullif(btrim(p_comment), '') is null then
        raise exception 'Нужен комментарий: откуда деньги или на что';
    end if;

    -- та же блокировка, что у фиксации розыгрыша: списания не уведут фонд в минус
    perform pg_advisory_xact_lock(hashtext('project.ti_bonus_prize_fund'));
    select coalesce(sum(f.amount_usd), 0)
    into v_balance
    from project.ti_bonus_prize_fund_ledger f
    where f.fund = v_fund;
    if v_balance + p_amount_usd < 0 then
        raise exception 'В фонде % $%, списать $% нельзя', v_fund, round(v_balance, 2), -p_amount_usd;
    end if;

    insert into project.ti_bonus_prize_fund_ledger (fund, op_type, amount_usd, occurred_at, comment, created_by)
    values (v_fund, 'ADJUST', p_amount_usd, now(), left(btrim(p_comment), 255), p_by);

    return v_balance + p_amount_usd;
end;
$$;


-- Отметка выплаты победителю. Повторно — ошибка.
create or replace function project.ti_bonus_winner_paid(p_winner_id uuid, p_paid_amount numeric, p_paid_currency varchar,
                                                        p_paid_rate numeric default null, p_payout_ref varchar default null,
                                                        p_by uuid default null)
    returns void
    language plpgsql
as
$$
declare
    w          project.ti_bonus_draw_winners%rowtype;
    v_currency varchar := upper(btrim(coalesce(p_paid_currency, '')));
begin
    select * into w from project.ti_bonus_draw_winners x where x.id = p_winner_id for update;
    if not found then
        raise exception 'Победитель % не найден', p_winner_id;
    end if;
    if w.payout_status <> 'PENDING' then
        raise exception 'Выплата этому победителю уже в статусе %', w.payout_status;
    end if;
    if p_paid_amount is null or p_paid_amount <= 0 then
        raise exception 'Сумма выплаты должна быть больше нуля';
    end if;
    if v_currency !~ '^[A-Z]{3}$' then
        raise exception 'Валюта выплаты — три буквы (UZS, USD), а не «%»', coalesce(p_paid_currency, '');
    end if;
    if p_paid_rate is not null and p_paid_rate <= 0 then
        raise exception 'Курс выплаты должен быть больше нуля';
    end if;

    update project.ti_bonus_draw_winners x
    set payout_status = 'PAID',
        paid_at       = now(),
        paid_amount   = p_paid_amount,
        paid_currency = v_currency,
        paid_rate     = p_paid_rate,
        payout_ref    = left(nullif(btrim(p_payout_ref), ''), 100),
        updated_at    = now(),
        updated_by    = p_by
    where x.id = p_winner_id;
end;
$$;


-- =====================================================================================
-- 4. Проведение через стадии platon: подготовка → запрос к random.org → итог
-- =====================================================================================

-- Фиксация (если черновик) и всё для запроса к random.org.
--   need_random — участники есть: стадия platon шлёт запрос с n, entries_hash и api_key;
--   need_empty  — участников нет: провести без random.org.
-- Нет ключа при участниках — ошибка (в одной транзакции с фиксацией: розыгрыш остаётся черновиком).
create or replace function project.ti_bonus_draw_prepare(p_draw_id uuid)
    returns table
            (
                draw_id         uuid,
                audience        varchar,
                status          varchar,
                entries_count   integer,
                prizes_count    integer,
                prize_total_usd numeric,
                need_random     boolean,
                need_empty      boolean,
                n               integer,
                entries_hash    varchar,
                api_key         text
            )
    language plpgsql
as
$$
declare
    f     record;
    v_key text;
begin
    if p_draw_id is null then
        raise exception 'Не указан розыгрыш (id)';
    end if;
    select * into f from project.ti_bonus_draw_freeze(p_draw_id) x;
    if f.prizes_count > 0 then
        v_key := project.ti_bonus_setting('random_org_api_key');
        if v_key is null then
            raise exception 'Нет ключа random.org: заполните ti_bonus_settings.random_org_api_key';
        end if;
    end if;

    return query
        select d.id, d.audience, d.status, d.entries_count, d.prizes_count, d.prize_total_usd,
               d.prizes_count > 0, d.prizes_count = 0, greatest(d.prizes_count, 1), d.entries_hash, v_key
        from project.ti_bonus_draws d
        where d.id = p_draw_id;
end;
$$;


-- Итог по ответу random.org (как пришёл из стадии platon); участников нет — ответ null.
-- Ошибка random.org — понятным текстом. Возвращает число победителей.
create or replace function project.ti_bonus_draw_finish(p_draw_id uuid, p_random_response text)
    returns integer
    language plpgsql
as
$$
declare
    v_resp jsonb;
    v_cnt  integer;
begin
    if p_random_response is not null then
        v_resp := project.ti_bonus_try_jsonb(p_random_response);
        if v_resp is null then
            raise exception 'Ответ random.org — не JSON: %', left(p_random_response, 200);
        end if;
        if coalesce(jsonb_typeof(v_resp -> 'error'), 'null') <> 'null' then
            raise exception 'random.org вернул ошибку %: %', coalesce(v_resp #>> '{error,code}', '-'),
                coalesce(v_resp #>> '{error,message}', v_resp ->> 'error');
        end if;
    end if;

    select count(*) into v_cnt from project.ti_bonus_draw_run(p_draw_id, p_random_response) r;
    return v_cnt;
end;
$$;


-- =====================================================================================
-- 5. Cron ежедневных розыгрышей
-- =====================================================================================

-- Ошибка cron по розыгрышу: в attributes и в ti_bonus_errors; следующая попытка — через час.
create or replace function project.ti_bonus_draw_auto_error(p_draw_id uuid, p_message text)
    returns void
    language plpgsql
as
$$
begin
    update project.ti_bonus_draws x
    set attributes = (coalesce(x.attributes::jsonb, '{}'::jsonb)
        || jsonb_build_object('auto_error', left(p_message, 1000),
                              'auto_error_at', now(),
                              'retry_at', now() + interval '1 hour'))::json,
        updated_at = now()
    where x.id = p_draw_id
      and x.status in ('DRAFT', 'FROZEN');

    insert into project.ti_bonus_errors (source, message, detail)
    values ('draw_daily', left(p_message, 1000), 'draw_id=' || coalesce(p_draw_id::text, ''));
end;
$$;


-- Для cron раз в 10 минут. Создаёт сегодняшние ежедневные розыгрыши (призы — как у последнего
-- ежедневного той же аудитории) и готовит один закончившийся. Всегда одна строка:
--   need_random — запросить random.org и передать ответ в ti_bonus_draw_daily_finish;
--   need_empty  — участников нет: ti_bonus_draw_daily_finish без ответа;
--   оба false   — делать нечего или ошибка (текст в note, в ti_bonus_errors и в attributes
--                 розыгрыша; повтор через час). Ошибка одного розыгрыша cron не роняет.
-- Отменённый день заново не создаётся. Первый ежедневный создаёт компания (миграция 07 или админка).
create or replace function project.ti_bonus_draw_daily_next()
    returns table
            (
                draw_id      uuid,
                audience     varchar,
                need_random  boolean,
                need_empty   boolean,
                n            integer,
                entries_hash varchar,
                api_key      text,
                created      integer,
                note         text
            )
    language plpgsql
as
$$
declare
    v_today   date   := (now() at time zone 'Asia/Tashkent')::date;
    v_enabled text[] := string_to_array(upper(regexp_replace(coalesce(project.ti_bonus_setting('daily_draws'), ''),
                                                             '\s', '', 'g')), ',');
    v_aud     varchar;
    v_created integer := 0;
    d         project.ti_bonus_draws%rowtype;
    v_key     text;
    v_err     text;
begin
    -- два одновременных запуска не создадут один день дважды
    perform pg_advisory_xact_lock(hashtext('project.ti_bonus_draw_daily'));

    foreach v_aud in array array ['TOURIST', 'OBJECT']::varchar[]
        loop
            if v_aud = any (v_enabled)
                and exists (select 1
                            from project.ti_bonus_draws x
                            where x.kind = 'DAILY'
                              and x.audience = v_aud
                              and x.status <> 'CANCELLED')
                and not exists (select 1
                                from project.ti_bonus_draws x
                                where x.kind = 'DAILY'
                                  and x.audience = v_aud
                                  and x.period_from = (v_today::timestamp at time zone 'Asia/Tashkent')) then
                perform project.ti_bonus_draw_create_daily(v_aud, v_today);
                v_created := v_created + 1;
            end if;
        end loop;

    select x.*
    into d
    from project.ti_bonus_draws x
    where x.kind = 'DAILY'
      and x.status in ('DRAFT', 'FROZEN')
      and x.period_to <= now()
      and coalesce((x.attributes ->> 'retry_at')::timestamptz, '-infinity'::timestamptz) <= now()
    order by x.period_to, x.audience
    limit 1
    for update;

    if not found then
        return query select null::uuid, null::varchar, false, false, null::integer, null::varchar, null::text,
                            v_created, 'закончившихся ежедневных розыгрышей нет'::text;
        return;
    end if;

    if d.status = 'DRAFT' then
        begin
            perform 1 from project.ti_bonus_draw_freeze(d.id) f;
        exception
            when others then
                get stacked diagnostics v_err = message_text;
                perform project.ti_bonus_draw_auto_error(d.id, 'фиксация: ' || v_err);
                return query select d.id, d.audience, false, false, null::integer, null::varchar, null::text,
                                    v_created, 'ошибка: фиксация: ' || v_err;
                return;
        end;
        select x.* into d from project.ti_bonus_draws x where x.id = d.id;
    end if;

    if d.prizes_count = 0 then
        return query select d.id, d.audience, false, true, null::integer, d.entries_hash, null::text,
                            v_created, 'участников нет: провести без random.org'::text;
        return;
    end if;

    v_key := project.ti_bonus_setting('random_org_api_key');
    if v_key is null then
        perform project.ti_bonus_draw_auto_error(d.id, 'нет ключа random.org в ti_bonus_settings');
        return query select d.id, d.audience, false, false, null::integer, d.entries_hash, null::text,
                            v_created, 'ошибка: нет ключа random.org'::text;
        return;
    end if;

    return query select d.id, d.audience, true, false, d.prizes_count, d.entries_hash, v_key,
                        v_created, 'запрос к random.org'::text;
end;
$$;


-- Итог ежедневного розыгрыша для cron. Ошибка (в том числе ответ random.org с ошибкой) не роняет
-- cron: розыгрыш остаётся зафиксированным, ошибка — в attributes и ti_bonus_errors, повтор через час.
create or replace function project.ti_bonus_draw_daily_finish(p_draw_id uuid, p_random_response text)
    returns table
            (
                draw_id uuid,
                status  varchar,
                winners integer,
                note    text
            )
    language plpgsql
as
$$
declare
    v_cnt integer;
    v_err text;
begin
    begin
        v_cnt := project.ti_bonus_draw_finish(p_draw_id, p_random_response);
    exception
        when others then
            get stacked diagnostics v_err = message_text;
            perform project.ti_bonus_draw_auto_error(p_draw_id, 'проведение: ' || v_err);
            return query select p_draw_id, (select x.status from project.ti_bonus_draws x where x.id = p_draw_id),
                                0, 'ошибка: проведение: ' || v_err;
            return;
    end;
    return query select p_draw_id, (select x.status from project.ti_bonus_draws x where x.id = p_draw_id),
                        v_cnt, 'проведён'::text;
end;
$$;


-- =====================================================================================
-- 6. API админки. Первый параметр — пользователь из токена; не администратор — ошибка.
--    Даты — по Ташкенту; date_to включительно.
-- =====================================================================================

-- Строки списка розыгрышей (без проверки доступа: только для функций ниже).
create or replace function project.ti_bonus_draw_rows(p_draw_id uuid, p_audience varchar, p_kind varchar,
                                                      p_status varchar, p_limit integer, p_offset integer)
    returns table
            (
                id               uuid,
                audience         varchar,
                kind             varchar,
                title            varchar,
                date_from        text,
                date_to          text,
                status           varchar,
                prizes           text,
                prizes_usd       numeric,
                entries_count    integer,
                prizes_count     integer,
                winners_count    integer,
                unpaid_count     integer,
                fund_balance_usd numeric,
                error            text,
                drawn_at         text,
                hash             varchar
            )
    language sql
    stable
as
$$
with b as (select f.fund, round(f.balance_usd, 2) as balance_usd
           from project.ti_bonus_prize_fund_balance f)
select d.id,
       d.audience,
       d.kind,
       d.title,
       to_char(d.period_from at time zone 'Asia/Tashkent', 'YYYY-MM-DD'),
       to_char((d.period_to at time zone 'Asia/Tashkent') - interval '1 second', 'YYYY-MM-DD'),
       d.status,
       pz.prizes,
       coalesce(pz.total, 0),
       d.entries_count,
       d.prizes_count,
       coalesce(w.cnt, 0)::integer,
       coalesce(w.unpaid, 0)::integer,
       b.balance_usd,
       case when d.status in ('DRAFT', 'FROZEN') then d.attributes ->> 'auto_error' end,
       to_char(d.drawn_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
       d.hash
from project.ti_bonus_draws d
         left join b on b.fund = d.audience
         left join lateral (select string_agg(p.amount_usd::text, ' + ' order by p.place_no) as prizes,
                                   sum(p.amount_usd)                                       as total
                            from project.ti_bonus_draw_prizes p
                            where p.draw_id = d.id
                              and p.state = 1) pz on true
         left join lateral (select count(*)                                            as cnt,
                                   count(*) filter (where x.payout_status = 'PENDING') as unpaid
                            from project.ti_bonus_draw_winners x
                            where x.draw_id = d.id) w on true
where (p_draw_id is null or d.id = p_draw_id)
  and (p_audience is null or d.audience = p_audience)
  and (p_kind is null or d.kind = p_kind)
  and (p_status is null or d.status = p_status)
order by d.period_to desc, d.audience, d.id
limit least(greatest(coalesce(p_limit, 50), 1), 500) offset greatest(coalesce(p_offset, 0), 0)
$$;


-- Список розыгрышей; фильтры необязательные.
create or replace function project.ti_bonus_admin_draws(p_admin uuid, p_audience varchar default null,
                                                        p_kind varchar default null, p_status varchar default null,
                                                        p_limit integer default null, p_offset integer default null)
    returns table
            (
                id               uuid,
                audience         varchar,
                kind             varchar,
                title            varchar,
                date_from        text,
                date_to          text,
                status           varchar,
                prizes           text,
                prizes_usd       numeric,
                entries_count    integer,
                prizes_count     integer,
                winners_count    integer,
                unpaid_count     integer,
                fund_balance_usd numeric,
                error            text,
                drawn_at         text,
                hash             varchar
            )
    language plpgsql
    stable
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query
        select *
        from project.ti_bonus_draw_rows(null, upper(nullif(btrim(p_audience), '')), upper(nullif(btrim(p_kind), '')),
                                        upper(nullif(btrim(p_status), '')), p_limit, p_offset);
end;
$$;


-- Розыгрыш целиком: призы, победители с контактами, ответ random.org с подписью.
create or replace function project.ti_bonus_admin_draw(p_admin uuid, p_draw_id uuid)
    returns jsonb
    language plpgsql
    stable
as
$$
declare
    v_out jsonb;
begin
    perform project.ti_bonus_admin_check(p_admin);

    select jsonb_build_object(
                   'id', d.id,
                   'audience', d.audience,
                   'kind', d.kind,
                   'title', d.title,
                   'status', d.status,
                   'date_from', to_char(d.period_from at time zone 'Asia/Tashkent', 'YYYY-MM-DD'),
                   'date_to', to_char((d.period_to at time zone 'Asia/Tashkent') - interval '1 second', 'YYYY-MM-DD'),
                   'period_from', to_char(d.period_from at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
                   'period_to', to_char(d.period_to at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
                   'entries_count', d.entries_count,
                   'total_weight_usd', round(d.total_weight_cents / 100.0, 2),
                   'prizes_count', d.prizes_count,
                   'prize_total_usd', d.prize_total_usd,
                   'frozen_at', to_char(d.frozen_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
                   'drawn_at', to_char(d.drawn_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
                   'entries_hash', d.entries_hash,
                   'prev_hash', d.prev_hash,
                   'hash', d.hash,
                   'error', case when d.status in ('DRAFT', 'FROZEN') then d.attributes ->> 'auto_error' end,
                   'cancel_reason', d.attributes ->> 'cancel_reason',
                   'fund_balance_usd', (select round(b.balance_usd, 2)
                                        from project.ti_bonus_prize_fund_balance b
                                        where b.fund = d.audience),
                   'random', project.ti_bonus_try_jsonb(d.random_response) #> '{result,random}',
                   'signature', project.ti_bonus_try_jsonb(d.random_response) #>> '{result,signature}',
                   'prizes', coalesce((select jsonb_agg(jsonb_build_object('place_no', p.place_no,
                                                                           'amount_usd', p.amount_usd)
                                                        order by p.place_no)
                                       from project.ti_bonus_draw_prizes p
                                       where p.draw_id = d.id
                                         and p.state = 1), '[]'::jsonb),
                   'winners', coalesce((select jsonb_agg(jsonb_build_object(
                                                                 'id', w.id,
                                                                 'round_no', w.round_no,
                                                                 'place_no', p.place_no,
                                                                 'amount_usd', w.amount_usd,
                                                                 'ticket', w.ticket,
                                                                 'user_id', w.user_id,
                                                                 'user_name', u.name,
                                                                 'user_phone', u.phone,
                                                                 'place_id', w.place_id,
                                                                 'place_name', pl.name_uz,
                                                                 'payout_status', w.payout_status,
                                                                 'paid_at', to_char(w.paid_at at time zone 'Asia/Tashkent',
                                                                                    'YYYY-MM-DD HH24:MI'),
                                                                 'paid_amount', w.paid_amount,
                                                                 'paid_currency', w.paid_currency,
                                                                 'paid_rate', w.paid_rate,
                                                                 'payout_ref', w.payout_ref)
                                                         order by w.round_no)
                                        from project.ti_bonus_draw_winners w
                                                 join project.ti_bonus_draw_prizes p on p.id = w.prize_id
                                                 left join project.places pl on pl.id = w.place_id
                                                 left join lateral (select coalesce(nullif(btrim(au.full_name), ''),
                                                                                    nullif(btrim(concat_ws(' ', au.first_name, au.second_name)), ''),
                                                                                    au.username)                 as name,
                                                                           coalesce(nullif(btrim(au.mobile_phone), ''),
                                                                                    au.username)                 as phone
                                                                    from project.auth_users au
                                                                    where au.user_id = w.user_id
                                                                    order by au.updated_at desc nulls last, au.created_at desc nulls last
                                                                    limit 1) u on true
                                        where w.draw_id = d.id), '[]'::jsonb))
    into v_out
    from project.ti_bonus_draws d
    where d.id = p_draw_id;

    if v_out is null then
        raise exception 'Розыгрыш % не найден', p_draw_id;
    end if;
    return v_out;
end;
$$;


-- Новый розыгрыш. PERIOD — с date_from по date_to включительно. DAILY — за день date_from
-- (так запускают ежедневные заново или меняют призы с этого дня). Призы: [10, 5, 1] или «10, 5, 1».
create or replace function project.ti_bonus_admin_draw_create(p_admin uuid, p_audience varchar, p_date_from text,
                                                              p_date_to text, p_prizes text, p_title varchar default null,
                                                              p_kind varchar default null)
    returns table
            (
                id               uuid,
                audience         varchar,
                kind             varchar,
                title            varchar,
                date_from        text,
                date_to          text,
                status           varchar,
                prizes           text,
                prizes_usd       numeric,
                entries_count    integer,
                prizes_count     integer,
                winners_count    integer,
                unpaid_count     integer,
                fund_balance_usd numeric,
                error            text,
                drawn_at         text,
                hash             varchar
            )
    language plpgsql
as
$$
declare
    v_aud    varchar;
    v_kind   varchar;
    v_from   date;
    v_to     date;
    v_prizes numeric[];
    v_title  varchar;
    v_id     uuid;
begin
    perform project.ti_bonus_admin_check(p_admin);

    v_aud := upper(nullif(btrim(p_audience), ''));
    v_kind := coalesce(upper(nullif(btrim(p_kind), '')), 'PERIOD');
    v_from := project.ti_bonus_parse_date(p_date_from);
    v_to := project.ti_bonus_parse_date(p_date_to);
    v_prizes := project.ti_bonus_parse_amounts(p_prizes);
    v_title := left(nullif(btrim(p_title), ''), 255);

    if v_aud is null or v_aud not in ('TOURIST', 'OBJECT') then
        raise exception 'Аудитория — TOURIST или OBJECT, а не «%»', coalesce(p_audience, '');
    end if;
    if v_kind not in ('PERIOD', 'DAILY') then
        raise exception 'Вид розыгрыша — PERIOD или DAILY, а не «%»', p_kind;
    end if;
    if v_from is null then
        raise exception 'Нужна дата начала (date_from)';
    end if;
    if v_prizes is null then
        raise exception 'Нужен хотя бы один приз';
    end if;

    if v_kind = 'PERIOD' then
        if v_to is null or v_to < v_from then
            raise exception 'Нужна дата конца (date_to) не раньше начала';
        end if;
        v_id := project.ti_bonus_draw_create(v_aud,
                                             v_from::timestamp at time zone 'Asia/Tashkent',
                                             (v_to + 1)::timestamp at time zone 'Asia/Tashkent',
                                             v_prizes,
                                             coalesce(v_title, 'Розыгрыш ' || to_char(v_from, 'DD.MM.YYYY') || ' — ' ||
                                                               to_char(v_to, 'DD.MM.YYYY')),
                                             'PERIOD', p_admin);
    else
        if v_to is not null and v_to <> v_from then
            raise exception 'Ежедневный розыгрыш — за один день: date_to пусто или равно date_from';
        end if;
        if exists (select 1
                   from project.ti_bonus_draws x
                   where x.kind = 'DAILY'
                     and x.audience = v_aud
                     and x.status <> 'CANCELLED'
                     and x.period_from = (v_from::timestamp at time zone 'Asia/Tashkent')) then
            raise exception 'Ежедневный розыгрыш за % уже есть: поменяйте призы в нём', to_char(v_from, 'DD.MM.YYYY');
        end if;
        v_id := project.ti_bonus_draw_create_daily(v_aud, v_from, v_prizes, p_admin);
    end if;

    return query select * from project.ti_bonus_draw_rows(v_id, null, null, null, 1, 0);
end;
$$;


-- Новые призы черновика.
create or replace function project.ti_bonus_admin_draw_prizes(p_admin uuid, p_draw_id uuid, p_prizes text)
    returns table
            (
                id               uuid,
                audience         varchar,
                kind             varchar,
                title            varchar,
                date_from        text,
                date_to          text,
                status           varchar,
                prizes           text,
                prizes_usd       numeric,
                entries_count    integer,
                prizes_count     integer,
                winners_count    integer,
                unpaid_count     integer,
                fund_balance_usd numeric,
                error            text,
                drawn_at         text,
                hash             varchar
            )
    language plpgsql
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    perform project.ti_bonus_draw_set_prizes(p_draw_id, project.ti_bonus_parse_amounts(p_prizes), p_admin);
    return query select * from project.ti_bonus_draw_rows(p_draw_id, null, null, null, 1, 0);
end;
$$;


-- Проведение из админки, шаг 1: фиксация и параметры запроса к random.org.
create or replace function project.ti_bonus_admin_draw_prepare(p_admin uuid, p_draw_id uuid)
    returns table
            (
                draw_id         uuid,
                audience        varchar,
                status          varchar,
                entries_count   integer,
                prizes_count    integer,
                prize_total_usd numeric,
                need_random     boolean,
                need_empty      boolean,
                n               integer,
                entries_hash    varchar,
                api_key         text
            )
    language plpgsql
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query select * from project.ti_bonus_draw_prepare(p_draw_id);
end;
$$;


-- Проведение из админки, шаг 2: итог по ответу random.org. Возвращает число победителей.
create or replace function project.ti_bonus_admin_draw_finish(p_admin uuid, p_draw_id uuid, p_random_response text)
    returns integer
    language plpgsql
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return project.ti_bonus_draw_finish(p_draw_id, p_random_response);
end;
$$;


-- Отмена до проведения; причина обязательна. Призы, уже списанные из фонда, возвращаются.
create or replace function project.ti_bonus_admin_draw_cancel(p_admin uuid, p_draw_id uuid, p_reason varchar)
    returns table
            (
                id               uuid,
                audience         varchar,
                kind             varchar,
                title            varchar,
                date_from        text,
                date_to          text,
                status           varchar,
                prizes           text,
                prizes_usd       numeric,
                entries_count    integer,
                prizes_count     integer,
                winners_count    integer,
                unpaid_count     integer,
                fund_balance_usd numeric,
                error            text,
                drawn_at         text,
                hash             varchar
            )
    language plpgsql
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    if not exists (select 1 from project.ti_bonus_draws x where x.id = p_draw_id) then
        raise exception 'Розыгрыш % не найден', p_draw_id;
    end if;
    if nullif(btrim(p_reason), '') is null then
        raise exception 'Нужна причина отмены';
    end if;

    perform project.ti_bonus_draw_cancel(p_draw_id, left(btrim(p_reason), 200));
    update project.ti_bonus_draws x
    set updated_by = p_admin
    where x.id = p_draw_id;

    return query select * from project.ti_bonus_draw_rows(p_draw_id, null, null, null, 1, 0);
end;
$$;


-- Фонды: остатки за всё время и движения за период (по умолчанию — с начала месяца по сегодня).
-- planned_prizes_usd — призы черновиков, ещё не списанные; free_usd — остаток минус они.
create or replace function project.ti_bonus_admin_fund(p_admin uuid, p_date_from text default null,
                                                       p_date_to text default null)
    returns table
            (
                fund                 varchar,
                balance_usd          numeric,
                collected_usd        numeric,
                prizes_usd           numeric,
                adjusted_usd         numeric,
                planned_prizes_usd   numeric,
                free_usd             numeric,
                date_from            text,
                date_to              text,
                period_collected_usd numeric,
                period_prizes_usd    numeric,
                period_adjusted_usd  numeric
            )
    language plpgsql
    stable
as
$$
declare
    v_from date;
    v_to   date;
begin
    perform project.ti_bonus_admin_check(p_admin);
    v_from := coalesce(project.ti_bonus_parse_date(p_date_from),
                       date_trunc('month', now() at time zone 'Asia/Tashkent')::date);
    v_to := coalesce(project.ti_bonus_parse_date(p_date_to), (now() at time zone 'Asia/Tashkent')::date);
    if v_to < v_from then
        raise exception 'Конец периода раньше начала';
    end if;

    return query
        select b.fund::varchar,
               round(b.balance_usd, 2),
               round(b.collected_usd, 2),
               round(b.prizes_usd, 2),
               round(b.adjusted_usd, 2),
               coalesce(pl.planned, 0),
               round(b.balance_usd, 2) - coalesce(pl.planned, 0),
               to_char(v_from, 'YYYY-MM-DD'),
               to_char(v_to, 'YYYY-MM-DD'),
               round(coalesce(pr.collected, 0), 2),
               round(coalesce(pr.prizes, 0), 2),
               round(coalesce(pr.adjusted, 0), 2)
        from project.ti_bonus_prize_fund_balance b
                 left join lateral (select sum(p.amount_usd) as planned
                                    from project.ti_bonus_draws d
                                             join project.ti_bonus_draw_prizes p on p.draw_id = d.id and p.state = 1
                                    where d.audience = b.fund
                                      and d.status = 'DRAFT') pl on true
                 left join lateral (select sum(l.amount_usd) filter (where l.op_type in ('SPEND', 'BURN', 'REFUND')) as collected,
                                           -sum(l.amount_usd) filter (where l.op_type in ('PRIZE', 'PRIZE_RETURN')) as prizes,
                                           sum(l.amount_usd) filter (where l.op_type = 'ADJUST')                   as adjusted
                                    from project.ti_bonus_prize_fund_ledger l
                                    where l.fund = b.fund
                                      and l.occurred_at >= (v_from::timestamp at time zone 'Asia/Tashkent')
                                      and l.occurred_at < ((v_to + 1)::timestamp at time zone 'Asia/Tashkent')) pr on true
        order by b.fund desc;
end;
$$;


-- Движения фонда, новые первыми; фильтры необязательные.
create or replace function project.ti_bonus_admin_fund_ledger(p_admin uuid, p_fund varchar default null,
                                                              p_op_type varchar default null,
                                                              p_limit integer default null, p_offset integer default null)
    returns table
            (
                id          uuid,
                occurred_at text,
                fund        varchar,
                op_type     varchar,
                amount_usd  numeric,
                draw_id     uuid,
                draw_title  varchar,
                comment     varchar,
                created_by  uuid
            )
    language plpgsql
    stable
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query
        select l.id,
               to_char(l.occurred_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
               l.fund,
               l.op_type,
               l.amount_usd,
               l.draw_id,
               d.title,
               l.comment,
               l.created_by
        from project.ti_bonus_prize_fund_ledger l
                 left join project.ti_bonus_draws d on d.id = l.draw_id
        where (nullif(btrim(p_fund), '') is null or l.fund = upper(btrim(p_fund)))
          and (nullif(btrim(p_op_type), '') is null or l.op_type = upper(btrim(p_op_type)))
        order by l.occurred_at desc, l.created_at desc, l.id
        limit least(greatest(coalesce(p_limit, 100), 1), 1000) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;


-- Пополнение или списание фонда (ADJUST). Возвращает новый остаток.
create or replace function project.ti_bonus_admin_fund_adjust(p_admin uuid, p_fund varchar, p_amount_usd numeric,
                                                              p_comment varchar)
    returns table
            (
                fund        varchar,
                amount_usd  numeric,
                balance_usd numeric
            )
    language plpgsql
as
$$
declare
    v_balance numeric;
begin
    perform project.ti_bonus_admin_check(p_admin);
    v_balance := project.ti_bonus_fund_adjust(p_fund, p_amount_usd, p_comment, p_admin);
    return query select upper(btrim(p_fund))::varchar, p_amount_usd, round(v_balance, 2);
end;
$$;


-- Победители и выплаты: невыплаченные первыми; фильтры необязательные.
create or replace function project.ti_bonus_admin_winners(p_admin uuid, p_payout_status varchar default null,
                                                          p_audience varchar default null,
                                                          p_limit integer default null, p_offset integer default null)
    returns table
            (
                id            uuid,
                draw_id       uuid,
                draw_title    varchar,
                audience      varchar,
                kind          varchar,
                date_from     text,
                date_to       text,
                drawn_at      text,
                place_no      integer,
                amount_usd    numeric,
                user_id       uuid,
                user_name     varchar,
                user_phone    varchar,
                place_id      uuid,
                place_name    varchar,
                payout_status varchar,
                paid_at       text,
                paid_amount   numeric,
                paid_currency varchar,
                paid_rate     numeric,
                payout_ref    varchar
            )
    language plpgsql
    stable
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query
        select w.id,
               w.draw_id,
               d.title,
               d.audience,
               d.kind,
               to_char(d.period_from at time zone 'Asia/Tashkent', 'YYYY-MM-DD'),
               to_char((d.period_to at time zone 'Asia/Tashkent') - interval '1 second', 'YYYY-MM-DD'),
               to_char(d.drawn_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
               p.place_no::integer,
               w.amount_usd,
               w.user_id,
               u.name,
               u.phone,
               w.place_id,
               pl.name_uz,
               w.payout_status,
               to_char(w.paid_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
               w.paid_amount,
               w.paid_currency,
               w.paid_rate,
               w.payout_ref
        from project.ti_bonus_draw_winners w
                 join project.ti_bonus_draws d on d.id = w.draw_id
                 join project.ti_bonus_draw_prizes p on p.id = w.prize_id
                 left join project.places pl on pl.id = w.place_id
                 left join lateral (select coalesce(nullif(btrim(au.full_name), ''),
                                                    nullif(btrim(concat_ws(' ', au.first_name, au.second_name)), ''),
                                                    au.username)::varchar                      as name,
                                           coalesce(nullif(btrim(au.mobile_phone), ''), au.username)::varchar as phone
                                    from project.auth_users au
                                    where au.user_id = w.user_id
                                    order by au.updated_at desc nulls last, au.created_at desc nulls last
                                    limit 1) u on true
        where (nullif(btrim(p_payout_status), '') is null or w.payout_status = upper(btrim(p_payout_status)))
          and (nullif(btrim(p_audience), '') is null or d.audience = upper(btrim(p_audience)))
        order by (w.payout_status = 'PENDING') desc, d.drawn_at desc, w.round_no
        limit least(greatest(coalesce(p_limit, 100), 1), 1000) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;


-- Отметка выплаты: сумма, валюта, курс (необязательно), номер платёжки.
create or replace function project.ti_bonus_admin_winner_paid(p_admin uuid, p_winner_id uuid, p_paid_amount numeric,
                                                              p_paid_currency varchar, p_paid_rate numeric default null,
                                                              p_payout_ref varchar default null)
    returns table
            (
                id            uuid,
                payout_status varchar,
                paid_at       text,
                paid_amount   numeric,
                paid_currency varchar,
                paid_rate     numeric,
                payout_ref    varchar
            )
    language plpgsql
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    perform project.ti_bonus_winner_paid(p_winner_id, p_paid_amount, p_paid_currency, p_paid_rate, p_payout_ref, p_admin);
    return query
        select w.id,
               w.payout_status,
               to_char(w.paid_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
               w.paid_amount,
               w.paid_currency,
               w.paid_rate,
               w.payout_ref
        from project.ti_bonus_draw_winners w
        where w.id = p_winner_id;
end;
$$;


-- Сбои бонусной логики и cron розыгрышей, новые первыми.
create or replace function project.ti_bonus_admin_errors(p_admin uuid, p_limit integer default null)
    returns table
            (
                id         uuid,
                created_at text,
                source     varchar,
                payment_id uuid,
                message    text,
                detail     text
            )
    language plpgsql
    stable
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query
        select e.id,
               to_char(e.created_at at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI:SS'),
               e.source,
               e.payment_id,
               e.message,
               e.detail
        from project.ti_bonus_errors e
        order by e.created_at desc, e.id
        limit least(greatest(coalesce(p_limit, 100), 1), 1000);
end;
$$;


-- Состояние модуля одной строкой: курс, ключ random.org, розыгрыши, цепочка, сверка, сбои, фонды.
create or replace function project.ti_bonus_admin_health(p_admin uuid)
    returns table
            (
                usd_rate          numeric,
                usd_rate_date     text,
                rate_fresh        boolean,
                random_key_set    boolean,
                daily_draws       text,
                draws_waiting     integer,
                draws_with_errors integer,
                chain_ok          boolean,
                card_mismatches   integer,
                errors_24h        integer,
                fund_tourist_usd  numeric,
                fund_object_usd   numeric
            )
    language plpgsql
    stable
as
$$
begin
    perform project.ti_bonus_admin_check(p_admin);
    return query
        select r.rate,
               to_char(r.rate_date, 'YYYY-MM-DD'),
               coalesce(r.rate_date >= (now() at time zone 'Asia/Tashkent')::date - 7, false),
               project.ti_bonus_setting('random_org_api_key') is not null,
               coalesce(project.ti_bonus_setting('daily_draws'), ''),
               (select count(*)::integer
                from project.ti_bonus_draws x
                where (x.status = 'DRAFT' and x.period_to <= now())
                   or x.status = 'FROZEN'),
               (select count(*)::integer
                from project.ti_bonus_draws x
                where x.status in ('DRAFT', 'FROZEN')
                  and x.attributes ->> 'auto_error' is not null),
               coalesce((select bool_and(c.hash_ok and c.chain_ok and c.entries_ok)
                         from project.ti_bonus_draw_chain_check() c), true),
               (select count(*)::integer from project.ti_bonus_card_mismatches m),
               (select count(*)::integer from project.ti_bonus_errors e where e.created_at > now() - interval '24 hours'),
               (select round(b.balance_usd, 2) from project.ti_bonus_prize_fund_balance b where b.fund = 'TOURIST'),
               (select round(b.balance_usd, 2) from project.ti_bonus_prize_fund_balance b where b.fund = 'OBJECT')
        from (select 1) as one
                 left join lateral (select c.rate, c.rate_date
                                    from project.ti_currency_rates c
                                    where c.currency = 'USD'
                                    order by c.rate_date desc
                                    limit 1) r on true;
end;
$$;


-- =====================================================================================
-- 7. Первые ежедневные розыгрыши: на сегодня, по одному месту, приз 1 доллар (временно, для проверки)
-- =====================================================================================

select project.ti_bonus_draw_create_daily(a.audience, (now() at time zone 'Asia/Tashkent')::date, array [1]::numeric[])
from (values ('TOURIST'::varchar), ('OBJECT'::varchar)) as a(audience)
where not exists (select 1
                  from project.ti_bonus_draws x
                  where x.kind = 'DAILY'
                    and x.audience = a.audience);

commit;


-- =====================================================================================
-- Проверка после commit (только чтение)
-- =====================================================================================

-- две настройки: random_org_api_key без значения, daily_draws = TOURIST,OBJECT
select s.code, s.value is not null as has_value, case when s.code = 'daily_draws' then s.value end as daily_value
from project.ti_bonus_settings s
order by s.code;

-- ежедневные розыгрыши на сегодня: TOURIST и OBJECT, DRAFT, приз 1.00
select d.audience, d.kind, d.title, d.status, p.place_no, p.amount_usd
from project.ti_bonus_draws d
         join project.ti_bonus_draw_prizes p on p.draw_id = d.id
where d.kind = 'DAILY'
order by d.period_from desc, d.audience
limit 4;

-- новые функции на месте и принадлежат project (ожидается 29 строк, у всех owner = project)
select p.proname, pg_get_userbyid(p.proowner) as owner
from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'project'
  and p.proname in ('ti_bonus_setting', 'ti_bonus_is_admin', 'ti_bonus_admin_check', 'ti_bonus_parse_amounts',
                    'ti_bonus_parse_date', 'ti_bonus_try_jsonb', 'ti_bonus_draw_set_prizes', 'ti_bonus_fund_adjust',
                    'ti_bonus_winner_paid', 'ti_bonus_draw_prepare', 'ti_bonus_draw_finish', 'ti_bonus_draw_auto_error',
                    'ti_bonus_draw_daily_next', 'ti_bonus_draw_daily_finish', 'ti_bonus_draw_rows',
                    'ti_bonus_admin_draws', 'ti_bonus_admin_draw', 'ti_bonus_admin_draw_create',
                    'ti_bonus_admin_draw_prizes', 'ti_bonus_admin_draw_prepare', 'ti_bonus_admin_draw_finish',
                    'ti_bonus_admin_draw_cancel', 'ti_bonus_admin_fund', 'ti_bonus_admin_fund_ledger',
                    'ti_bonus_admin_fund_adjust', 'ti_bonus_admin_winners', 'ti_bonus_admin_winner_paid',
                    'ti_bonus_admin_errors', 'ti_bonus_admin_health')
order by p.proname;
