"""Эмулятор стадий platon для доставки Uzum Tezkor (P01).

Читает эндпоинты v1/uzum/* из локального platon, подставляет #поле, :стадия.поле и $user,
SQL-стадии выполняет в локальном microservice, а JS-стадии — в Node (tools/js_stage.js) с
настоящими запросами к тестовому стенду Uzum. Каждая стадия — отдельный вызов psql (своя
транзакция), как при has_transaction = false.

Запуск из Git Bash (PostgreSQL 17 на 5435 работает, P01 вставлен в локальный platon):
  python -I tools/emu.py <папка для временных файлов> [--fresh]
    --fresh — перед тестами откат и заново 01-DDL.sql в локальном microservice.
Тестовый токен Uzum — переменная UZUM_TEST_TOKEN или файл UZUM_TOKEN_FILE
(по умолчанию D:/code/easytrip-local-db 2/uzum-test.env, строка UZUM_TOKEN=...). В git его нет.

Все заявки, созданные на стенде, эмулятор в конце отменяет (бесплатно: курьер не назначен).
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid

PSQL = 'D:/tools/pgsql17/bin/psql.exe'
ENV = dict(os.environ, PGHOST='127.0.0.1', PGPORT='5435', PGUSER='postgres', PGCLIENTENCODING='UTF8')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
JS_RUNNER = os.path.join(HERE, 'js_stage.js')
WORK = sys.argv[1]
FRESH = '--fresh' in sys.argv[2:]
TOKEN_FILE = os.environ.get('UZUM_TOKEN_FILE', 'D:/code/easytrip-local-db 2/uzum-test.env')

ADMIN = '00000000-0000-4000-8000-0000000000c0'
OPER = '00000000-0000-4000-8000-0000000000c1'
GUEST = '00000000-0000-4000-8000-0000000000c2'
SRC = (69.20515, 41.32202)   # точка забора как в документации Uzum: Ташкент, Кукча Дарвоза 377
DST = (69.21686, 41.31740)   # доставка в 1,5 км: улица Кончилик, 47
FAR = (66.9597, 39.6542)     # Самарканд — вне зоны точки забора в Ташкенте
SUBST = re.compile(r'(?<!:):([A-Za-z_]\w*)((?:\.[A-Za-z_]\w*)*)|#([A-Za-z_]\w*)|\$user\.([A-Za-z_]\w*)')
sys.stdout.reconfigure(encoding='utf-8')

fails = 0
http_log = []


class StageError(Exception):
    pass


def psql(db, sql):
    path = os.path.join(WORK, 'emu_q.sql')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(sql)
    r = subprocess.run([PSQL, '-d', db, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', path], env=ENV, capture_output=True)
    if r.returncode != 0:
        err = r.stderr.decode('utf-8', 'replace')
        m = re.search(r'(ERROR|ОШИБКА):\s*(.*)', err)
        raise StageError(m.group(2).strip() if m else err.strip())
    return r.stdout.decode('utf-8')


def psql_file(db, path):
    r = subprocess.run([PSQL, '-d', db, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', path], env=ENV, capture_output=True)
    if r.returncode != 0:
        raise SystemExit('psql %s: %s' % (path, r.stderr.decode('utf-8', 'replace')[-2000:]))


def sqlv(q):
    return psql('microservice', q).strip()


def lit(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (dict, list)):
        v = json.dumps(v, ensure_ascii=False)
    return "'" + str(v).replace("'", "''") + "'"


def resolve(vars_, alias, path):
    v = vars_.get(alias)
    for p in [x for x in path.split('.') if x]:
        v = v.get(p) if isinstance(v, dict) else None
    return v


def subst_sql(sql, params, vars_, user):
    def rep(m):
        if m.group(1):
            return lit(resolve(vars_, m.group(1), m.group(2)))
        if m.group(3):
            return lit(params.get(m.group(3)))
        return lit(user.get(m.group(4)))
    return SUBST.sub(rep, sql)


def run_sql(sql, rtype):
    if rtype == 'list':
        q = "select coalesce(json_agg(t), '[]'::json)::text from (%s) t;\n" % sql
    else:
        q = "select coalesce((select row_to_json(t)::text from (%s) t limit 1), 'null');\n" % sql
    v = json.loads(psql('microservice', q).strip())
    if rtype == 'object' and isinstance(v, dict):
        v = next(iter(v.values()), None)
    return v


def run_js(a, vars_, params, http_mode):
    js = json.loads(a['js_eval'])
    inp = os.path.join(WORK, 'js_in.json')
    out = os.path.join(WORK, 'js_out.json')
    with open(inp, 'w', encoding='utf-8') as f:
        json.dump({'es5': js['es5'], 'variables': vars_, 'requestParams': params, 'http_mode': http_mode,
                   'work_dir': WORK}, f, ensure_ascii=False)
    try:
        r = subprocess.run(['node', JS_RUNNER, inp, out], capture_output=True)
    finally:
        os.remove(inp)  # там токен точки
    if r.returncode != 0:
        raise StageError('node: ' + r.stderr.decode('utf-8', 'replace')[-500:])
    with open(out, encoding='utf-8') as f:
        res = json.load(f)
    http_log.extend(res['calls'])
    if res['error']:
        raise StageError('JS: ' + res['error'])
    return res['result'], res['calls']


def call(eps, method, path, params=None, user=None, http_mode='throw'):
    ep = eps[(method, path)]
    params = params or {}
    user = user or {}
    if ep['auth'] == 'bearer' and not user.get('id'):
        return None, [], 'HTTP 401: нужен bearer', []
    vars_ = {}
    log = []
    calls = []
    try:
        for st in ep['stages']:
            if st['state'] != 1:
                continue
            a = st['attributes']
            if st['handler'] == 'sql_select':
                if set(a) != {'datasource', 'sql', 'sql_result_type'} or a['datasource'] != 'project':
                    raise StageError('ключи SQL-стадии: %s' % sorted(a))
                vars_[st['alias']] = run_sql(subst_sql(a['sql'], params, vars_, user), a['sql_result_type'])
            elif st['handler'] == 'js_eval_handler':
                vars_[st['alias']], c = run_js(a, vars_, params, http_mode)
                calls.extend(c)
            else:
                raise StageError('handler ' + st['handler'])
            log.append(st['alias'])
    except StageError as e:
        return None, log, str(e), calls
    return vars_.get('_body'), log, None, calls


def call_retry(eps, method, path, params, user, http_mode='throw'):
    """стенд иногда отвечает «source not in city» на адреса в Ташкенте — известная проблема, повтор"""
    b, log, err, c = call(eps, method, path, params, user, http_mode)
    if isinstance(b, dict) and 'not in city' in str(b.get('error_message') or ''):
        print('  (стенд ответил «source not in city» — повтор)')
        b, log, err, c2 = call(eps, method, path, params, user, http_mode)
        c = c + c2
    return b, log, err, c


def check(cond, label, extra=''):
    global fails
    if cond:
        print('  ok:', label)
    else:
        fails += 1
        print('  FAIL:', label, extra)


def read_token():
    t = os.environ.get('UZUM_TEST_TOKEN')
    if not t and os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, encoding='utf-8') as f:
            for line in f:
                if line.startswith('UZUM_TOKEN='):
                    t = line.split('=', 1)[1].strip()
    if not t:
        raise SystemExit('нет тестового токена Uzum: задайте UZUM_TEST_TOKEN или файл ' + TOKEN_FILE)
    return t


def load_endpoints():
    rows = psql('platon', """
select json_agg(json_build_object(
        'method', e.method, 'path', e.path, 'auth', e.auth_handler, 'tx', e.has_transaction,
        'stages', (select json_agg(json_build_object('sort', s.sort_order, 'alias', s.alias, 'handler', s.handler,
                                                     'attributes', s.attributes, 'cond', s.access_condition,
                                                     'state', s.state) order by s.sort_order)
                   from api_stages s where s.endpoint_id = e.id)))
from api_endpoints e
where e.path like 'v1/uzum/%';
""").strip()
    eps = {(x['method'], x['path']): x for x in json.loads(rows)}
    for x in eps.values():
        if any(st['cond'] for st in x['stages']):
            raise SystemExit('у стадий %s есть access_condition — эмулятор их не поддерживает' % x['path'])
    return eps


def cancel_leftovers(eps):
    """отменить на стенде всё, что осталось активным от прошлых запусков"""
    try:
        rows = run_sql('select c.id from project.uzum_claims c where c.claim_id is not null and c.finished_at is null', 'list')
    except StageError:
        return 0
    n = 0
    for r in rows:
        b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': r['id']}, {'id': ADMIN})
        n += 1 if (b and b.get('is_final')) else 0
    return n


def setup(token):
    place = sqlv("select p.id from project.places p where p.state = 1 and p.latitude between 41.25 and 41.40 "
                 "and p.longitude between 69.15 and 69.35 order by p.created_at, p.id limit 1;")
    if not place:
        raise SystemExit('в локальной базе нет объекта в Ташкенте')
    psql('microservice', f"""
update project.uzum_settings set value = 'https://emu.invalid/endpoint/api/v1/uzum/callback' where code = 'callback_url';
update project.uzum_settings set value = 'string' where code = 'js_body_mode';
delete from project.uzum_claim_events e where e.claim_row in (select c.id from project.uzum_claims c where c.place_id = '{place}');
delete from project.uzum_claim_events e where e.claim_row is null;
delete from project.uzum_claims c where c.place_id = '{place}';
delete from project.uzum_points p where p.place_id = '{place}';
delete from project.uzum_operators o where o.user_id in ('{ADMIN}', '{OPER}', '{GUEST}');
insert into project.uzum_points (place_id, env, token, name, phone, address, lon, lat, comment, note)
values ('{place}', 'test', {lit(token)}, 'Тест: точка забора', '+998000000001', 'улица Кукча Дарвоза, 377, Ташкент',
        {SRC[0]}, {SRC[1]}, 'Тест easy-trip', 'emu');
insert into project.uzum_operators (user_id, place_id, note)
values ('{ADMIN}', null, 'emu: администратор доставки'), ('{OPER}', '{place}', 'emu: оператор объекта');
""")
    psql('microservice', 'select 1;')  # затереть файл запроса с токеном
    return place


def unit_checks():
    print('== разбор ответов Uzum и форматы (SQL)')

    def err_of(obj):
        v = sqlv('select coalesce(project.uzum_result_error(%s::jsonb)::text, \'null\');' % lit(json.dumps(obj, ensure_ascii=False)))
        return json.loads(v)

    q = chr(34)
    bq = chr(92) + chr(34)
    e = err_of({'_error': '404 Not Found: ' + q + '{"code":"not_found","message":"claim not found"}' + q})
    check(e and e['code'] == 'not_found' and e['http'] == '404' and e['message'] == 'claim not found',
          'исключение с телом: код, http, сообщение', e)
    e = err_of({'_error': 'org.springframework.web.client.HttpClientErrorException$Conflict: 409 Conflict: '
                          + q + '{' + bq + 'code' + bq + ':' + bq + 'inappropriate_status' + bq + ',' + bq + 'message'
                          + bq + ':' + bq + 'order not editable status' + bq + '}' + q})
    check(e and e['code'] == 'inappropriate_status' and e['http'] == '409' and e['message'] == 'order not editable status',
          'исключение с экранированными кавычками', e)
    e = err_of({'code': 'address_too_far', 'message': 'too far'})
    check(e and e['code'] == 'address_too_far', 'тело ошибки как ответ', e)
    e = err_of({'status': 401, 'message': 'Unauthorized'})
    check(e and e['code'] == 'unauthorized' and e['http'] == '401', '401 → unauthorized', e)
    e = err_of({'code': 405, 'message': 'method POST is not allowed, but [GET] are'})
    check(e and e['code'] == 'http_405', '405 → http_405', e)
    check(err_of({'id': 'abc', 'status': 'ready_for_approval'}) is None, 'удачный ответ — не ошибка')
    check(err_of({'cancel_state': 'free'}) is None and err_of({'offers': []}) is None, 'cancel-info и calculate — не ошибки')
    e = err_of({'_error': 'I/O error on POST request for ' + q + 'https://x' + q + ': Read timed out'})
    check(e and e['code'] == 'http_error', 'сбой связи → http_error', e)
    tr = sqlv("select project.uzum_is_transient('{\"code\": \"http_error\"}') || ',' || "
              "project.uzum_is_transient('{\"code\": \"unknown_error\", \"message\": \"service is closed by schedule\"}') || ',' || "
              "project.uzum_is_transient('{\"code\": \"unknown_error\", \"message\": \"try later\"}') || ',' || "
              "project.uzum_is_transient('{\"code\": \"address_too_far\", \"http\": \"400\"}');")
    check(tr == 'true,false,true,false', 'временные ошибки: связь и сбой — да, расписание и 400 — нет', tr)
    m = sqlv("select string_agg(project.uzum_money(x), ',' order by n) from unnest(array[89000, 89000.5, 0.1 + 0.2, 18000.00, 12.345]::numeric[]) with ordinality t(x, n);")
    check(m == '89000,89000.50,0.30,18000,12.35', 'cost_value строкой без хвостов', m)
    p = sqlv("select string_agg(project.uzum_phone(x), ',' order by n) from unnest(array['901234567', '998901234567', '+998 90 123-45-67', '+7 999 1234567']) with ordinality t(x, n);")
    check(p == '+998901234567,+998901234567,+998901234567,+7 999 1234567', 'телефон к +998', p)
    st = sqlv("select string_agg(project.uzum_stage(x), ',' order by n) from unnest(array['new', 'ready_for_approval', 'performer_lookup', 'pickup_arrived', 'pickuped', 'delivered_finish', 'cancelled_with_payment', 'failed', 'returning']) with ordinality t(x, n);")
    check(st == 'creating,draft,searching,to_pickup,delivering,delivered,cancelled,failed,unknown', 'этапы для приложения', st)


def main():
    token = read_token()
    eps = load_endpoints()
    print('эндпоинтов из platon:', len(eps), ' стадий:', sum(len(x['stages']) for x in eps.values()))
    n = cancel_leftovers(eps)
    if n:
        print('отменено на стенде от прошлых запусков:', n)
    if FRESH:
        psql_file('microservice', os.path.join(ROOT, '02-Откат.sql'))
        psql_file('microservice', os.path.join(ROOT, '01-DDL.sql'))
        print('microservice: откат и 01-DDL.sql заново')
    place = setup(token)
    adm = {'id': ADMIN, 'username': 'emu-admin'}
    op = {'id': OPER, 'username': 'emu-operator'}
    guest = {'id': GUEST, 'username': 'emu-guest'}

    unit_checks()

    print('== кто я и где доступна доставка')
    b, log, err, c = call(eps, 'GET', 'v1/uzum/me', user=guest)
    check(err is None and b['user_id'] == GUEST and b['is_admin'] is False, 'me: гость', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/me', user=adm)
    check(err is None and b['is_admin'] is True and b['points'] >= 1, 'me: администратор', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/points', {'place_id': place}, guest)
    check(err is None and len(b) == 1 and 'token' not in b[0] and b[0]['env'] == 'test', 'points: точка без токена', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/me')
    check(err is not None, 'me без входа — 401', err)

    print('== диагностика платформы')
    b, log, err, c = call(eps, 'GET', 'v1/uzum/diag', {'place_id': place}, guest)
    check(err is not None and 'uzum_no_access' in err and not c, 'diag: гостю нельзя', err)
    b, log, err, c = call(eps, 'GET', 'v1/uzum/diag', {'place_id': place}, adm)
    check(err is None and b['info404_code'] == 'not_found' and b['info404_how'] == 'exception',
          'diag: 404 исключением распознан', (b, err))
    check(err is None and b['calc_string_ok'] and b['calc_string_price'] and b['calc_object_ok']
          and b['recommended_js_body_mode'] == 'string', 'diag: Uzum принимает тело и строкой, и объектом', b)
    b, log, err, c = call(eps, 'GET', 'v1/uzum/diag', {'place_id': place}, adm, http_mode='return')
    check(err is None and b['info404_code'] == 'not_found' and b['info404_how'] == 'body',
          'diag: 404 телом ответа тоже распознан', (b, err))

    print('== цена')
    b, log, err, c = call_retry(eps, 'POST', 'v1/uzum/calculate',
                                {'place_id': place, 'lon': DST[0], 'lat': DST[1], 'address': 'улица Кончилик, 47, Ташкент'}, guest)
    check(err is None and b['ok'] and b['price'] > 0 and b['currency'] == 'UZS' and b['taxi_class'] == 'courier'
          and b['delivery_to'], 'calculate: цена для любого вошедшего — %s сум' % (b or {}).get('price'), (b, err))
    b, log, err, c = call_retry(eps, 'POST', 'v1/uzum/calculate', {'place_id': place, 'lon': DST[0], 'lat': DST[1],
                                                                   'taxi_class': 'express', 'weight': '2.5'}, guest)
    check(err is None and b['ok'] and b['taxi_class'] == 'express', 'calculate: express', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/calculate', {'place_id': place, 'lon': FAR[0], 'lat': FAR[1]}, guest)
    far_code = (b or {}).get('error_code')
    check(err is None and b['ok'] is False and far_code and c and c[0]['http'] >= 400,
          'calculate: Самарканд — ошибка Uzum %s' % far_code, (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/calculate', {'place_id': place, 'lon': FAR[0], 'lat': FAR[1]}, guest,
                          http_mode='return')
    check(err is None and b['ok'] is False and b['error_code'] == far_code, 'calculate: тот же код, если платформа отдаёт тело', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/calculate', {'place_id': place, 'lon': DST[1], 'lat': DST[0]}, guest)
    check(err is not None and 'вне Узбекистана' in err and not c, 'calculate: перепутаны lon и lat — наша ошибка, в Uzum не ходим', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/calculate', {'place_id': str(uuid.uuid4()), 'lon': DST[0], 'lat': DST[1]}, guest)
    check(err is not None and 'uzum_no_point' in err, 'calculate: объект без точки Uzum', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/calculate', {'place_id': place, 'lon': DST[0], 'lat': DST[1], 'taxi_class': 'cargo'}, guest)
    check(err is not None and 'taxi_class' in err, 'calculate: taxi_class cargo — наша ошибка', err)

    print('== вызов курьера')
    ref = 'EMU-' + uuid.uuid4().hex[:6].upper()
    order = {'place_id': place, 'order_ref': ref, 'recipient_name': 'Тест: получатель', 'recipient_phone': '998000000002',
             'address': 'улица Кончилик, 47, Ташкент', 'lon': DST[0], 'lat': DST[1], 'porch': '2', 'sfloor': '5', 'sflat': '18',
             'comment': 'Тест интеграции easy-trip, не выполнять',
             'items': [{'title': 'Плов', 'quantity': 2, 'price': 45000, 'weight': 0.6},
                       {'title': 'Чай', 'quantity': 1, 'price': '8000.5'}]}
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/create', order, guest)
    check(err is not None and 'uzum_no_access' in err and not c, 'create: гостю нельзя', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/create', dict(order, recipient_phone=''), op)
    check(err is not None and 'recipient_phone' in err, 'create: без телефона — наша ошибка', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/create', dict(order, items=[{'title': 'x', 'quantity': 0}]), op)
    check(err is not None and 'quantity' in err, 'create: quantity 0 — наша ошибка', err)
    b, log, err, c = call_retry(eps, 'POST', 'v1/uzum/claim/create', order, op)
    check(err is None and b['ok'] and b['stage'] == 'draft' and b['status'] == 'ready_for_approval' and b['claim_id']
          and b['price'] > 0 and b['external_order_id'] == ref, 'create: черновик с ценой %s сум' % (b or {}).get('price'), (b, err))
    d1 = b['id'] if b else None
    if not d1:
        print('дальше без заявки нельзя')
        sys.exit(1)
    req = json.loads(sqlv("select request::text from project.uzum_claims where id = '%s';" % d1))
    secret = sqlv("select callback_secret from project.uzum_claims where id = '%s';" % d1)
    check(req['callback_properties']['callback_url'].endswith('?secret=' + secret) and len(secret) == 32,
          'create: callback_url с секретом заявки')
    items = req['items']
    check([i.get('weight') for i in items] == [1.2, None] and [i['cost_value'] for i in items] == ['45000', '8000.50']
          and req['route_points'][1]['contact']['phone'] == '+998000000002'
          and req['route_points'][1]['address']['sflat'] == '18' and 'auto_accept' not in req,
          'create: вес × количество, цены строкой, телефон с +998, квартира', items)
    check(sqlv("select items_total from project.uzum_claims where id = '%s';" % d1) == '98000.50', 'create: items_total = Σ цена × количество')
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/create', order, op)
    check(err is None and b['id'] == d1 and not c, 'create: повтор с тем же order_ref — та же доставка, в Uzum не ходим', (b, err, c))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/create', dict(order, recipient_phone='+998000000003'), op)
    check(err is not None and 'uzum_order_busy' in err, 'create: тот же order_ref на другой адрес — ошибка', err)

    print('== статус и callback')
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claim/info', {'id': d1}, op)
    check(err is None and b['status'] == 'ready_for_approval' and b['ok'] and len(c) == 1, 'info: свежий статус из Uzum', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claim/info', {'id': d1}, guest)
    check(err is not None and 'uzum_no_access' in err, 'info: чужому нельзя', err)
    claim_id = sqlv("select claim_id from project.uzum_claims where id = '%s';" % d1)
    ts1, ts2 = '2026-11-24T10:00:00Z', '2026-11-24T10:00:05Z'
    b, log, err, c = call(eps, 'POST', 'v1/uzum/callback', {'secret': 'wrong', 'claim_id': claim_id,
                                                           'status': 'ready_for_approval', 'updated_ts': ts1})
    check(err is None and b['note'] == 'ignored' and not c, 'callback: чужой секрет — игнор, в Uzum не ходим', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/callback', {'secret': secret, 'claim_id': claim_id,
                                                           'status': 'ready_for_approval', 'updated_ts': ts1})
    check(err is None and b['note'] == 'applied' and len(c) == 1 and '/claims/info' in c[0]['url'],
          'callback: свой секрет (после подделки с теми же полями) — claims/info и применить', (b, err, c))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/callback', {'secret': secret, 'claim_id': claim_id,
                                                           'status': 'ready_for_approval', 'updated_ts': ts1})
    check(err is None and b['note'] == 'ignored' and not c, 'callback: повтор — отброшен', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/callback', {'claim_id': '0' * 32, 'status': 'accepted', 'updated_ts': ts1})
    check(err is None and b['note'] == 'ignored' and not c, 'callback: неизвестная заявка — игнор', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/callback', {'claim_id': claim_id, 'status': 'ready_for_approval', 'updated_ts': ts2})
    ev = sqlv("select coalesce(secret_ok::text, 'null') from project.uzum_claim_events where source = 'callback' "
              "and claim_id = '%s' and updated_ts = '%s';" % (claim_id, ts2))
    check(err is None and b['note'] == 'applied' and len(c) == 1 and ev == 'null',
          'callback без secret (если платформа не отдаёт query) — всё равно через claims/info', (b, err, ev))
    bad = sqlv("select string_agg(note, ',' order by id) from project.uzum_claim_events where source = 'callback_bad';")
    check(bad == 'wrong secret,unknown claim', 'callback: подделки записаны как callback_bad', bad)

    print('== подтверждение, курьер, отмена')
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/accept', {'id': d1}, guest)
    check(err is not None and 'uzum_no_access' in err and not c, 'accept: гостю нельзя', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/accept', {'id': d1}, op)
    check(err is None and b['ok'] and b['stage'] == 'searching' and b['accepted_at'] and b['display_id'],
          'accept: поиск курьера, статус %s, display_id %s' % ((b or {}).get('status'), (b or {}).get('display_id')), (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/accept', {'id': d1}, op)
    check(err is not None and 'uzum_inappropriate_status' in err and not c, 'accept: повторно — наша ошибка', err)
    time.sleep(2)
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claim/courier', {'id': d1}, op)
    check(err is None and b['ok'] and b['phone'] is None and b['lat'] is None and len(c) == 3,
          'courier: курьера ещё нет — 409 на позицию и телефон не ошибка (статус %s)' % (b or {}).get('status'), (b, err, c))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': d1}, guest)
    check(err is not None and 'uzum_no_access' in err and not c, 'cancel: гостю нельзя', err)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': d1}, op)
    check(err is None and b['ok'] and b['status'] == 'cancelled' and b['is_final'] and b['cancel_state'] == 'free'
          and len(c) == 2, 'cancel: бесплатно — cancel-info, cancel', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': d1}, op)
    check(err is not None and 'uzum_inappropriate_status' in err, 'cancel: повторно — наша ошибка', err)
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claim/info', {'id': d1}, op)
    check(err is None and b['status'] == 'cancelled' and b['finished_at'], 'info: в Uzum тоже cancelled', (b, err))
    ev = sqlv("select string_agg(coalesce(old_status, '-') || '>' || status, ' ' order by id) from project.uzum_claim_events "
              "where claim_row = '%s' and status is not null and source not like 'callback%%';" % d1)
    check(ev.startswith('->new new>ready_for_approval ready_for_approval>') and ev.endswith('>cancelled'), 'события: путь статусов', ev)
    b = run_sql("select * from project.uzum_save('%s', '%s', 'info', 'not json')" % (OPER, d1), 'map')
    check(b['ok'] is False and b['error_code'] == 'platform_result', 'save: ответ платформы не JSON — ошибка platform_result', b)

    print('== cron: повтор create и опрос')
    ref2 = 'EMU-' + uuid.uuid4().hex[:6].upper()
    row = run_sql("select * from project.uzum_create_prepare('%s', '%s', null, '%s', 'Тест: получатель', '+998000000002', "
                  "'улица Кончилик, 47, Ташкент', %s, %s, null, null, null, null, null, 'Тест easy-trip: повтор create из cron', "
                  "null, null, null, null)" % (OPER, place, ref2, DST[0], DST[1]), 'map')
    d2 = row['id']
    psql('microservice', "update project.uzum_claims set updated_at = now() - interval '1 minute' where id = '%s';" % d2)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/sync')
    st = run_sql("select status, claim_id, create_attempts from project.uzum_claims where id = '%s'" % d2, 'map')
    if st['status'] == 'error':
        print('  (стенд не принял повтор create — ещё раз)')
        psql('microservice', "update project.uzum_claims set status = 'new', finished_at = null, updated_at = now() - interval '1 minute' where id = '%s';" % d2)
        b, log, err, c = call(eps, 'POST', 'v1/uzum/sync')
        st = run_sql("select status, claim_id, create_attempts from project.uzum_claims where id = '%s'" % d2, 'map')
    check(err is None and b['checked'] >= 1 and st['status'] == 'ready_for_approval' and st['claim_id'],
          'sync: потерянный ответ create — повтор тем же request_id, заявка создана', (b, err, st))
    psql('microservice', "update project.uzum_claims set sync_at = now() - interval '20 minutes', last_info_at = now() - interval '20 minutes', "
                         "created_at = now() - interval '20 minutes', last_callback_at = null where id = '%s';" % d2)
    b, log, err, c = call(eps, 'POST', 'v1/uzum/sync')
    fresh = sqlv("select last_info_at > now() - interval '1 minute' from project.uzum_claims where id = '%s';" % d2)
    check(err is None and b['checked'] >= 1 and fresh == 't' and any('/claims/info' in x['url'] for x in c),
          'sync: давно без новостей — claims/info', (b, err))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/sync')
    check(err is None and b['checked'] == 0 and not c, 'sync: сразу повторно — делать нечего', (b, err))
    fake_paid = json.dumps({'cancel_info': {'cancel_state': 'paid', 'price': '36000.00'}})
    r = run_sql("select * from project.uzum_cancel_decide('%s', '%s', %s, false)" % (OPER, d2, lit(fake_paid)), 'map')
    e = run_sql("select error_code, cancel_price from project.uzum_claims where id = '%s'" % d2, 'map')
    check(r['calls'] == '[]' and e['error_code'] == 'paid_cancel_not_confirmed' and e['cancel_price'] == 36000,
          'cancel: платная без allow_paid — не отменяем, цену показываем', (r, e))
    r = run_sql("select * from project.uzum_cancel_decide('%s', '%s', %s, true)" % (OPER, d2, lit(fake_paid)), 'map')
    paid = json.loads(r['calls'])
    check(len(paid) == 1 and '/claims/cancel?' in paid[0]['url'] and json.loads(paid[0]['body'])['cancel_state'] == 'paid',
          'cancel: платная с allow_paid — вызов cancel с paid', r['calls'][:200].replace(paid[0]['token'] if paid else '-', '***'))
    b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': d2}, op)
    check(err is None and b['status'] == 'cancelled' and b['ok'], 'cancel: заявка из cron отменена', (b, err))

    print('== без позиций и с auto_accept')
    b, log, err, c = call_retry(eps, 'POST', 'v1/uzum/claim/create',
                                {'place_id': place, 'recipient_name': 'Тест: получатель', 'recipient_phone': '+998000000002',
                                 'address': 'улица Кончилик, 47, Ташкент', 'lon': DST[0], 'lat': DST[1],
                                 'comment': 'Тест easy-trip: auto_accept, сразу отмена', 'auto_accept': True}, op)
    d3 = (b or {}).get('id')
    check(err is None and b['ok'] and b['claim_id'] and b['external_order_id'].startswith('ET-'),
          'create без items и order_ref: позиция «Заказ ET-…» с ценой 0 принята', (b, err))
    if d3:
        time.sleep(2)
        b, log, err, c = call(eps, 'GET', 'v1/uzum/claim/info', {'id': d3}, op)
        check(err is None and b['stage'] in ('searching', 'to_pickup') and b['accepted_at'],
              'auto_accept: Uzum сам подтвердил (статус %s)' % (b or {}).get('status'), (b, err))
        b, log, err, c = call(eps, 'POST', 'v1/uzum/claim/cancel', {'id': d3}, op)
        check(err is None and b['status'] == 'cancelled', 'auto_accept: отменена', (b, err))

    print('== списки')
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claims', {'place_id': place, 'limit': '10'}, op)
    check(err is None and {d1, d2} <= {x['id'] for x in b} and all('request' not in x for x in b), 'claims: доставки оператора', err)
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claims', {}, guest)
    check(err is None and b == [], 'claims: гостю пусто', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claims', {'active': 'true'}, adm)
    check(err is None and all(not x['is_final'] for x in b), 'claims: active=true — только активные', (b, err))
    b, log, err, c = call(eps, 'GET', 'v1/uzum/claims', {'status': 'cancelled'}, adm)
    check(err is None and len(b) >= 3 and all(x['stage'] == 'cancelled' for x in b), 'claims: фильтр по этапу', err)

    left = cancel_leftovers(eps)
    active = sqlv("select count(*) from project.uzum_claims where claim_id is not null and finished_at is null;")
    check(active == '0', 'на стенде не осталось активных заявок (отменено в конце: %d)' % left, active)

    print('== итог эмуляции:', 'ВСЁ ПРОШЛО' if fails == 0 else 'ОШИБОК: %d' % fails)
    summary = {}
    for x in http_log:
        k = '%s %s → %s' % (x['method'], re.sub(r'\?.*', '', x['url'].split('/integration')[-1]), x['http'])
        summary[k] = summary.get(k, 0) + 1
    print('вызовы Uzum:', json.dumps(summary, ensure_ascii=False, indent=1))
    sys.exit(1 if fails else 0)


main()
