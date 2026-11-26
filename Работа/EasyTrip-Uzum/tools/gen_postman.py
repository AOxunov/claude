# Генератор коллекции Postman для проверки доставки Uzum на сервере easy-trip.
#   python -I tools/gen_postman.py Uzum-easy-trip.postman_collection.json
# Токенов в коллекции нет: et_token пустой, его вписывают в Postman в Current value.
import json
import sys

DST_LON, DST_LAT = 69.21686, 41.3174          # адрес доставки ~1 км от центра Ташкента
DST_ADDRESS = 'Ташкент, тестовый адрес'

SAVE_ID = [
    '// id доставки -> переменная delivery_id для следующих запросов',
    'const j = pm.response.json();',
    'const d = j && j.data !== undefined ? j.data : j;',
    'const row = Array.isArray(d) ? d[0] : d;',
    'if (row && row.id) {',
    '    pm.collectionVariables.set("delivery_id", row.id);',
    '    console.log("delivery_id = " + row.id);',
    '}',
]


def url(path, query=None):
    raw = '{{base}}/' + path
    u = {'raw': raw, 'host': ['{{base}}'], 'path': path.split('/')}
    if query:
        u['query'] = [dict(q) for q in query]
        on = ['%s=%s' % (q['key'], q['value']) for q in query if not q.get('disabled')]
        if on:
            u['raw'] = raw + '?' + '&'.join(on)
    return u


def get(name, path, desc, query=None):
    return {'name': name, 'request': {'method': 'GET', 'header': [], 'url': url(path, query), 'description': desc}}


def post(name, path, desc, body, tests=None):
    item = {'name': name,
            'request': {'method': 'POST',
                        'header': [{'key': 'Content-Type', 'value': 'application/json'}],
                        'body': {'mode': 'raw', 'raw': json.dumps(body, ensure_ascii=False, indent=2),
                                 'options': {'raw': {'language': 'json'}}},
                        'url': url(path), 'description': desc}}
    if tests:
        item['event'] = [{'listen': 'test', 'script': {'type': 'text/javascript', 'exec': tests}}]
    return item


PLACE_OFF = [{'key': 'place_id', 'value': '{{place_id}}', 'disabled': True}]

items = [
    get('01 me — свой user_id', 'v1/uzum/me',
        'Свой user_id — его вписать в блок 1 шаблона 03 (администратор доставки). '
        'После блока 1 is_admin = true.'),
    get('02 diag — проверка платформы', 'v1/uzum/diag',
        'Только администратору. Ждём info404_code = not_found и calc_string_ok = true; '
        'что делать при другом ответе — шаг 5 в 00-Обзор.md.', PLACE_OFF),
    get('03 points — подключённые точки', 'v1/uzum/points',
        'Точки забора без токенов. Должна быть тестовая точка из блока 3 шаблона 03 (env = test).', PLACE_OFF),
    post('04 calculate — цена', 'v1/uzum/calculate',
         'Цена доставки от точки до адреса, ничего не создаёт. Ждём ok = true и price.',
         {'place_id': '{{place_id}}', 'lon': DST_LON, 'lat': DST_LAT, 'address': DST_ADDRESS,
          'taxi_class': 'courier'}),
    post('05 claim/create — черновик', 'v1/uzum/claim/create',
         'Черновик с ценой: stage = draft, курьера не ищет до accept. id доставки сохраняется '
         'в переменную delivery_id. order_ref каждый раз новый ({{$timestamp}}).',
         {'place_id': '{{place_id}}', 'order_ref': 'TEST-{{$timestamp}}',
          'recipient_name': 'Тест easy-trip', 'recipient_phone': '+998000000002',
          'address': DST_ADDRESS, 'lon': DST_LON, 'lat': DST_LAT,
          'comment': 'Тестовая доставка easy-trip',
          'items': [{'title': 'Тестовый заказ', 'quantity': 1, 'price': 10000, 'weight': 0.5}],
          'taxi_class': 'courier'},
         SAVE_ID),
    get('06 claim/info — статус', 'v1/uzum/claim/info', 'Доставка со свежим статусом из Uzum.',
        [{'key': 'id', 'value': '{{delivery_id}}'}]),
    post('07 claim/cancel — отмена', 'v1/uzum/claim/cancel',
         'Черновик отменяется бесплатно: ждём stage = cancelled. Тестовые доставки отменять в конце каждой проверки.',
         {'id': '{{delivery_id}}', 'allow_paid': False}),
    post('08 claim/accept — поиск курьера (только с Бахтиёром)', 'v1/uzum/claim/accept',
         'Только для полного прогона: начинает поиск курьера. На стенде курьеров нет — без Бахтиёра '
         'доставка повиснет в поиске; после проверки отменить (07).',
         {'id': '{{delivery_id}}'}),
    get('09 claim/courier — курьер', 'v1/uzum/claim/courier',
        'Имя, телефон, координаты, ссылка отслеживания. До назначения курьера пусто — это не ошибка.',
        [{'key': 'id', 'value': '{{delivery_id}}'}]),
    post('10 claim/cancel — платная отмена', 'v1/uzum/claim/cancel',
         'Только если 07 вернул error_code = paid_cancel_not_confirmed и cancel_price устраивает.',
         {'id': '{{delivery_id}}', 'allow_paid': True}),
    get('11 claims — незавершённые доставки', 'v1/uzum/claims',
        'В конце проверки тестовых доставок здесь быть не должно.',
        [{'key': 'active', 'value': 'true'}, {'key': 'limit', 'value': '20'}]),
]

collection = {
    'info': {
        'name': 'easy-trip — доставка Uzum Tezkor',
        'description': (
            'Проверка доставки Uzum на сервере easy-trip; порядок и ожидаемые ответы — 00-Обзор.md, '
            '«Проверка на сервере». Перед запуском в переменных коллекции вписать et_token (свой токен '
            'easy-trip — только в Current value, чтобы он не попал в экспорт) и place_id (объект тестовой '
            'точки из блока 3 шаблона 03). Генерирует tools/gen_postman.py.'),
        'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
    },
    'auth': {'type': 'bearer', 'bearer': [{'key': 'token', 'value': '{{et_token}}', 'type': 'string'}]},
    'variable': [
        {'key': 'base', 'value': 'https://easy-trip.com/endpoint/api'},
        {'key': 'et_token', 'value': ''},
        {'key': 'place_id', 'value': ''},
        {'key': 'delivery_id', 'value': ''},
    ],
    'item': items,
}

with open(sys.argv[1], 'w', encoding='utf-8', newline='\n') as fh:
    json.dump(collection, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
print('requests:', len(items))
