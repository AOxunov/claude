-- =====================================================================================
-- Тесты миграции 07. ТОЛЬКО ДЛЯ ЛОКАЛЬНОЙ КОПИИ: после 01-DDL.sql, 03-Тесты-локально.sql и
-- 07-Розыгрыши-cron-и-админка.sql (участники розыгрышей — из данных 03).
-- Всё в одной транзакции и в конце откатывается: база остаётся как после 03 и 07.
-- Запуск: psql -v ON_ERROR_STOP=1 -d microservice -f 07-Тесты-локально.sql
-- Первая неудачная проверка останавливает скрипт.
-- =====================================================================================

\set ON_ERROR_STOP 1
set client_min_messages = notice;

begin;

create schema if not exists ti_bonus_test;

create or replace function ti_bonus_test.ok(p_cond boolean, p_label text) returns void
    language plpgsql as
$$
begin
    if p_cond is distinct from true then
        raise exception 'FAIL: %', p_label;
    end if;
    raise notice 'ok: %', p_label;
end;
$$;

create or replace function ti_bonus_test.raises(p_sql text, p_label text) returns void
    language plpgsql as
$$
begin
    begin
        execute p_sql;
    exception
        when others then
            raise notice 'ok: % (ошибка: %)', p_label, sqlerrm;
            return;
    end;
    raise exception 'FAIL: % — ожидалась ошибка', p_label;
end;
$$;

-- ответ random.org для розыгрыша: числа и userData как в запросе
create or replace function ti_bonus_test.random_ok(p_draw uuid, p_data numeric[]) returns text
    language sql as
$$
select jsonb_build_object('jsonrpc', '2.0',
                          'result', jsonb_build_object('random', jsonb_build_object(
                                                               'method', 'generateSignedDecimalFractions',
                                                               'data', to_jsonb(p_data),
                                                               'userData', jsonb_build_object('draw_id', d.id, 'entries_hash', d.entries_hash),
                                                               'serialNumber', 7),
                                                       'signature', 'тест'),
                          'id', 1)::text
from project.ti_bonus_draws d
where d.id = p_draw
$$;

\set adm '00000000-0000-4000-8000-0000000000aa'
\set guest '00000000-0000-4000-8000-0000000000bb'
\set err401 '{"jsonrpc": "2.0", "error": {"code": 401, "message": "The API key you specified does not exist", "data": null}, "id": 1}'
select (now() at time zone 'Asia/Tashkent')::date as today \gset

create temp table cron_next
(
    step         integer,
    draw_id      uuid,
    audience     varchar,
    need_random  boolean,
    need_empty   boolean,
    n            integer,
    entries_hash varchar,
    api_key      text,
    created      integer,
    note         text
);
create temp table cron_fin
(
    step    integer,
    draw_id uuid,
    status  varchar,
    winners integer,
    note    text
);

-- ---------------------------------------------------------------- 1. Настройки, доступ, разбор входа
select ti_bonus_test.ok(project.ti_bonus_setting('random_org_api_key') is null
                            and project.ti_bonus_setting('daily_draws') = 'TOURIST,OBJECT',
                        'настройки: ключа random.org нет, ежедневные — туристам и объектам');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_check(%L)', :'guest'), 'не администратор — нет доступа');
select ti_bonus_test.raises('select project.ti_bonus_admin_check(null)', 'без пользователя — нет доступа');
do
$$
    begin
        perform project.ti_bonus_admin_check('00000000-0000-4000-8000-0000000000bb');
    exception
        when others then
            if sqlerrm not like '%00000000-0000-4000-8000-0000000000bb%' then
                raise exception 'FAIL: в тексте ошибки доступа нет id пользователя';
            end if;
            raise notice 'ok: в тексте ошибки доступа — id пользователя';
    end
$$;
insert into project.ti_bonus_admins (user_id, note) values (:'adm', 'тест');
select ti_bonus_test.ok(project.ti_bonus_is_admin(:'adm') and not project.ti_bonus_is_admin(:'guest')
                            and not project.ti_bonus_is_admin(null), 'администратор добавлен, остальные — нет');
update project.ti_bonus_admins set state = 0 where user_id = :'adm';
select ti_bonus_test.raises(format('select project.ti_bonus_admin_check(%L)', :'adm'), 'доступ снят (state = 0) — нет доступа');
update project.ti_bonus_admins set state = 1 where user_id = :'adm';

select ti_bonus_test.ok(project.ti_bonus_parse_amounts('[10, 5, 1.5]') = array [10, 5, 1.5]::numeric[], 'призы из JSON-массива');
select ti_bonus_test.ok(project.ti_bonus_parse_amounts(' 10 ,5 ') = array [10, 5]::numeric[], 'призы из строки');
select ti_bonus_test.ok(project.ti_bonus_parse_amounts('["3", "2"]') = array [3, 2]::numeric[], 'призы строками в JSON');
select ti_bonus_test.ok(project.ti_bonus_parse_amounts('') is null and project.ti_bonus_parse_amounts('[]') is null
                            and project.ti_bonus_parse_amounts(null) is null, 'призов нет — null');
select ti_bonus_test.raises($$select project.ti_bonus_parse_amounts('10, abc')$$, 'приз не число — ошибка');
select ti_bonus_test.raises($$select project.ti_bonus_parse_amounts('5, 0')$$, 'приз ноль — ошибка');
select ti_bonus_test.raises($$select project.ti_bonus_parse_amounts('1.234')$$, 'приз точнее центов — ошибка');
select ti_bonus_test.ok(project.ti_bonus_parse_date('2026-11-01') = date '2026-11-01'
                            and project.ti_bonus_parse_date('01.11.2026') = date '2026-11-01'
                            and project.ti_bonus_parse_date('2026-11-01T10:00:00Z') = date '2026-11-01'
                            and project.ti_bonus_parse_date(' ') is null, 'даты: 2026-11-01 и 01.11.2026');
select ti_bonus_test.raises($$select project.ti_bonus_parse_date('11/01/2026')$$, 'дата в другом виде — ошибка');
select ti_bonus_test.raises($$select project.ti_bonus_parse_date('2026-02-30')$$, 'несуществующая дата — ошибка');

-- ---------------------------------------------------------------- 2. Что создала миграция
select ti_bonus_test.ok((select count(*) = 1
                         from project.ti_bonus_draws x
                         where x.kind = 'DAILY'
                           and x.audience = 'OBJECT'
                           and x.status = 'DRAFT'
                           and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent'),
                        'миграция создала сегодняшний ежедневный объектам');
select ti_bonus_test.ok((select array_agg(p.amount_usd order by p.place_no)
                         from project.ti_bonus_draw_prizes p
                                  join project.ti_bonus_draws x on x.id = p.draw_id
                         where x.kind = 'DAILY'
                           and x.audience = 'OBJECT') = array [1.00]::numeric[], 'приз первого ежедневного — одно место на $1');
select ti_bonus_test.ok(not exists (select 1
                                    from project.ti_bonus_draws x
                                    where x.kind = 'DAILY'
                                      and x.audience = 'TOURIST'
                                      and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent'),
                        'туристам миграция не создавала: ежедневные у них уже были (из 03)');

-- ---------------------------------------------------------------- 3. Cron ежедневных розыгрышей
insert into cron_next select 1, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.created = 1 from cron_next c where c.step = 1), 'cron создал сегодняшний туристам');
select ti_bonus_test.ok((select array_agg(p.amount_usd order by p.place_no)
                         from project.ti_bonus_draw_prizes p
                                  join project.ti_bonus_draws x on x.id = p.draw_id
                         where x.kind = 'DAILY'
                           and x.audience = 'TOURIST'
                           and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent')
                            = array [1.00, 0.50]::numeric[],
                        'призы сегодняшнего — как у последнего ежедневного туристов');
select ti_bonus_test.ok((select c.draw_id = x.id and c.need_empty and not c.need_random and c.api_key is null
                         from cron_next c,
                              project.ti_bonus_draws x
                         where c.step = 1
                           and x.kind = 'DAILY'
                           and x.audience = 'TOURIST'
                           and x.period_from = (:'today'::date - 2)::timestamp at time zone 'Asia/Tashkent'),
                        'взят самый старый закончившийся (позавчера), участников нет');
insert into cron_fin select 1, f.* from (select * from cron_next where step = 1) c, lateral project.ti_bonus_draw_daily_finish(c.draw_id, null) f;
select ti_bonus_test.ok((select f.status = 'DONE' and f.winners = 0 from cron_fin f where f.step = 1),
                        'пустой ежедневный проведён без random.org');

insert into cron_next select 2, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.created = 0 and c.need_empty
                                and c.draw_id = (select x.id
                                                 from project.ti_bonus_draws x
                                                 where x.kind = 'DAILY'
                                                   and x.audience = 'TOURIST'
                                                   and x.period_from = (:'today'::date - 1)::timestamp at time zone 'Asia/Tashkent')
                         from cron_next c where c.step = 2), 'второй запуск: вчерашний, тоже пустой; новых не создано');
insert into cron_fin select 2, f.* from (select * from cron_next where step = 2) c, lateral project.ti_bonus_draw_daily_finish(c.draw_id, null) f;

insert into cron_next select 3, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.draw_id is null and not c.need_random and not c.need_empty and c.created = 0
                         from cron_next c where c.step = 3), 'третий запуск: делать нечего');

-- закончившийся ежедневный с участниками (период накрывает данные 03)
select project.ti_bonus_draw_create('TOURIST', now() - interval '120 days', now(), array [1],
                                    'Тест: ежедневный с участниками', 'DAILY') as dd \gset
insert into cron_next select 4, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.draw_id = :'dd' and not c.need_random and not c.need_empty and c.note like '%нет ключа%'
                         from cron_next c where c.step = 4), 'нет ключа random.org — cron не падает, ошибка в note');
select ti_bonus_test.ok((select x.status = 'FROZEN' and x.prizes_count = 1 and x.attributes ->> 'auto_error' like '%нет ключа%'
                                and (x.attributes ->> 'retry_at')::timestamptz = now() + interval '1 hour'
                         from project.ti_bonus_draws x where x.id = :'dd'),
                        'розыгрыш зафиксирован, ошибка и время повтора — в attributes');
select ti_bonus_test.ok((select count(*) = 1 from project.ti_bonus_errors e
                         where e.source = 'draw_daily' and e.detail = 'draw_id=' || :'dd'), 'ошибка записана в ti_bonus_errors');

insert into cron_next select 5, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.draw_id is null from cron_next c where c.step = 5), 'до времени повтора розыгрыш пропускается');

update project.ti_bonus_settings set value = 'test-key', updated_at = now() where code = 'random_org_api_key';
update project.ti_bonus_draws set attributes = (attributes::jsonb - 'retry_at')::json where id = :'dd';
insert into cron_next select 6, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.draw_id = :'dd' and c.need_random and not c.need_empty and c.n = 1 and c.api_key = 'test-key'
                                and c.entries_hash = (select x.entries_hash from project.ti_bonus_draws x where x.id = :'dd')
                         from cron_next c where c.step = 6), 'ключ есть — запрос к random.org: n = 1, entries_hash, ключ');

insert into cron_fin select 6, f.* from project.ti_bonus_draw_daily_finish(:'dd', :'err401') f;
select ti_bonus_test.ok((select f.status = 'FROZEN' and f.winners = 0 and f.note like '%random.org вернул ошибку 401%'
                         from cron_fin f where f.step = 6), 'ошибка random.org — cron не падает, розыгрыш ждёт');
select ti_bonus_test.ok((select x.attributes ->> 'auto_error' like '%ошибку 401%' and x.attributes ->> 'retry_at' is not null
                         from project.ti_bonus_draws x where x.id = :'dd'), 'ошибка random.org — в attributes');

update project.ti_bonus_draws set attributes = (attributes::jsonb - 'retry_at')::json where id = :'dd';
insert into cron_next select 7, * from project.ti_bonus_draw_daily_next();
insert into cron_fin
select 7, f.*
from (select * from cron_next where step = 7 and need_random) c,
     lateral project.ti_bonus_draw_daily_finish(c.draw_id, ti_bonus_test.random_ok(c.draw_id, array [0.5])) f;
select ti_bonus_test.ok((select f.draw_id = :'dd' and f.status = 'DONE' and f.winners = 1 from cron_fin f where f.step = 7),
                        'ответ random.org — проведён, один победитель');
select ti_bonus_test.ok((select w.ticket = floor(0.5 * x.total_weight_cents) + 1
                         from project.ti_bonus_draw_winners w
                                  join project.ti_bonus_draws x on x.id = w.draw_id
                         where w.draw_id = :'dd'), 'билет победителя: ⌊0,5 × сумма весов⌋ + 1');

select project.ti_bonus_draw_create('TOURIST', now() - interval '119 days', now(), array [100000],
                                    'Тест: ежедневный без фонда', 'DAILY') as dbig \gset
insert into cron_next select 8, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.draw_id = :'dbig' and not c.need_random and not c.need_empty and c.note like '%фиксация: В фонде%'
                         from cron_next c where c.step = 8), 'фонда не хватает — cron не падает');
select ti_bonus_test.ok((select x.status = 'DRAFT' and x.attributes ->> 'auto_error' like '%В фонде%'
                                and not exists (select 1 from project.ti_bonus_draw_entries e where e.draw_id = x.id)
                         from project.ti_bonus_draws x where x.id = :'dbig'), 'розыгрыш остался черновиком без участников');

select project.ti_bonus_draw_cancel(x.id, 'тест: отмена дня')
from project.ti_bonus_draws x
where x.kind = 'DAILY'
  and x.audience = 'TOURIST'
  and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent';
insert into cron_next select 9, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.created = 0 from cron_next c where c.step = 9)
                            and not exists (select 1
                                            from project.ti_bonus_draws x
                                            where x.kind = 'DAILY'
                                              and x.audience = 'TOURIST'
                                              and x.status <> 'CANCELLED'
                                              and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent'),
                        'отменённый день cron заново не создаёт');

-- пауза объектам: сегодняшний удалён, за позапрошлые сутки есть другой с призом $2
update project.ti_bonus_settings set value = 'TOURIST' where code = 'daily_draws';
delete from project.ti_bonus_draw_prizes p using project.ti_bonus_draws x
where p.draw_id = x.id and x.kind = 'DAILY' and x.audience = 'OBJECT';
delete from project.ti_bonus_draws x where x.kind = 'DAILY' and x.audience = 'OBJECT';
select project.ti_bonus_draw_create_daily('OBJECT', :'today'::date - 3, array [2]) as dobj \gset
insert into cron_next select 10, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.created = 0 from cron_next c where c.step = 10), 'пауза: объектам сегодняшний не создан');
update project.ti_bonus_settings set value = 'TOURIST, OBJECT' where code = 'daily_draws';
insert into cron_next select 11, * from project.ti_bonus_draw_daily_next();
select ti_bonus_test.ok((select c.created = 1 from cron_next c where c.step = 11)
                            and (select array_agg(p.amount_usd order by p.place_no)
                                 from project.ti_bonus_draw_prizes p
                                          join project.ti_bonus_draws x on x.id = p.draw_id
                                 where x.kind = 'DAILY'
                                   and x.audience = 'OBJECT'
                                   and x.period_from = (:'today'::date)::timestamp at time zone 'Asia/Tashkent')
                            = array [2.00]::numeric[],
                        'пауза снята (с пробелом в настройке): объектам создан, приз — как у последнего');

-- ---------------------------------------------------------------- 4. Админка: розыгрыш за период
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draws(%L)', :'guest'), 'список — не администратору нельзя');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_draw(%L, %L)', :'guest', :'dd'), 'розыгрыш — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, %L, %L)', :'guest',
                                   'TOURIST', '2026-01-01', '2026-01-31', '[1]'), 'создать — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_prepare(%L, %L)', :'guest', :'dbig'),
                            'провести — не администратору нельзя');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_draw_finish(%L, %L, null)', :'guest', :'dbig'),
                            'итог — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_cancel(%L, %L, %L)', :'guest', :'dbig', 'x'),
                            'отменить — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund(%L)', :'guest'), 'фонд — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, 1, %L)', :'guest', 'TOURIST', 'x'),
                            'ADJUST — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_winners(%L)', :'guest'), 'победители — не администратору нельзя');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_health(%L)', :'guest'), 'состояние — не администратору нельзя');

select r.id as dp, r.status as dp_status, r.prizes as dp_prizes, r.prizes_usd as dp_total, r.date_from as dp_from, r.date_to as dp_to
from project.ti_bonus_admin_draw_create(:'adm', 'tourist', (:'today'::date - 120)::text, to_char(:'today'::date - 1, 'DD.MM.YYYY'),
                                        '[3, 2]', 'Тест: период') r \gset
select ti_bonus_test.ok(:'dp_status' = 'DRAFT' and :'dp_prizes' = '3.00 + 2.00' and :'dp_total' = '5.00'
                            and :'dp_from' = (:'today'::date - 120)::text and :'dp_to' = (:'today'::date - 1)::text,
                        'розыгрыш за период создан: даты по Ташкенту, конец включительно, призы $3 + $2');
select ti_bonus_test.ok((select x.period_to = (:'today'::date)::timestamp at time zone 'Asia/Tashkent' and x.created_by = :'adm'
                         from project.ti_bonus_draws x where x.id = :'dp'), 'период до полуночи следующего дня, создал администратор');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, %L, %L)', :'adm', 'GUESTS',
                                   '2026-01-01', '2026-01-31', '[1]'), 'неизвестная аудитория — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, %L, %L)', :'adm', 'TOURIST',
                                   '2026-01-31', '2026-01-01', '[1]'), 'конец раньше начала — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, %L, %L)', :'adm', 'TOURIST',
                                   '2026-01-01', '2026-01-31', '[]'), 'без призов — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, %L, %L, null, %L)', :'adm',
                                   'TOURIST', '2026-01-01', null, '[1]', 'WEEKLY'), 'неизвестный вид — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_create(%L, %L, %L, null, %L, null, %L)', :'adm',
                                   'OBJECT', :'today', '[1]', 'DAILY'), 'ежедневный за день, где он уже есть — ошибка');
select r.id as dnext, r.kind as dnext_kind, r.date_from as dnext_from
from project.ti_bonus_admin_draw_create(:'adm', 'OBJECT', (:'today'::date + 1)::text, null, '4', null, 'daily') r \gset
select ti_bonus_test.ok(:'dnext_kind' = 'DAILY' and :'dnext_from' = (:'today'::date + 1)::text,
                        'ежедневный на завтра создан из админки');

select ti_bonus_test.ok((select r.prizes = '4.00 + 1.00' from project.ti_bonus_admin_draw_prizes(:'adm', :'dp', '4, 1') r),
                        'призы черновика изменены');
select ti_bonus_test.ok((select count(*) = 1 from project.ti_bonus_admin_draws(:'adm', 'TOURIST', 'period', 'DRAFT') r where r.id = :'dp')
                            and (select count(*) = 0 from project.ti_bonus_admin_draws(:'adm', 'OBJECT') r where r.id = :'dp'),
                        'список: фильтры по аудитории, виду и статусу');
select ti_bonus_test.ok((select count(*) = 2 from project.ti_bonus_admin_draws(:'adm', null, null, null, 2, 0))
                            and (select count(*) = 1 from project.ti_bonus_admin_draws(:'adm', '', '', '', 1, 1)),
                        'список: limit и offset, пустые фильтры — без фильтра');

-- без ключа при участниках — ошибка, розыгрыш остаётся черновиком
update project.ti_bonus_settings set value = '' where code = 'random_org_api_key';
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_prepare(%L, %L)', :'adm', :'dp'),
                            'проведение без ключа random.org — ошибка');
select ti_bonus_test.ok((select x.status = 'DRAFT' from project.ti_bonus_draws x where x.id = :'dp'), 'после ошибки — снова черновик');
update project.ti_bonus_settings set value = 'test-key' where code = 'random_org_api_key';

select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_prepare(%L, %L)', :'adm', :'dnext'),
                            'период не закончился — провести нельзя');

select r.need_random as pr_random, r.need_empty as pr_empty, r.n as pr_n, r.api_key as pr_key, r.status as pr_status,
       r.entries_count as pr_entries, r.prizes_count as pr_prizes
from project.ti_bonus_admin_draw_prepare(:'adm', :'dp') r \gset
select ti_bonus_test.ok(:'pr_random' = 't' and :'pr_empty' = 'f' and :'pr_status' = 'FROZEN' and :pr_entries >= 1
                            and :pr_prizes = least(2, :pr_entries) and :pr_n = :pr_prizes and :'pr_key' = 'test-key',
                        'подготовка: зафиксирован, нужен random.org, n = числу мест, ключ из настроек');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_prizes(%L, %L, %L)', :'adm', :'dp', '1'),
                            'после фиксации призы не меняются');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_draw_finish(%L, %L, %L)', :'adm', :'dp', :'err401'),
                            'ответ random.org с ошибкой — ошибка с её текстом');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_draw_finish(%L, %L, %L)', :'adm', :'dp', 'не json'),
                            'ответ random.org не JSON — ошибка');
select ti_bonus_test.ok(project.ti_bonus_admin_draw_finish(:'adm', :'dp', ti_bonus_test.random_ok(:'dp', array [0.1, 0.9])) = :pr_prizes,
                        'итог: победителей столько, сколько мест');
select ti_bonus_test.ok((select x.status = 'DONE' and x.hash is not null from project.ti_bonus_draws x where x.id = :'dp'),
                        'розыгрыш проведён, хеш цепочки есть');

select project.ti_bonus_admin_draw(:'adm', :'dp') as dp_json \gset
select ti_bonus_test.ok((select j ->> 'status' = 'DONE'
                                and jsonb_array_length(j -> 'prizes') = 2
                                and jsonb_array_length(j -> 'winners') = :pr_prizes
                                and j #>> '{winners,0,payout_status}' = 'PENDING'
                                and j #>> '{random,serialNumber}' = '7'
                                and j ->> 'signature' = 'тест'
                                and j ->> 'date_to' = (:'today'::date - 1)::text
                         from (select (:'dp_json')::jsonb as j) t), 'карточка розыгрыша: призы, победители, ответ random.org');
select ti_bonus_test.raises(format('select project.ti_bonus_admin_draw(%L, %L)', :'adm', '00000000-0000-4000-8000-000000000000'),
                            'карточка несуществующего — ошибка');

select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_cancel(%L, %L, %L)', :'adm', :'dp', 'x'),
                            'проведённый не отменить');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_draw_cancel(%L, %L, %L)', :'adm', :'dnext', ' '),
                            'отмена без причины — ошибка');
-- проверка строки — отдельным запросом: запрос видит данные на момент своего начала
select ti_bonus_test.ok((select r.status = 'CANCELLED' from project.ti_bonus_admin_draw_cancel(:'adm', :'dnext', 'тест: не нужен') r),
                        'отмена с причиной');
select ti_bonus_test.ok((select x.attributes ->> 'cancel_reason' = 'тест: не нужен' and x.updated_by = :'adm'
                         from project.ti_bonus_draws x where x.id = :'dnext'), 'в розыгрыше — причина и кто отменил');

-- ---------------------------------------------------------------- 5. Админка: фонд
select balance_usd as t_before from project.ti_bonus_prize_fund_balance where fund = 'TOURIST' \gset
select ti_bonus_test.ok((select count(*) = 2 and bool_and(r.date_from = to_char(date_trunc('month', :'today'::date), 'YYYY-MM-DD')
                                                          and r.date_to = :'today')
                         from project.ti_bonus_admin_fund(:'adm') r)
                            and (select r.fund = 'TOURIST' and r.balance_usd = round(:t_before, 2)
                                 from project.ti_bonus_admin_fund(:'adm') r limit 1),
                        'фонды: две строки, период по умолчанию — с начала месяца по сегодня');
select ti_bonus_test.ok((select r.period_collected_usd = round(b.collected_usd, 2)
                         from project.ti_bonus_admin_fund(:'adm', '2000-01-01', (:'today'::date + 1)::text) r
                                  join project.ti_bonus_prize_fund_balance b on b.fund = r.fund
                         where r.fund = 'OBJECT'), 'собрано за весь период = собрано всего');
select ti_bonus_test.ok((select r.planned_prizes_usd = (select coalesce(sum(p.amount_usd), 0)
                                                        from project.ti_bonus_draws x
                                                                 join project.ti_bonus_draw_prizes p on p.draw_id = x.id
                                                        where x.audience = 'TOURIST' and x.status = 'DRAFT')
                                and r.free_usd = r.balance_usd - r.planned_prizes_usd
                         from project.ti_bonus_admin_fund(:'adm') r where r.fund = 'TOURIST'), 'запланировано в черновиках и свободно');

select ti_bonus_test.ok((select r.balance_usd = round(:t_before - 1.5, 2)
                         from project.ti_bonus_admin_fund_adjust(:'adm', 'tourist', -1.5, 'тест: на рекламу') r),
                        'ADJUST −$1.50: новый остаток');
select ti_bonus_test.ok((select l.op_type = 'ADJUST' and l.amount_usd = -1.5 and l.comment = 'тест: на рекламу' and l.created_by = :'adm'
                         from project.ti_bonus_admin_fund_ledger(:'adm', 'TOURIST', 'adjust', 1) l), 'журнал фонда: строка ADJUST с автором');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, %s, %L)', :'adm', 'TOURIST',
                                   -(round(:t_before, 2) + 100), 'x'), 'списать больше остатка — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, 0, %L)', :'adm', 'TOURIST', 'x'),
                            'ноль — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, 1.234, %L)', :'adm', 'TOURIST', 'x'),
                            'точнее центов — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, 1, %L)', :'adm', 'TOURIST', ' '),
                            'без комментария — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_fund_adjust(%L, %L, 1, %L)', :'adm', 'ALL', 'x'),
                            'неизвестный фонд — ошибка');

-- ---------------------------------------------------------------- 6. Админка: выплаты, сбои, состояние
select ti_bonus_test.ok((select count(*) = :pr_prizes from project.ti_bonus_admin_winners(:'adm', 'pending', 'TOURIST') w
                         where w.draw_id = :'dp')
                            and (select count(*) = 0 from project.ti_bonus_admin_winners(:'adm', null, 'OBJECT') w where w.draw_id = :'dp'),
                        'победители розыгрыша — к выплате, фильтры работают');
select w.id as win1 from project.ti_bonus_admin_winners(:'adm', 'PENDING') w where w.draw_id = :'dp' and w.place_no = 1 \gset
select ti_bonus_test.ok((select r.payout_status = 'PAID' and r.paid_amount = 50601.72 and r.paid_currency = 'UZS'
                                and r.payout_ref = 'тест-1'
                         from project.ti_bonus_admin_winner_paid(:'adm', :'win1', 50601.72, 'uzs', 12650.43, ' тест-1 ') r),
                        'выплата отмечена');
select ti_bonus_test.ok((select x.updated_by = :'adm' from project.ti_bonus_draw_winners x where x.id = :'win1'), 'отметил администратор');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_winner_paid(%L, %L, 1, %L)', :'adm', :'win1', 'UZS'),
                            'повторная выплата — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_winner_paid(%L, %L, 0, %L)', :'adm',
                                   (select w.id from project.ti_bonus_draw_winners w where w.draw_id = :'dp' and w.payout_status = 'PENDING' limit 1),
                                   'UZS'), 'выплата ноль — ошибка');
select ti_bonus_test.raises(format('select * from project.ti_bonus_admin_winner_paid(%L, %L, 1, %L)', :'adm',
                                   (select w.id from project.ti_bonus_draw_winners w where w.draw_id = :'dp' and w.payout_status = 'PENDING' limit 1),
                                   'SUMS'), 'валюта не из трёх букв — ошибка');

select ti_bonus_test.ok((select count(*) >= 3 from project.ti_bonus_admin_errors(:'adm', 50) e where e.source = 'draw_daily'),
                        'сбои: ошибки cron розыгрышей видны');
select ti_bonus_test.ok((select h.random_key_set and h.chain_ok and h.card_mismatches = 0 and h.daily_draws = 'TOURIST, OBJECT'
                                and h.usd_rate = 12650.43 and h.rate_fresh and h.draws_with_errors >= 1
                         from project.ti_bonus_admin_health(:'adm') h), 'состояние: ключ есть, цепочка сходится, сверка чистая');
select ti_bonus_test.ok((select bool_and(c.hash_ok and c.chain_ok and c.entries_ok) from project.ti_bonus_draw_chain_check() c),
                        'итог: цепочка всех розыгрышей сходится');
select ti_bonus_test.ok(not exists (select 1 from project.ti_bonus_card_mismatches), 'итог: кеш остатков совпадает с журналом');

\echo '=== ВСЕ ПРОВЕРКИ 07 ПРОЙДЕНЫ ==='
rollback;
