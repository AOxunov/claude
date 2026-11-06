"""Эмулятор стадий platon для P02: читает эндпоинты из локального platon, подставляет #поле,
:стадия.поле и $user, проверяет access_condition, выполняет SQL в microservice, вместо random.org
отвечает сам (проверив тело запроса), JS-стадию JSON.parse(variables.x.value) выполняет как есть.
Каждая стадия — отдельный вызов psql (своя транзакция).
Запуск: python -I emu.py <папка для временных файлов>
"""
import datetime
import json
import os
import re
import subprocess
import sys

PSQL = 'D:/tools/pgsql17/bin/psql.exe'
ENV = dict(os.environ, PGHOST='127.0.0.1', PGPORT='5435', PGUSER='postgres', PGCLIENTENCODING='UTF8')
WORK = sys.argv[1]
ADMIN = '00000000-0000-4000-8000-0000000000aa'
GUEST = '00000000-0000-4000-8000-0000000000bb'
TOKEN = re.compile(r'(?<!:):([A-Za-z_]\w*)((?:\.[A-Za-z_]\w*)*)|#([A-Za-z_]\w*)|\$user\.([A-Za-z_]\w*)')
sys.stdout.reconfigure(encoding='utf-8')

fails = 0
random_requests = []


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
    return TOKEN.sub(rep, sql)


def subst_text(text, params, vars_):
    def rep(m):
        if m.group(1):
            v = resolve(vars_, m.group(1), m.group(2))
        elif m.group(3):
            v = params.get(m.group(3))
        else:
            v = None
        if v is None:
            return 'null'
        if isinstance(v, bool):
            return 'true' if v else 'false'
        if isinstance(v, (dict, list)):
            return json.dumps(v, ensure_ascii=False)
        return str(v)
    return TOKEN.sub(rep, text)


def run_sql(sql, rtype):
    if rtype == 'list':
        q = "select coalesce(json_agg(t), '[]'::json)::text from (%s) t;\n" % sql
    else:
        q = "select coalesce((select row_to_json(t)::text from (%s) t limit 1), 'null');\n" % sql
    v = json.loads(psql('microservice', q).strip())
    if rtype == 'object' and isinstance(v, dict):
        v = next(iter(v.values()), None)
    return v


def eval_cond(c, vars_):
    if not c:
        return True
    c = c.strip()
    neg = c.startswith('!')
    if neg:
        c = c[1:].strip()
    m = re.fullmatch(r':([A-Za-z_]\w*)((?:\.[A-Za-z_]\w*)*)', c)
    if not m:
        raise StageError('условие не поддержано эмулятором: ' + c)
    v = resolve(vars_, m.group(1), m.group(2))
    if not isinstance(v, bool):
        raise StageError('условие не boolean: %s = %r' % (c, v))
    return (not v) if neg else v


def fake_random(a, params, vars_, data):
    if a.get('resource_url') != 'https://api.random.org/json-rpc/4/invoke' or a.get('http_method') != 'POST':
        raise StageError('HTTP-стадия не к random.org')
    if set(a) != {'resource_url', 'http_method', 'content_type', 'request_body', 'http_headers', 'http_request_response'}:
        raise StageError('ключи HTTP-стадии: %s' % sorted(a))
    req = json.loads(subst_text(a['request_body'], params, vars_))  # тело — валидный JSON
    p = req['params']
    if req['method'] != 'generateSignedDecimalFractions' or p['decimalPlaces'] != 14 or p['replacement'] is not True:
        raise StageError('не тот запрос к random.org: %s' % req)
    if not isinstance(p['n'], int) or not p['apiKey'] or set(p['userData']) != {'draw_id', 'entries_hash'}:
        raise StageError('параметры запроса: %s' % p)
    random_requests.append(req)
    n = p['n']
    values = (data or [0.5] * n)[:n]
    return {'jsonrpc': '2.0',
            'result': {'random': {'method': req['method'], 'hashedApiKey': 'emu', 'n': n, 'decimalPlaces': 14,
                                  'replacement': True, 'pregeneratedRandomization': None, 'data': values,
                                  'license': {'type': 'developer',
                                              'text': 'Random values licensed strictly for development and testing only',
                                              'infoUrl': None},
                                  'licenseData': None, 'userData': p['userData'], 'ticketData': None,
                                  'completionTime': '2026-11-06 12:00:00Z', 'serialNumber': len(random_requests)},
                       'signature': 'emu-signature', 'cost': 0, 'bitsUsed': 47 * n, 'bitsLeft': 249953,
                       'requestsLeft': 999, 'advisoryDelay': 1000},
            'id': req['id']}


def run_js(a, vars_):
    js = json.loads(a['js_eval'])
    m = re.fullmatch(r'return\s+JSON\.parse\(variables\.(\w+)\.value\)', js['code'].strip())
    if not m or js['es5'] != 'return (function(){return JSON.parse(variables.%s.value)})();' % m.group(1):
        raise StageError('JS-стадия не поддержана: %s' % js)
    return vars_[m.group(1)]


def call(eps, method, path, params=None, user=None, random_data=None):
    ep = eps[(method, path)]
    params = params or {}
    user = user or {}
    vars_ = {}
    log = []
    try:
        for st in ep['stages']:
            if st['state'] != 1:
                continue
            if not eval_cond(st['cond'], vars_):
                log.append(st['alias'] + '-skip')
                continue
            a = st['attributes']
            if st['handler'] == 'sql_select':
                if set(a) != {'datasource', 'sql', 'sql_result_type'} or a['datasource'] != 'project':
                    raise StageError('ключи SQL-стадии: %s' % sorted(a))
                vars_[st['alias']] = run_sql(subst_sql(a['sql'], params, vars_, user), a['sql_result_type'])
            elif st['handler'] == 'http_request_handler':
                vars_[st['alias']] = fake_random(a, params, vars_, random_data)
            elif st['handler'] == 'js_eval_handler':
                vars_[st['alias']] = run_js(a, vars_)
            else:
                raise StageError('handler ' + st['handler'])
            log.append(st['alias'])
    except StageError as e:
        return None, log, str(e)
    return vars_.get('_body'), log, None


def check(cond, label, extra=''):
    global fails
    if cond:
        print('  ok:', label)
    else:
        fails += 1
        print('  FAIL:', label, extra)


def main():
    rows = psql('platon', """
select json_agg(json_build_object(
        'method', e.method, 'path', e.path, 'auth', e.auth_handler, 'tx', e.has_transaction,
        'stages', (select json_agg(json_build_object('sort', s.sort_order, 'alias', s.alias, 'handler', s.handler,
                                                     'attributes', s.attributes, 'cond', s.access_condition,
                                                     'state', s.state, 'ser', s.serialize_result)
                                   order by s.sort_order)
                   from api_stages s where s.endpoint_id = e.id)))
from api_endpoints e
where e.path = 'v1/ti/bonus/draws/daily' or e.path like 'v1/ti/bonus/admin/%';
""").strip()
    eps = {(x['method'], x['path']): x for x in json.loads(rows)}
    print('эндпоинтов из platon:', len(eps), ' стадий:', sum(len(x['stages']) for x in eps.values()))
    today = datetime.date.fromisoformat(psql('microservice', "select (now() at time zone 'Asia/Tashkent')::date;").strip())
    adm = {'id': ADMIN, 'username': 'emu-admin'}
    guest = {'id': GUEST, 'username': 'emu-guest'}

    print('== доступ')
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/me', user=guest)
    check(err is None and b['user_id'] == GUEST and b['is_admin'] is False, 'me: гость, не администратор', (b, err))
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/draws', user=guest)
    check(err is not None and 'Нет доступа' in err and GUEST in err, 'draws гостю — ошибка с его id', err)
    psql('microservice', "insert into project.ti_bonus_admins (user_id, note) values ('%s', 'эмуляция') on conflict do nothing;" % ADMIN)
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/me', user=adm)
    check(err is None and b['is_admin'] is True and b['username'] == 'emu-admin', 'me: администратор', (b, err))

    print('== cron ежедневных')
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/draws/daily')
    check(err is None and log == ['prep', 'random-skip', 'run-skip', 'run_empty', '_body'] and b['status'] == 'DONE'
          and b['created'] == 1 and b['audience'] == 'TOURIST', 'запуск 1: создан сегодняшний, позавчерашний пустой проведён', (log, b, err))
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/draws/daily')
    check(err is None and b['status'] == 'DONE' and b['created'] == 0, 'запуск 2: вчерашний проведён', (b, err))
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/draws/daily')
    check(err is None and log == ['prep', 'random-skip', 'run-skip', 'run_empty-skip', '_body'] and b['draw_id'] is None
          and 'нет' in b['note'], 'запуск 3: делать нечего', (log, b, err))
    dd = psql('microservice', "select project.ti_bonus_draw_create('TOURIST', now() - interval '120 days', now(), array [1], "
                              "'Эмуляция: ежедневный с участниками', 'DAILY');").strip()
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/draws/daily')
    check(err is None and b['draw_id'] == dd and b['status'] == 'FROZEN' and 'ключ' in (b['error'] or ''),
          'запуск 4: нет ключа — ошибка в ответе, розыгрыш зафиксирован', (b, err))
    psql('microservice', "update project.ti_bonus_settings set value = 'emu-key' where code = 'random_org_api_key';"
                         "update project.ti_bonus_draws set attributes = (attributes::jsonb - 'retry_at')::json where id = '%s';" % dd)
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/draws/daily', random_data=[0.25])
    req = random_requests[-1] if random_requests else {}
    check(err is None and log == ['prep', 'random', 'run', 'run_empty-skip', '_body'] and b['status'] == 'DONE'
          and b['error'] is None, 'запуск 5: random.org → проведён', (log, b, err))
    check(req.get('params', {}).get('apiKey') == 'emu-key' and req['params']['n'] == 1
          and req['params']['userData']['draw_id'] == dd, 'тело запроса к random.org: ключ из настроек, n, userData')

    print('== админка: розыгрыш за период')
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/create',
                       {'audience': 'TOURIST', 'date_from': str(today - datetime.timedelta(days=120)),
                        'date_to': (today - datetime.timedelta(days=1)).strftime('%d.%m.%Y'), 'prizes': [3, 2],
                        'title': 'Эмуляция: период'}, adm)
    check(err is None and b['status'] == 'DRAFT' and b['prizes'] == '3.00 + 2.00' and b['kind'] == 'PERIOD',
          'create: черновик, призы из JSON-массива', (b, err))
    dp = b['id'] if b else None
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/prizes', {'id': dp, 'prizes': '4, 1'}, adm)
    check(err is None and b['prizes'] == '4.00 + 1.00', 'prizes: строкой «4, 1»', (b, err))
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/draws', {'audience': 'TOURIST', 'kind': 'PERIOD', 'status': 'DRAFT', 'limit': '10'}, adm)
    check(err is None and any(r['id'] == dp for r in b), 'draws: фильтры строками из GET', err)
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/draws', {}, adm)
    check(err is None and len(b) >= 5, 'draws без параметров', err)
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/run', {'id': dp}, adm, random_data=[0.1, 0.9])
    check(err is None and log == ['prep', 'random', 'run', 'run_empty-skip', 'draw', '_body'] and b['status'] == 'DONE'
          and len(b['winners']) == b['prizes_count'] >= 1 and b['random']['serialNumber'] == len(random_requests),
          'run: фиксация → random.org → победители, ответ — розыгрыш целиком', (log, b if err else '', err))
    winners = b['winners'] if b else []
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/run', {'id': dp}, adm)
    check(err is not None and 'DONE' in err, 'run проведённого — ошибка', err)
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/draw', {'id': dp}, adm)
    check(err is None and b['id'] == dp and b['signature'] == 'emu-signature' and len(b['prizes']) == 2,
          'draw: карточка через JS-стадию', err)
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/create',
                       {'audience': 'OBJECT', 'date_from': str(today + datetime.timedelta(days=10)),
                        'date_to': str(today + datetime.timedelta(days=20)), 'prizes': '1'}, adm)
    d2 = b['id'] if b else None
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/run', {'id': d2}, adm)
    check(err is not None and 'не закончился' in err, 'run до конца периода — ошибка', err)
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/cancel', {'id': d2, 'reason': 'эмуляция'}, adm)
    check(err is None and b['status'] == 'CANCELLED', 'cancel', (b, err))
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/draw/run', {'id': dp}, guest)
    check(err is not None and 'Нет доступа' in err, 'run гостю — ошибка', err)

    print('== админка: фонд, выплаты, мониторинг')
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/fund', {}, adm)
    check(err is None and [r['fund'] for r in b] == ['TOURIST', 'OBJECT'], 'fund: две строки', err)
    bal = b[0]['balance_usd'] if b else 0
    b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/fund/adjust', {'fund': 'TOURIST', 'amount_usd': -1, 'comment': 'эмуляция: реклама'}, adm)
    check(err is None and abs(b['balance_usd'] - (bal - 1)) < 0.005, 'adjust −$1', (b, err))
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/fund/ledger', {'fund': 'TOURIST', 'op_type': 'ADJUST', 'limit': '3'}, adm)
    check(err is None and b[0]['amount_usd'] == -1 and b[0]['created_by'] == ADMIN, 'ledger: строка ADJUST', err)
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/winners', {'payout_status': 'PENDING'}, adm)
    check(err is None and {w['id'] for w in winners} <= {r['id'] for r in b}, 'winners: победители к выплате', err)
    if winners:
        b, log, err = call(eps, 'POST', 'v1/ti/bonus/admin/winner/paid',
                           {'id': winners[0]['id'], 'paid_amount': 50601.72, 'paid_currency': 'UZS', 'paid_rate': 12650.43,
                            'payout_ref': 'emu-1'}, adm)
        check(err is None and b['payout_status'] == 'PAID' and b['payout_ref'] == 'emu-1', 'winner/paid', (b, err))
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/errors', {'limit': '5'}, adm)
    check(err is None and len(b) >= 1 and b[0]['source'] == 'draw_daily', 'errors: последние сбои', err)
    b, log, err = call(eps, 'GET', 'v1/ti/bonus/admin/health', {}, adm)
    check(err is None and b['random_key_set'] is True and b['chain_ok'] is True and b['card_mismatches'] == 0,
          'health', (b, err))

    print('== итог эмуляции:', 'ВСЁ ПРОШЛО' if fails == 0 else 'ОШИБОК: %d' % fails)
    req = dict(random_requests[0]) if random_requests else {}
    if req:
        req['params'] = dict(req['params'], apiKey='***')
        print('пример тела запроса к random.org:', json.dumps(req, ensure_ascii=False))
    sys.exit(1 if fails else 0)


main()
