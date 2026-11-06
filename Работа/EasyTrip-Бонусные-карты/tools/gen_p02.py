"""Генератор P02-Platon-розыгрыши-и-админка.sql (база platon).

Подстановки платформы (:alias, #field, $user) внутри JSON стадий пишутся JSON-escape-ом,
чтобы DataGrip не принял их за свои параметры; в access_condition (не JSON) — через chr(58).
"""
import json
import re
import sys

BS = chr(92)
OUT = sys.argv[1]

GROUP_CRON = 'Bonus cards (Mutalib)'
GROUP_ADMIN = 'Bonus cards admin (Mutalib)'

RANDOM_URL = 'https://api.random.org/json-rpc/4/invoke'
RANDOM_BODY = ('{"jsonrpc": "2.0", "method": "generateSignedDecimalFractions", '
               '"params": {"apiKey": ":prep.api_key", "n": :prep.n, "decimalPlaces": 14, "replacement": true, '
               '"userData": {"draw_id": ":prep.draw_id", "entries_hash": ":prep.entries_hash"}}, "id": 1}')


def esc(s):
    """JSON-строка; символы подстановок — escape-ом."""
    j = json.dumps(s, ensure_ascii=False)
    j = re.sub(r'(?<!:):(?=[A-Za-z_])', lambda m: BS + 'u003a', j)
    j = re.sub(r'#(?=[A-Za-z_])', lambda m: BS + 'u0023', j)
    j = re.sub(r'\$(?=[A-Za-z_])', lambda m: BS + 'u0024', j)
    return j


def sql_stage(sql, rtype):
    return '{"datasource": "project", "sql_result_type": %s, "sql": %s}' % (json.dumps(rtype), esc(sql))


def http_random():
    return ('{"resource_url": %s, "http_method": "POST", "content_type": "application/json", "request_body": %s, '
            '"http_headers": {"Accept": "application/json"}, "http_request_response": "false"}'
            % (json.dumps(RANDOM_URL), esc(RANDOM_BODY)))


def js_parse(alias):
    code = 'return JSON.parse(variables.%s.value)' % alias
    es5 = 'return (function(){return JSON.parse(variables.%s.value)})();' % alias
    return '{"js_eval": %s}' % esc(json.dumps({'code': code, 'es5': es5}, ensure_ascii=False, separators=(',', ':')))


def cond(alias_field):
    # access_condition — обычный текст, не JSON: двоеточие собирается функцией chr(58)
    return "(chr(58) || '%s')::varchar" % alias_field


U = '$user.id::uuid'

# (method, path, auth, has_transaction, group, note, [stages]); стадия: (sort, alias, handler, attributes, cond)
ENDPOINTS = [
    ('POST', 'v1/ti/bonus/draws/daily', 'basic', True, GROUP_CRON,
     'Бонусные карты: ежедневные розыгрыши — создать сегодняшние, провести закончившийся через random.org. Вызывает cron TiBonusDrawsDaily',
     [(10, 'prep', 'sql_select', sql_stage('select * from project.ti_bonus_draw_daily_next()', 'map'), None),
      (20, 'random', 'http_request_handler', http_random(), cond('prep.need_random')),
      (30, 'run', 'sql_select',
       sql_stage('select * from project.ti_bonus_draw_daily_finish(:prep.draw_id::uuid, :random::text)', 'map'),
       cond('prep.need_random')),
      (40, 'run_empty', 'sql_select',
       sql_stage('select * from project.ti_bonus_draw_daily_finish(:prep.draw_id::uuid, null)', 'map'),
       cond('prep.need_empty')),
      (50, '_body', 'sql_select', sql_stage(
          "select :prep.draw_id::uuid as draw_id, :prep.audience::varchar as audience, :prep.created::integer as created,\n"
          "       :prep.note::text as note, d.status, d.entries_count, d.prizes_count,\n"
          "       case when d.status in ('DRAFT', 'FROZEN') then d.attributes ->> 'auto_error' end as error\n"
          "from (select 1) as one\n"
          "         left join project.ti_bonus_draws d on d.id = :prep.draw_id::uuid", 'map'), None)]),

    ('GET', 'v1/ti/bonus/admin/me', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: кто я и есть ли доступ (id — для ti_bonus_admins)',
     [(10, '_body', 'sql_select', sql_stage(
         'select $user.id::uuid as user_id, $user.username::varchar as username,\n'
         '       project.ti_bonus_is_admin($user.id::uuid) as is_admin', 'map'), None)]),

    ('GET', 'v1/ti/bonus/admin/draws', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: список розыгрышей (audience, kind, status, limit, offset)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_draws(%s, #audience::varchar, #kind::varchar, #status::varchar,\n'
         '                                           #limit::integer, #offset::integer)' % U, 'list'), None)]),

    ('GET', 'v1/ti/bonus/admin/draw', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: розыгрыш целиком — призы, победители, ответ random.org (id)',
     [(10, 'draw', 'sql_select', sql_stage('select project.ti_bonus_admin_draw(%s, #id::uuid)' % U, 'object'), None),
      (20, '_body', 'js_eval_handler', js_parse('draw'), None)]),

    ('POST', 'v1/ti/bonus/admin/draw/create', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: новый розыгрыш (audience, date_from, date_to, prizes, title, kind)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_draw_create(%s, #audience::varchar, #date_from::text, #date_to::text,\n'
         '                                                 #prizes::text, #title::varchar, #kind::varchar)' % U, 'map'),
       None)]),

    ('POST', 'v1/ti/bonus/admin/draw/prizes', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: новые призы черновика (id, prizes)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_draw_prizes(%s, #id::uuid, #prizes::text)' % U, 'map'), None)]),

    ('POST', 'v1/ti/bonus/admin/draw/run', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: провести розыгрыш — фиксация, random.org, победители (id)',
     [(10, 'prep', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_draw_prepare(%s, #id::uuid)' % U, 'map'), None),
      (20, 'random', 'http_request_handler', http_random(), cond('prep.need_random')),
      (30, 'run', 'sql_select', sql_stage(
          'select project.ti_bonus_admin_draw_finish(%s, :prep.draw_id::uuid, :random::text)' % U, 'object'),
       cond('prep.need_random')),
      (40, 'run_empty', 'sql_select', sql_stage(
          'select project.ti_bonus_admin_draw_finish(%s, :prep.draw_id::uuid, null)' % U, 'object'),
       cond('prep.need_empty')),
      (50, 'draw', 'sql_select', sql_stage(
          'select project.ti_bonus_admin_draw(%s, :prep.draw_id::uuid)' % U, 'object'), None),
      (60, '_body', 'js_eval_handler', js_parse('draw'), None)]),

    ('POST', 'v1/ti/bonus/admin/draw/cancel', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: отменить розыгрыш до проведения (id, reason)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_draw_cancel(%s, #id::uuid, #reason::varchar)' % U, 'map'), None)]),

    ('GET', 'v1/ti/bonus/admin/fund', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: фонды — остатки и движения за период (date_from, date_to)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_fund(%s, #date_from::text, #date_to::text)' % U, 'list'), None)]),

    ('GET', 'v1/ti/bonus/admin/fund/ledger', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: движения фонда (fund, op_type, limit, offset)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_fund_ledger(%s, #fund::varchar, #op_type::varchar,\n'
         '                                                 #limit::integer, #offset::integer)' % U, 'list'), None)]),

    ('POST', 'v1/ti/bonus/admin/fund/adjust', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: пополнение или списание фонда ADJUST (fund, amount_usd, comment)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_fund_adjust(%s, #fund::varchar, #amount_usd::numeric, #comment::varchar)' % U,
         'map'), None)]),

    ('GET', 'v1/ti/bonus/admin/winners', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: победители и выплаты (payout_status, audience, limit, offset)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_winners(%s, #payout_status::varchar, #audience::varchar,\n'
         '                                             #limit::integer, #offset::integer)' % U, 'list'), None)]),

    ('POST', 'v1/ti/bonus/admin/winner/paid', 'bearer', True, GROUP_ADMIN,
     'Бонусные карты, админка: отметить выплату (id, paid_amount, paid_currency, paid_rate, payout_ref)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_winner_paid(%s, #id::uuid, #paid_amount::numeric, #paid_currency::varchar,\n'
         '                                                 #paid_rate::numeric, #payout_ref::varchar)' % U, 'map'), None)]),

    ('GET', 'v1/ti/bonus/admin/errors', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: сбои бонусов и cron розыгрышей (limit)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.ti_bonus_admin_errors(%s, #limit::integer)' % U, 'list'), None)]),

    ('GET', 'v1/ti/bonus/admin/health', 'bearer', False, GROUP_ADMIN,
     'Бонусные карты, админка: состояние модуля — курс, ключ random.org, розыгрыши, цепочка, сверка, фонды',
     [(10, '_body', 'sql_select', sql_stage('select * from project.ti_bonus_admin_health(%s)' % U, 'map'), None)]),
]


def q(s):
    return "'" + s.replace("'", "''") + "'"


n_end = len(ENDPOINTS)
n_stages = sum(len(e[6]) for e in ENDPOINTS)

end_rows = []
for i, (method, path, auth, tx, grp, note, _) in enumerate(ENDPOINTS, 1):
    end_rows.append('(%d, %s, %s, %s, %s, %s, %s)' % (i, q(method), q(path), q(auth), 'true' if tx else 'false', q(grp), q(note)))

stage_rows = []
k = 0
for method, path, auth, tx, grp, note, stages in ENDPOINTS:
    for sort, alias, handler, attrs, cnd in stages:
        k += 1
        json.loads(attrs)  # JSON валиден
        stage_rows.append('(%d, %s, %s, %d, %s, %s,\n                       %s,\n                       %s)'
                          % (k, q(method), q(path), sort, q(alias), q(handler), q(attrs), cnd or 'null::varchar'))

# для шапки: список эндпоинтов
lines = []
for method, path, auth, tx, grp, note, stages in ENDPOINTS:
    lines.append('--   %-5s %-36s %s' % (method, path, auth))

header = f"""-- =====================================================================================
-- Platon, 06.11.2026 (P02): розыгрыши бонусных карт — cron ежедневных и API админки.
--
-- База — platon, не microservice. Сначала в microservice должна быть миграция
-- 07-Розыгрыши-cron-и-админка.sql: стадии вызывают её функции.
--
-- Эндпоинты ({n_end}, стадий {n_stages}):
""" + '\n'.join(lines) + f"""
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
--     \\u003a, \\u0023, \\u0024, а в access_condition — через chr(58), чтобы DataGrip не принял их за
--     свои параметры. В базе это обычные символы — их покажет проверка в конце файла;
--   * стадии random и run выполняются, только если prep.need_random, стадия run_empty — если
--     prep.need_empty (access_condition);
--   * ответ со вложенными данными (розыгрыш целиком) — как у v1/hotels: SQL-стадия отдаёт jsonb,
--     JS-стадия _body делает JSON.parse(variables.draw.value);
--   * has_transaction = true у эндпоинтов, которые пишут: при ошибке на любой стадии ничего не
--     сохранится (у проведения из админки розыгрыш останется черновиком).
-- =====================================================================================
"""

sql = header + f"""
begin;

-- 1. Эндпоинты
insert into api_endpoints (id, state, version, created_at, attributes, method, path, auth_handler,
                           has_transaction, group_by, result_cached_seconds, note)
select (select least(min(id), 0) from api_endpoints) - row_number() over (order by v.ord),
       1, 1, now(), '{{}}', v.method, v.path, v.auth, v.tx, v.grp, 0, v.note
from (values {(','+chr(10)+'             ').join(end_rows)})
         as v(ord, method, path, auth, tx, grp, note)
where not exists (select 1 from api_endpoints e where e.method = v.method and e.path = v.path);

-- 2. Стадии
insert into api_stages (id, endpoint_id, sort_order, alias, handler, serialize_result, state, version, created_at,
                        attributes, access_condition)
select (select least(min(id), 0) from api_stages) - row_number() over (order by s.ord),
       e.id, s.sort_order, s.alias, s.handler, true, 1, 1, now(), s.attributes::json, s.cond
from api_endpoints e
         join (values {(','+chr(10)+'                      ').join(stage_rows)})
    as s(ord, method, path, sort_order, alias, handler, attributes, cond) on s.method = e.method and s.path = e.path
where not exists (select 1 from api_stages x where x.endpoint_id = e.id);

-- 3. Задача cron
insert into cron_schedules (id, state, version, created_at, name, group_by, code_type, methods, url,
                            cron_expression, datasource, content_type, log_level, attempt_count, attributes, details)
select (select least(min(id), 0) from cron_schedules) - row_number() over (order by v.ord),
       1, 1, now(), v.name, {q(GROUP_CRON)}, 'REQUEST', 'POST', v.url,
       v.cron, 'project', 'application/json', 'ERROR', 1,
       json_build_object('header', json_build_object('Authorization', t.attributes -> 'header' ->> 'Authorization'),
                         'js_eval', null),
       '{{}}'
from (values (1, 'TiBonusDrawsDaily', 'v1/ti/bonus/draws/daily', '5,15,25,35,45,55 * * * *')) as v(ord, name, url, cron)
         join cron_schedules t on t.name = 'TokenUpdater'
where not exists (select 1 from cron_schedules c where c.name = v.name);

commit;

-- Проверка 1: {n_end} эндпоинтов, всего {n_stages} стадий
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
"""

with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write(sql)
print('written', OUT, 'endpoints', n_end, 'stages', n_stages)
