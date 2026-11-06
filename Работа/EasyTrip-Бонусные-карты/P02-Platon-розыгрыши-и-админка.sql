-- =====================================================================================
-- Platon, 06.11.2026 (P02): розыгрыши бонусных карт — cron ежедневных и API админки.
--
-- База — platon, не microservice. Сначала в microservice должна быть миграция
-- 07-Розыгрыши-cron-и-админка.sql: стадии вызывают её функции.
--
-- Эндпоинты (15, стадий 25):
--   POST  v1/ti/bonus/draws/daily              basic
--   GET   v1/ti/bonus/admin/me                 bearer
--   GET   v1/ti/bonus/admin/draws              bearer
--   GET   v1/ti/bonus/admin/draw               bearer
--   POST  v1/ti/bonus/admin/draw/create        bearer
--   POST  v1/ti/bonus/admin/draw/prizes        bearer
--   POST  v1/ti/bonus/admin/draw/run           bearer
--   POST  v1/ti/bonus/admin/draw/cancel        bearer
--   GET   v1/ti/bonus/admin/fund               bearer
--   GET   v1/ti/bonus/admin/fund/ledger        bearer
--   POST  v1/ti/bonus/admin/fund/adjust        bearer
--   GET   v1/ti/bonus/admin/winners            bearer
--   POST  v1/ti/bonus/admin/winner/paid        bearer
--   GET   v1/ti/bonus/admin/errors             bearer
--   GET   v1/ti/bonus/admin/health             bearer
--
--   POST v1/ti/bonus/draws/daily — для cron TiBonusDrawsDaily (каждые 10 минут, в 5, 15, ... 55):
--     создаёт сегодняшние ежедневные розыгрыши и проводит один закончившийся. Участников нет —
--     без random.org; есть — запрос generateSignedDecimalFractions. Ошибка розыгрыша (нет ключа,
--     нет денег в фонде, ответ random.org с ошибкой) cron не роняет: она пишется в розыгрыш и
--     ti_bonus_errors, повтор через час.
--   v1/ti/bonus/admin/* — для админки, bearer. Каждая функция в microservice сама проверяет, что
--     пользователь есть в ti_bonus_admins; свой id показывает GET v1/ti/bonus/admin/me.
--     Розыгрыш за период проводится вручную: create → (prizes) → run.
--
-- Запуск: DataGrip, консоль на базе platon → весь файл (Ctrl+A, Ctrl+Enter). Повторный запуск
-- ничего не задвоит: эндпоинт с тем же методом и путём и задача с тем же именем пропускаются.
--
-- Как устроено:
--   * id — отрицательные, ниже текущего минимума, как в P01;
--   * cron-эндпоинт — basic, заголовок Authorization задачи копируется из TokenUpdater (как в P01);
--   * ключ random.org в стадиях не хранится: его отдаёт стадия prep из ti_bonus_settings (microservice);
--   * подстановки платформы (двоеточие, решётка, доллар перед именем) в JSON записаны escape-ами
--     \u003a, \u0023, \u0024, а в access_condition — через chr(58), чтобы DataGrip не принял их за
--     свои параметры. В базе это обычные символы — их покажет проверка в конце файла;
--   * стадии random и run выполняются, только если prep.need_random, стадия run_empty — если
--     prep.need_empty (access_condition);
--   * ответ со вложенными данными (розыгрыш целиком) — как у v1/hotels: SQL-стадия отдаёт jsonb,
--     JS-стадия _body делает JSON.parse(variables.draw.value);
--   * has_transaction = true у эндпоинтов, которые пишут: при ошибке на любой стадии ничего не
--     сохранится (у проведения из админки розыгрыш останется черновиком).
-- =====================================================================================

begin;

-- 1. Эндпоинты
insert into api_endpoints (id, state, version, created_at, attributes, method, path, auth_handler,
                           has_transaction, group_by, result_cached_seconds, note)
select (select least(min(id), 0) from api_endpoints) - row_number() over (order by v.ord),
       1, 1, now(), '{}', v.method, v.path, v.auth, v.tx, v.grp, 0, v.note
from (values (1, 'POST', 'v1/ti/bonus/draws/daily', 'basic', true, 'Bonus cards (Mutalib)', 'Бонусные карты: ежедневные розыгрыши — создать сегодняшние, провести закончившийся через random.org. Вызывает cron TiBonusDrawsDaily'),
             (2, 'GET', 'v1/ti/bonus/admin/me', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: кто я и есть ли доступ (id — для ti_bonus_admins)'),
             (3, 'GET', 'v1/ti/bonus/admin/draws', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: список розыгрышей (audience, kind, status, limit, offset)'),
             (4, 'GET', 'v1/ti/bonus/admin/draw', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: розыгрыш целиком — призы, победители, ответ random.org (id)'),
             (5, 'POST', 'v1/ti/bonus/admin/draw/create', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: новый розыгрыш (audience, date_from, date_to, prizes, title, kind)'),
             (6, 'POST', 'v1/ti/bonus/admin/draw/prizes', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: новые призы черновика (id, prizes)'),
             (7, 'POST', 'v1/ti/bonus/admin/draw/run', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: провести розыгрыш — фиксация, random.org, победители (id)'),
             (8, 'POST', 'v1/ti/bonus/admin/draw/cancel', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: отменить розыгрыш до проведения (id, reason)'),
             (9, 'GET', 'v1/ti/bonus/admin/fund', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: фонды — остатки и движения за период (date_from, date_to)'),
             (10, 'GET', 'v1/ti/bonus/admin/fund/ledger', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: движения фонда (fund, op_type, limit, offset)'),
             (11, 'POST', 'v1/ti/bonus/admin/fund/adjust', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: пополнение или списание фонда ADJUST (fund, amount_usd, comment)'),
             (12, 'GET', 'v1/ti/bonus/admin/winners', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: победители и выплаты (payout_status, audience, limit, offset)'),
             (13, 'POST', 'v1/ti/bonus/admin/winner/paid', 'bearer', true, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: отметить выплату (id, paid_amount, paid_currency, paid_rate, payout_ref)'),
             (14, 'GET', 'v1/ti/bonus/admin/errors', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: сбои бонусов и cron розыгрышей (limit)'),
             (15, 'GET', 'v1/ti/bonus/admin/health', 'bearer', false, 'Bonus cards admin (Mutalib)', 'Бонусные карты, админка: состояние модуля — курс, ключ random.org, розыгрыши, цепочка, сверка, фонды'))
         as v(ord, method, path, auth, tx, grp, note)
where not exists (select 1 from api_endpoints e where e.method = v.method and e.path = v.path);

-- 2. Стадии
insert into api_stages (id, endpoint_id, sort_order, alias, handler, serialize_result, state, version, created_at,
                        attributes, access_condition)
select (select least(min(id), 0) from api_stages) - row_number() over (order by s.ord),
       e.id, s.sort_order, s.alias, s.handler, true, 1, 1, now(), s.attributes::json, s.cond
from api_endpoints e
         join (values (1, 'POST', 'v1/ti/bonus/draws/daily', 10, 'prep', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_draw_daily_next()"}',
                       null::varchar),
                      (2, 'POST', 'v1/ti/bonus/draws/daily', 20, 'random', 'http_request_handler',
                       '{"resource_url": "https://api.random.org/json-rpc/4/invoke", "http_method": "POST", "content_type": "application/json", "request_body": "{\"jsonrpc\": \"2.0\", \"method\": \"generateSignedDecimalFractions\", \"params\": {\"apiKey\": \"\u003aprep.api_key\", \"n\": \u003aprep.n, \"decimalPlaces\": 14, \"replacement\": true, \"userData\": {\"draw_id\": \"\u003aprep.draw_id\", \"entries_hash\": \"\u003aprep.entries_hash\"}}, \"id\": 1}", "http_headers": {"Accept": "application/json"}, "http_request_response": "false"}',
                       (chr(58) || 'prep.need_random')::varchar),
                      (3, 'POST', 'v1/ti/bonus/draws/daily', 30, 'run', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_draw_daily_finish(\u003aprep.draw_id::uuid, \u003arandom::text)"}',
                       (chr(58) || 'prep.need_random')::varchar),
                      (4, 'POST', 'v1/ti/bonus/draws/daily', 40, 'run_empty', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_draw_daily_finish(\u003aprep.draw_id::uuid, null)"}',
                       (chr(58) || 'prep.need_empty')::varchar),
                      (5, 'POST', 'v1/ti/bonus/draws/daily', 50, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select \u003aprep.draw_id::uuid as draw_id, \u003aprep.audience::varchar as audience, \u003aprep.created::integer as created,\n       \u003aprep.note::text as note, d.status, d.entries_count, d.prizes_count,\n       case when d.status in (''DRAFT'', ''FROZEN'') then d.attributes ->> ''auto_error'' end as error\nfrom (select 1) as one\n         left join project.ti_bonus_draws d on d.id = \u003aprep.draw_id::uuid"}',
                       null::varchar),
                      (6, 'GET', 'v1/ti/bonus/admin/me', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select \u0024user.id::uuid as user_id, \u0024user.username::varchar as username,\n       project.ti_bonus_is_admin(\u0024user.id::uuid) as is_admin"}',
                       null::varchar),
                      (7, 'GET', 'v1/ti/bonus/admin/draws', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "list", "sql": "select * from project.ti_bonus_admin_draws(\u0024user.id::uuid, \u0023audience::varchar, \u0023kind::varchar, \u0023status::varchar,\n                                           \u0023limit::integer, \u0023offset::integer)"}',
                       null::varchar),
                      (8, 'GET', 'v1/ti/bonus/admin/draw', 10, 'draw', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "object", "sql": "select project.ti_bonus_admin_draw(\u0024user.id::uuid, \u0023id::uuid)"}',
                       null::varchar),
                      (9, 'GET', 'v1/ti/bonus/admin/draw', 20, '_body', 'js_eval_handler',
                       '{"js_eval": "{\"code\":\"return JSON.parse(variables.draw.value)\",\"es5\":\"return (function(){return JSON.parse(variables.draw.value)})();\"}"}',
                       null::varchar),
                      (10, 'POST', 'v1/ti/bonus/admin/draw/create', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_draw_create(\u0024user.id::uuid, \u0023audience::varchar, \u0023date_from::text, \u0023date_to::text,\n                                                 \u0023prizes::text, \u0023title::varchar, \u0023kind::varchar)"}',
                       null::varchar),
                      (11, 'POST', 'v1/ti/bonus/admin/draw/prizes', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_draw_prizes(\u0024user.id::uuid, \u0023id::uuid, \u0023prizes::text)"}',
                       null::varchar),
                      (12, 'POST', 'v1/ti/bonus/admin/draw/run', 10, 'prep', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_draw_prepare(\u0024user.id::uuid, \u0023id::uuid)"}',
                       null::varchar),
                      (13, 'POST', 'v1/ti/bonus/admin/draw/run', 20, 'random', 'http_request_handler',
                       '{"resource_url": "https://api.random.org/json-rpc/4/invoke", "http_method": "POST", "content_type": "application/json", "request_body": "{\"jsonrpc\": \"2.0\", \"method\": \"generateSignedDecimalFractions\", \"params\": {\"apiKey\": \"\u003aprep.api_key\", \"n\": \u003aprep.n, \"decimalPlaces\": 14, \"replacement\": true, \"userData\": {\"draw_id\": \"\u003aprep.draw_id\", \"entries_hash\": \"\u003aprep.entries_hash\"}}, \"id\": 1}", "http_headers": {"Accept": "application/json"}, "http_request_response": "false"}',
                       (chr(58) || 'prep.need_random')::varchar),
                      (14, 'POST', 'v1/ti/bonus/admin/draw/run', 30, 'run', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "object", "sql": "select project.ti_bonus_admin_draw_finish(\u0024user.id::uuid, \u003aprep.draw_id::uuid, \u003arandom::text)"}',
                       (chr(58) || 'prep.need_random')::varchar),
                      (15, 'POST', 'v1/ti/bonus/admin/draw/run', 40, 'run_empty', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "object", "sql": "select project.ti_bonus_admin_draw_finish(\u0024user.id::uuid, \u003aprep.draw_id::uuid, null)"}',
                       (chr(58) || 'prep.need_empty')::varchar),
                      (16, 'POST', 'v1/ti/bonus/admin/draw/run', 50, 'draw', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "object", "sql": "select project.ti_bonus_admin_draw(\u0024user.id::uuid, \u003aprep.draw_id::uuid)"}',
                       null::varchar),
                      (17, 'POST', 'v1/ti/bonus/admin/draw/run', 60, '_body', 'js_eval_handler',
                       '{"js_eval": "{\"code\":\"return JSON.parse(variables.draw.value)\",\"es5\":\"return (function(){return JSON.parse(variables.draw.value)})();\"}"}',
                       null::varchar),
                      (18, 'POST', 'v1/ti/bonus/admin/draw/cancel', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_draw_cancel(\u0024user.id::uuid, \u0023id::uuid, \u0023reason::varchar)"}',
                       null::varchar),
                      (19, 'GET', 'v1/ti/bonus/admin/fund', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "list", "sql": "select * from project.ti_bonus_admin_fund(\u0024user.id::uuid, \u0023date_from::text, \u0023date_to::text)"}',
                       null::varchar),
                      (20, 'GET', 'v1/ti/bonus/admin/fund/ledger', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "list", "sql": "select * from project.ti_bonus_admin_fund_ledger(\u0024user.id::uuid, \u0023fund::varchar, \u0023op_type::varchar,\n                                                 \u0023limit::integer, \u0023offset::integer)"}',
                       null::varchar),
                      (21, 'POST', 'v1/ti/bonus/admin/fund/adjust', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_fund_adjust(\u0024user.id::uuid, \u0023fund::varchar, \u0023amount_usd::numeric, \u0023comment::varchar)"}',
                       null::varchar),
                      (22, 'GET', 'v1/ti/bonus/admin/winners', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "list", "sql": "select * from project.ti_bonus_admin_winners(\u0024user.id::uuid, \u0023payout_status::varchar, \u0023audience::varchar,\n                                             \u0023limit::integer, \u0023offset::integer)"}',
                       null::varchar),
                      (23, 'POST', 'v1/ti/bonus/admin/winner/paid', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_winner_paid(\u0024user.id::uuid, \u0023id::uuid, \u0023paid_amount::numeric, \u0023paid_currency::varchar,\n                                                 \u0023paid_rate::numeric, \u0023payout_ref::varchar)"}',
                       null::varchar),
                      (24, 'GET', 'v1/ti/bonus/admin/errors', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "list", "sql": "select * from project.ti_bonus_admin_errors(\u0024user.id::uuid, \u0023limit::integer)"}',
                       null::varchar),
                      (25, 'GET', 'v1/ti/bonus/admin/health', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select * from project.ti_bonus_admin_health(\u0024user.id::uuid)"}',
                       null::varchar))
    as s(ord, method, path, sort_order, alias, handler, attributes, cond) on s.method = e.method and s.path = e.path
where not exists (select 1 from api_stages x where x.endpoint_id = e.id);

-- 3. Задача cron
insert into cron_schedules (id, state, version, created_at, name, group_by, code_type, methods, url,
                            cron_expression, datasource, content_type, log_level, attempt_count, attributes, details)
select (select least(min(id), 0) from cron_schedules) - row_number() over (order by v.ord),
       1, 1, now(), v.name, 'Bonus cards (Mutalib)', 'REQUEST', 'POST', v.url,
       v.cron, 'project', 'application/json', 'ERROR', 1,
       json_build_object('header', json_build_object('Authorization', t.attributes -> 'header' ->> 'Authorization'),
                         'js_eval', null),
       '{}'
from (values (1, 'TiBonusDrawsDaily', 'v1/ti/bonus/draws/daily', '5,15,25,35,45,55 * * * *')) as v(ord, name, url, cron)
         join cron_schedules t on t.name = 'TokenUpdater'
where not exists (select 1 from cron_schedules c where c.name = v.name);

commit;

-- Проверка 1: 15 эндпоинтов, всего 25 стадий
select e.id, e.method, e.path, e.auth_handler, e.has_transaction, count(s.id) as stages
from api_endpoints e
         left join api_stages s on s.endpoint_id = e.id
where e.path = 'v1/ti/bonus/draws/daily'
   or e.path like 'v1/ti/bonus/admin/%'
group by e.id, e.method, e.path, e.auth_handler, e.has_transaction
order by e.path, e.method;

-- Проверка 2: стадии как их прочтёт платформа — двоеточия, решётки и доллары на месте
select e.path, s.sort_order, s.alias, s.handler, s.access_condition,
       coalesce(s.attributes ->> 'sql', s.attributes ->> 'request_body', s.attributes ->> 'js_eval') as body
from api_endpoints e
         join api_stages s on s.endpoint_id = e.id
where e.path = 'v1/ti/bonus/draws/daily'
   or e.path like 'v1/ti/bonus/admin/%'
order by e.path, e.method, s.sort_order;

-- Проверка 3: задача cron, has_basic = true (сам заголовок не выводится)
select id, name, state, methods, url, cron_expression,
       coalesce((attributes -> 'header' ->> 'Authorization') like 'Basic %', false) as has_basic
from cron_schedules
where name = 'TiBonusDrawsDaily';
