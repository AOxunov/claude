-- =====================================================================================
-- Доставка Uzum: подключить точку забора (токен) и операторов. База microservice, сервер.
-- Шаблон: значения в <угловых скобках> вписываются только в консоли DataGrip.
-- Токен в этот файл, заметки и git не записывать.
-- Запускать по одному блоку (выделить → Ctrl+Enter), не весь файл.
-- =====================================================================================

-- 0. Свой id: GET https://easy-trip.com/endpoint/api/v1/uzum/me с токеном easy-trip → user_id.

-- 1. Администратор доставки: все объекты, диагностика v1/uzum/diag
insert into project.uzum_operators (user_id, place_id, note)
values ('<user_id>', null, '<кто это>');

-- 2. Оператор одного объекта (сотрудник ресторана или магазина): вызывает и отменяет курьера
insert into project.uzum_operators (user_id, place_id, note)
values ('<user_id>', '<place_id>', '<кто это>');

-- 3. Точка забора с токеном Uzum. Токен Uzum выдаёт на точку (филиал), без слова Bearer.
--    Адрес и координаты — откуда курьер забирает заказ; по координатам Uzum определяет город.
--    У places координаты бывают пустыми и неточными, имя и адрес — пустыми строками: проверить
--    на карте, при нужде вписать руками. Если имени или адреса нет, вставка падает на not null.
--    Тестовый токен — только с объектом в Ташкенте. На стенде проверен забор с 69.20515, 41.32202
--    (улица Кукча Дарвоза, 377, Ташкент) и телефон +998000000001. Адрес доставки в коллекции Postman
--    в ~1 км от этой точки. Для теста можно вписать эти значения вместо данных объекта.
insert into project.uzum_points (place_id, branch_id, env, token, name, phone, address, lon, lat, comment, note)
select p.id,
       null,                                         -- или place_branches.id, если точка — филиал
       'test',                                       -- 'prod' — для боевого токена
       '<токен Uzum>',
       coalesce(nullif(p.name_ru, ''), nullif(p.name_uz, ''), nullif(p.name_en, '')), -- контакт: его видит курьер
       '<+998XXXXXXXXX — телефон точки>',
       coalesce(nullif(p.address_ru, ''), nullif(p.address_uz, ''), nullif(p.address_en, '')),
       p.longitude,
       p.latitude,
       null,                                         -- комментарий курьеру: «вход со двора»
       'Тестовый токен Uzum, <дата>'
from project.places p
where p.id = '<place_id>';

-- 4. Проверка: точки без токенов, операторы
select pt.id, pt.place_id, pt.branch_id, pt.env, pt.name, pt.phone, pt.address, pt.lon, pt.lat, pt.state,
       length(pt.token) as token_len
from project.uzum_points pt
order by pt.created_at desc;

select o.user_id, o.place_id, o.note, o.created_at
from project.uzum_operators o
order by o.created_at desc;

-- 5. Переход на боевой токен: тестовую точку выключить, боевую добавить блоком 3 с env = 'prod'.
--    Активная точка у объекта (филиала) может быть только одна — сначала выключить старую.
update project.uzum_points
set state      = 0,
    updated_at = now()
where place_id = '<place_id>'
  and env = 'test'
  and state = 1;
