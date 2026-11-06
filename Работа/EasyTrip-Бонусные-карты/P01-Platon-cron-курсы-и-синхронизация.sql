-- =====================================================================================
-- Platon, 06.11.2026: два API для cron и две задачи cron бонусных карт.
--
--   POST v1/ti/currency/load   курсы ЦБ: забирает https://cbu.uz/uz/arkhiv-kursov-valyut/json/
--                              и сохраняет функцией project.ti_currency_rates_load_cbu.
--                              Задача cron TiCurrencyLoad — раз в 3 часа (в 15 минут).
--   POST v1/ti/bonus/sync      project.ti_bonus_sync(): сверка карт и скидок с платежами
--                              RealPay, снятие резервов старше 30 минут, начисления и сгорания.
--                              Задача cron TiBonusSync — каждые 10 минут.
--
-- База — platon, не microservice. Файл вставляет строки в api_endpoints, api_stages и
-- cron_schedules; SQL стадий потом выполняется в microservice через источник project.
--
-- Запуск: DataGrip, консоль на базе platon → весь файл (Ctrl+A, Ctrl+Enter). Повторный запуск
-- ничего не задвоит: эндпоинт с тем же путём и задача с тем же именем пропускаются.
--
-- Как устроено:
--   * id — отрицательные, ниже текущего минимума, как у ручных эндпоинтов RealPay;
--   * auth_handler = basic: cron вызывает эндпоинты с заголовком Basic. Заголовок
--     Authorization задач копируется из задачи TokenUpdater — значение в файл не попадает.
--     Нет TokenUpdater — задачи не вставятся (проверка в конце покажет пусто);
--   * стадии берут результат прошлой стадии через двоеточие и её имя (alias). В JSON ниже это
--     двоеточие записано как \u003a, чтобы DataGrip не принял его за свой параметр. В базе и в
--     конструкторе это обычное двоеточие — его покажет проверка в конце файла;
--   * has_transaction = true: SQL-стадии пишут в базу, и платформа сама сделает commit.
-- =====================================================================================

begin;

-- 1. Эндпоинты
insert into api_endpoints (id, state, version, created_at, attributes, method, path, auth_handler,
                           has_transaction, group_by, result_cached_seconds, note)
select (select least(min(id), 0) from api_endpoints) - row_number() over (order by v.ord),
       1, 1, now(), '{}', 'POST', v.path, 'basic', true, 'Bonus cards (Mutalib)', 0, v.note
from (values (1, 'v1/ti/currency/load', 'Бонусные карты: курсы ЦБ с cbu.uz. Вызывает cron TiCurrencyLoad'),
             (2, 'v1/ti/bonus/sync', 'Бонусные карты: ti_bonus_sync — начисления, сгорания, сверка с RealPay. Вызывает cron TiBonusSync'))
         as v(ord, path, note)
where not exists (select 1 from api_endpoints e where e.method = 'POST' and e.path = v.path);

-- 2. Стадии
--   currency/load: 10 cbu     — GET cbu.uz, ответ целиком (массив валют);
--                  20 loaded  — сохраняет курсы, возвращает, сколько строк добавлено или изменено;
--                  30 _body   — ответ: loaded и последний курс доллара (usd_rate, usd_date).
--   bonus/sync:    10 _body   — ответ: cards, discounts (сведено с платежами), cards_processed
--                               (карт с начислением или сгоранием).
insert into api_stages (id, endpoint_id, sort_order, alias, handler, serialize_result, state, version, created_at,
                        attributes)
select (select least(min(id), 0) from api_stages) - row_number() over (order by e.path, s.sort_order),
       e.id, s.sort_order, s.alias, s.handler, true, 1, 1, now(), s.attributes::json
from api_endpoints e
         join (values ('v1/ti/currency/load', 10, 'cbu', 'http_request_handler',
                       '{"resource_url": "https://cbu.uz/uz/arkhiv-kursov-valyut/json/", "http_method": "GET", "content_type": "application/json", "request_body": "", "http_headers": {"Accept": "application/json"}, "http_request_response": "false"}'),
                      ('v1/ti/currency/load', 20, 'loaded', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "object", "sql": "select project.ti_currency_rates_load_cbu(\u003acbu::jsonb)"}'),
                      ('v1/ti/currency/load', 30, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select \u003aloaded::integer as loaded, r.rate as usd_rate, r.rate_date as usd_date\nfrom (select 1) as one\n         left join lateral (select c.rate, c.rate_date\n                            from project.ti_currency_rates c\n                            where c.currency = ''USD''\n                            order by c.rate_date desc\n                            limit 1) as r on true"}'),
                      ('v1/ti/bonus/sync', 10, '_body', 'sql_select',
                       '{"datasource": "project", "sql_result_type": "map", "sql": "select (s.result ->> ''cards'')::integer as cards,\n       (s.result ->> ''discounts'')::integer as discounts,\n       (s.result ->> ''cards_processed'')::integer as cards_processed\nfrom (select project.ti_bonus_sync() as result) as s"}'))
    as s(path, sort_order, alias, handler, attributes) on s.path = e.path
where e.method = 'POST'
  and not exists (select 1 from api_stages x where x.endpoint_id = e.id);

-- 3. Задачи cron
insert into cron_schedules (id, state, version, created_at, name, group_by, code_type, methods, url,
                            cron_expression, datasource, content_type, log_level, attempt_count, attributes, details)
select (select least(min(id), 0) from cron_schedules) - row_number() over (order by v.ord),
       1, 1, now(), v.name, 'Bonus cards (Mutalib)', 'REQUEST', 'POST', v.url,
       v.cron, 'project', 'application/json', 'ERROR', 1,
       json_build_object('header', json_build_object('Authorization', t.attributes -> 'header' ->> 'Authorization'),
                         'js_eval', null),
       '{}'
from (values (1, 'TiCurrencyLoad', 'v1/ti/currency/load', '15 */3 * * *'),
             (2, 'TiBonusSync', 'v1/ti/bonus/sync', '*/10 * * * *')) as v(ord, name, url, cron)
         join cron_schedules t on t.name = 'TokenUpdater'
where not exists (select 1 from cron_schedules c where c.name = v.name);

commit;

-- Проверка 1: два эндпоинта и четыре стадии. В SQL стадий — обычное двоеточие перед cbu и loaded.
select e.id as endpoint_id, e.method, e.path, e.auth_handler, e.has_transaction, e.state,
       s.id as stage_id, s.sort_order, s.alias, s.handler,
       coalesce(s.attributes ->> 'sql',
                (s.attributes ->> 'http_method') || ' ' || (s.attributes ->> 'resource_url')) as what
from api_endpoints e
         join api_stages s on s.endpoint_id = e.id
where e.method = 'POST'
  and e.path in ('v1/ti/currency/load', 'v1/ti/bonus/sync')
order by e.path, s.sort_order;

-- Проверка 2: две задачи cron, has_basic = true (сам заголовок не выводится)
select id, name, state, methods, url, cron_expression,
       coalesce((attributes -> 'header' ->> 'Authorization') like 'Basic %', false) as has_basic
from cron_schedules
where name in ('TiCurrencyLoad', 'TiBonusSync')
order by id desc;
