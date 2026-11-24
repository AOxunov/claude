"""Генератор P01-Platon-API-Uzum.sql (база platon): эндпоинты доставки Uzum Tezkor и cron.

Подстановки платформы (:alias, #field, $user) внутри JSON стадий пишутся JSON-escape-ом,
чтобы DataGrip не принял их за свои параметры (как в бонусных картах, gen_p02.py).
Запуск: python -I tools/gen_p01.py P01-Platon-API-Uzum.sql
"""
import json
import re
import sys

BS = chr(92)
OUT = sys.argv[1]

GROUP = 'Uzum Tezkor (Mutalib)'
CRON_NAME = 'UzumSync'
CRON_URL = 'v1/uzum/sync'
CRON_EXPR = '* * * * *'

# JS-стадия: выполняет вызовы, которые собрала SQL-функция (стадия PREP, колонка calls).
# Пишется сразу на ES5: в базе хранится и исходник, и собранный вариант с обёрткой.
JS_CALLER = '''// Uzum Tezkor: выполнить вызовы из стадии PREP. calls — JSON-массив
// [{key, method, url, token, body, body_mode}], его собирает SQL-функция project.uzum_*.
// Ответ — объект {key: ответ Uzum}; ошибку HTTP кладём в _error, разбирает её SQL.
var p = variables.PREP;
var raw = p ? p.calls : null;
if (raw && raw.value !== undefined) {
    raw = raw.value;
}
var calls = raw ? JSON.parse(String(raw)) : [];
var out = {};
for (var i = 0; i < calls.length; i++) {
    var c = calls[i];
    var h = {"Authorization": "Bearer " + c.token, "Content-Type": "application/json", "Accept-Language": "ru"};
    try {
        if (c.method === "GET") {
            out[c.key] = http.get(c.url, h);
        } else {
            var b = (c.body === null || c.body === undefined) ? "{}" : c.body;
            out[c.key] = http.post(c.url, c.body_mode === "object" ? JSON.parse(b) : b, h);
        }
    } catch (e) {
        out[c.key] = {"_error": String(e && e.message ? e.message : e)};
    }
}
return out;'''


def esc(s):
    """JSON-строка; символы подстановок — escape-ом."""
    j = json.dumps(s, ensure_ascii=False)
    j = re.sub(r'(?<!:):(?=[A-Za-z_])', lambda m: BS + 'u003a', j)
    j = re.sub(r'#(?=[A-Za-z_])', lambda m: BS + 'u0023', j)
    j = re.sub(r'\$(?=[A-Za-z_])', lambda m: BS + 'u0024', j)
    return j


def sql_stage(sql, rtype='map'):
    return '{"datasource": "project", "sql_result_type": %s, "sql": %s}' % (json.dumps(rtype), esc(sql))


def js_caller(prep_alias):
    code = JS_CALLER.replace('PREP', prep_alias)
    body = '\n'.join(line for line in code.split('\n') if not line.lstrip().startswith('//'))
    es5 = 'return (function(){\n' + body + '\n})();'
    return '{"js_eval": %s}' % esc(json.dumps({'code': code, 'es5': es5}, ensure_ascii=False, separators=(',', ':')))


U = '$user.id::uuid'

# (method, path, auth, has_transaction, note, [stages]); стадия: (sort, alias, handler, attributes)
# has_transaction = false везде: строка заявки должна сохраниться ДО вызова Uzum (request_id).
ENDPOINTS = [
    ('POST', 'v1/uzum/calculate', 'bearer', False,
     'Uzum: цена доставки от объекта до адреса (place_id, branch_id, lon, lat, address, taxi_class, weight). Ничего не создаёт',
     [(10, 'prep', 'sql_select', sql_stage(
         'select * from project.uzum_calc_prepare(%s, #place_id::uuid, #branch_id::uuid, #lon::numeric, #lat::numeric,\n'
         '                                        #address::varchar, #taxi_class::varchar, #weight::numeric)' % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage('select * from project.uzum_calc_result(:uz::text, :prep.taxi_class::varchar)'))]),

    ('POST', 'v1/uzum/claim/create', 'bearer', False,
     'Uzum: вызвать курьера (оператор). Черновик с ценой; auto_accept — сразу заказ. Повтор с тем же order_ref — та же доставка',
     [(10, 'prep', 'sql_select', sql_stage(
         'select * from project.uzum_create_prepare(%s, #place_id::uuid, #branch_id::uuid, #order_ref::varchar,\n'
         '                                          #recipient_name::varchar, #recipient_phone::varchar,\n'
         '                                          #address::varchar, #lon::numeric, #lat::numeric,\n'
         '                                          #porch::varchar, #sfloor::varchar, #sflat::varchar,\n'
         '                                          #door_code::varchar, #address_comment::varchar,\n'
         '                                          #comment::varchar, #items::text, #taxi_class::varchar,\n'
         '                                          #optional_return::boolean, #auto_accept::boolean)' % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage(
          "select * from project.uzum_save(%s, :prep.id::uuid, 'create', :uz::text)" % U))]),

    ('POST', 'v1/uzum/claim/accept', 'bearer', False,
     'Uzum: подтвердить черновик — начать поиск курьера (id). После этого заказ не меняется, только отмена',
     [(10, 'prep', 'sql_select', sql_stage("select * from project.uzum_op_prepare(%s, #id::uuid, 'accept')" % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage(
          "select * from project.uzum_save(%s, :prep.id::uuid, 'accept', :uz::text)" % U))]),

    ('GET', 'v1/uzum/claim/info', 'bearer', False,
     'Uzum: доставка со свежим статусом из claims/info (id). Оператор или тот, кто создал',
     [(10, 'prep', 'sql_select', sql_stage("select * from project.uzum_op_prepare(%s, #id::uuid, 'info')" % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage(
          "select * from project.uzum_save(%s, :prep.id::uuid, 'info', :uz::text)" % U))]),

    ('POST', 'v1/uzum/claim/cancel', 'bearer', False,
     'Uzum: отменить доставку (id; allow_paid = true — согласие на платную отмену после забора)',
     [(10, 'prep', 'sql_select', sql_stage("select * from project.uzum_op_prepare(%s, #id::uuid, 'cancel_info')" % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, 'step', 'sql_select', sql_stage(
          'select * from project.uzum_cancel_decide(%s, :prep.id::uuid, :uz::text, #allow_paid::boolean)' % U)),
      (40, 'uz2', 'js_eval_handler', js_caller('step')),
      (50, '_body', 'sql_select', sql_stage(
          "select * from project.uzum_save(%s, :step.id::uuid, 'cancel', :uz2::text)" % U))]),

    ('GET', 'v1/uzum/claim/courier', 'bearer', False,
     'Uzum: курьер — имя, телефон, координаты, ссылка отслеживания (id)',
     [(10, 'prep', 'sql_select', sql_stage("select * from project.uzum_op_prepare(%s, #id::uuid, 'courier')" % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage(
          'select * from project.uzum_courier_save(%s, :prep.id::uuid, :uz::text)' % U))]),

    ('GET', 'v1/uzum/claims', 'bearer', False,
     'Uzum: доставки объектов оператора (place_id, status — статус или этап, active, limit, offset)',
     [(10, '_body', 'sql_select', sql_stage(
         'select * from project.uzum_claims_list(%s, #place_id::uuid, #status::varchar, #active::boolean,\n'
         '                                       #limit::integer, #offset::integer)' % U, 'list'))]),

    ('GET', 'v1/uzum/points', 'bearer', False,
     'Uzum: где доступна доставка — точки забора без токенов (place_id)',
     [(10, '_body', 'sql_select', sql_stage('select * from project.uzum_points_list(#place_id::uuid)', 'list'))]),

    ('GET', 'v1/uzum/me', 'bearer', False,
     'Uzum: мой id и права (user_id — для project.uzum_operators)',
     [(10, '_body', 'sql_select', sql_stage('select * from project.uzum_me(%s, $user.username::varchar)' % U))]),

    ('POST', 'v1/uzum/callback', None, False,
     'Uzum: callback о смене статуса — без авторизации, secret в адресе; статус берётся из claims/info',
     [(10, 'cb', 'sql_select', sql_stage(
         'select * from project.uzum_callback_receive(#secret::varchar, #claim_id::varchar, #status::varchar,\n'
         '                                            #updated_ts::varchar)')),
      (20, 'uz', 'js_eval_handler', js_caller('cb')),
      (30, '_body', 'sql_select', sql_stage('select * from project.uzum_callback_done(:cb.id::uuid, :uz::text)'))]),

    ('POST', CRON_URL, 'basic', False,
     'Uzum: cron %s — claims/info по активным доставкам без новостей, повтор create для new' % CRON_NAME,
     [(10, 'prep', 'sql_select', sql_stage('select * from project.uzum_sync_prepare()')),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage('select * from project.uzum_sync_save(:uz::text)'))]),

    ('GET', 'v1/uzum/diag', 'bearer', False,
     'Uzum: диагностика платформы — что делает http.post на 404 и какой режим тела понимает Uzum (администратор; place_id)',
     [(10, 'prep', 'sql_select', sql_stage('select * from project.uzum_diag_prepare(%s, #place_id::uuid)' % U)),
      (20, 'uz', 'js_eval_handler', js_caller('prep')),
      (30, '_body', 'sql_select', sql_stage('select * from project.uzum_diag_result(:uz::text)'))]),
]


def q(s):
    return 'null::varchar' if s is None else "'" + s.replace("'", "''") + "'"


n_end = len(ENDPOINTS)
n_stages = sum(len(e[5]) for e in ENDPOINTS)

end_rows = []
for i, (method, path, auth, tx, note, _) in enumerate(ENDPOINTS, 1):
    end_rows.append('(%d, %s, %s, %s, %s, %s)' % (i, q(method), q(path), q(auth), 'true' if tx else 'false', q(note)))

stage_rows = []
k = 0
for method, path, auth, tx, note, stages in ENDPOINTS:
    for sort, alias, handler, attrs in stages:
        k += 1
        json.loads(attrs)  # JSON валиден
        stage_rows.append('(%d, %s, %s, %d, %s, %s,\n                       %s)'
                          % (k, q(method), q(path), sort, q(alias), q(handler), q(attrs)))

lines = []
for method, path, auth, tx, note, stages in ENDPOINTS:
    lines.append('--   %-5s %-24s %-7s %s' % (method, path, auth or 'нет', note.split(' (')[0].split('. ')[0]))

paths = ', '.join(q(e[1]) for e in ENDPOINTS)

header = f"""-- =====================================================================================
-- Platon, 24.11.2026 (P01): доставка Uzum Tezkor — API и cron.
--
-- База — platon, не microservice. Сначала в microservice должна быть миграция
-- 01-DDL.sql: стадии вызывают её функции project.uzum_*.
-- Файл собран генератором tools/gen_p01.py — править там, потом пересобрать.
--
-- Эндпоинты ({n_end}, стадий {n_stages}), группа «{GROUP}»:
""" + '\n'.join(lines) + f"""
--
-- Запуск: DataGrip, консоль на базе platon → весь файл (Ctrl+A, Ctrl+Enter). Повторный запуск
-- ничего не задвоит: эндпоинт с тем же методом и путём и задача с тем же именем пропускаются.
--
-- Как устроено:
--   * У эндпоинтов с вызовом Uzum три стадии: prep (SQL собирает вызовы и токен точки),
--     uz (JS выполняет их через http.post / http.get, ошибку HTTP ловит и кладёт в _error),
--     _body (SQL разбирает ответ, пишет заявку и отдаёт её). У cancel — две пары: сначала
--     cancel-info, потом cancel (платная — только с allow_paid).
--   * has_transaction = false: строка заявки с request_id сохраняется до вызова Uzum, поэтому
--     сбой связи не теряет заявку, а повтор (cron) не создаёт второго курьера.
--   * callback — без авторизации (Uzum не подписывает запросы): секрет заявки в адресе, а
--     статус берётся из claims/info, поэтому поддельный callback ничего не меняет.
--   * cron {CRON_NAME} ({CRON_EXPR}) — basic, заголовок Authorization копируется из
--     TokenUpdater (как в P01/P02 бонусных карт).
--   * id — отрицательные, ниже текущего минимума; подстановки платформы (двоеточие, решётка,
--     доллар перед именем) в JSON записаны escape-ами \\u003a, \\u0023, \\u0024, чтобы DataGrip не
--     принял их за свои параметры. В базе это обычные символы — их покажет проверка 2.
--
-- После вставки — первым делом GET v1/uzum/diag (раздел «Проверка на сервере» в 00-Обзор.md).
-- =====================================================================================
"""

sql = header + f"""
begin;

-- 1. Эндпоинты
insert into api_endpoints (id, state, version, created_at, attributes, method, path, auth_handler,
                           has_transaction, group_by, result_cached_seconds, note)
select (select least(min(id), 0) from api_endpoints) - row_number() over (order by v.ord),
       1, 1, now(), '{{}}', v.method, v.path, v.auth, v.tx, {q(GROUP)}, 0, v.note
from (values {(','+chr(10)+'             ').join(end_rows)})
         as v(ord, method, path, auth, tx, note)
where not exists (select 1 from api_endpoints e where e.method = v.method and e.path = v.path);

-- 2. Стадии
insert into api_stages (id, endpoint_id, sort_order, alias, handler, serialize_result, state, version, created_at,
                        attributes, access_condition)
select (select least(min(id), 0) from api_stages) - row_number() over (order by s.ord),
       e.id, s.sort_order, s.alias, s.handler, true, 1, 1, now(), s.attributes::json, null
from api_endpoints e
         join (values {(','+chr(10)+'                      ').join(stage_rows)})
    as s(ord, method, path, sort_order, alias, handler, attributes) on s.method = e.method and s.path = e.path
where not exists (select 1 from api_stages x where x.endpoint_id = e.id);

-- 3. Задача cron
insert into cron_schedules (id, state, version, created_at, name, group_by, code_type, methods, url,
                            cron_expression, datasource, content_type, log_level, attempt_count, attributes, details)
select (select least(min(id), 0) from cron_schedules) - 1,
       1, 1, now(), {q(CRON_NAME)}, {q(GROUP)}, 'REQUEST', 'POST', {q(CRON_URL)},
       {q(CRON_EXPR)}, 'project', 'application/json', 'ERROR', 1,
       json_build_object('header', json_build_object('Authorization', t.attributes -> 'header' ->> 'Authorization'),
                         'js_eval', null),
       '{{}}'
from cron_schedules t
where t.name = 'TokenUpdater'
  and not exists (select 1 from cron_schedules c where c.name = {q(CRON_NAME)});

commit;

-- Проверка 1: {n_end} эндпоинтов, всего {n_stages} стадий
select e.id, e.method, e.path, e.auth_handler, e.has_transaction, count(s.id) as stages
from api_endpoints e
         left join api_stages s on s.endpoint_id = e.id
where e.path in ({paths})
group by e.id, e.method, e.path, e.auth_handler, e.has_transaction
order by e.path, e.method;

-- Проверка 2: стадии как их прочтёт платформа — двоеточия, решётки и доллары на месте
select e.path, s.sort_order, s.alias, s.handler,
       coalesce(s.attributes ->> 'sql', s.attributes ->> 'js_eval') as body
from api_endpoints e
         join api_stages s on s.endpoint_id = e.id
where e.path in ({paths})
order by e.path, e.method, s.sort_order;

-- Проверка 3: задача cron, has_basic = true (сам заголовок не выводится)
select id, name, state, methods, url, cron_expression,
       coalesce((attributes -> 'header' ->> 'Authorization') like 'Basic %', false) as has_basic
from cron_schedules
where name = {q(CRON_NAME)};
"""

with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write(sql)
print('written', OUT, 'endpoints', n_end, 'stages', n_stages)
