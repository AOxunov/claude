---
tags: [работа, easy-trip, конструктор, sql]
date: 2026-09-29
---

# API списка объектов easy-trip

`GET`-эндпоинт конструктора: список объектов из `places` с фильтром по типу и региону.
Таблицы — [[API-meal-place]] (DDL `places`, `place_images`), регионы — [[EasyTrip-TripAdvisor/00-Обзор|обзор TripAdvisor]] (раздел «Регионы»),
синтаксис стадий — [[Эндпоинты-easy-trip#Как устроен эндпоинт конструктора]].

Параметры (все необязательные):

| Параметр | Что | Пусто / мусор |
|---|---|---|
| `place_type` | значение enum `project.place_type`: `HOTEL`, `MEAL_PLACE`, `ATTRACTION`, `MOSQUE`, `PHOTO_POINT`, … | без фильтра; неизвестный тип → пустой список |
| `region_id` | `lists.id` при `type_id = 1` | без фильтра |
| `page`, `size` | страница с 1, размер 1–100 | `1`, `20` |

## Стадия `list` (`sql_select`, режим списка)

```sql
with prm as (select nullif(upper(trim(#place_type::varchar)), '')                        as place_type,
                    -- число приводим, только если строка из цифр: мусор не уронит запрос
                    case when trim(#region_id::varchar) ~ '^[0-9]{1,9}$'
                             then trim(#region_id::varchar)::integer end                  as region_id,
                    case when trim(#size::varchar) ~ '^[0-9]{1,3}$'
                             then least(greatest(trim(#size::varchar)::integer, 1), 100)
                         else 20 end                                                      as size,
                    case when trim(#page::varchar) ~ '^[0-9]{1,6}$'
                             then greatest(trim(#page::varchar)::integer, 1)
                         else 1 end                                                       as page)
select p.id,
       p.place_type::varchar as place_type,
       p.name_uz,
       p.name_ru,
       p.name_en,
       p.address_uz,
       p.address_ru,
       p.address_en,
       p.latitude,
       p.longitude,
       p.rating_avg,
       p.reviews_count,
       p.region_id,
       r.name4               as region_name_uz,
       r.name2               as region_name_ru,
       r.name3               as region_name_en,
       img.file_id           as image_file_id,
       img.url               as image_url,
       count(*) over ()      as total
from places p
         cross join prm
         left join lists r on r.type_id = 1 and r.id = p.region_id
         -- одна картинка: главная, иначе первая по sort_order
         left join lateral (select i.file_id, i.url
                            from place_images i
                            where i.place_id = p.id
                            order by i.is_main desc nulls last, i.sort_order nulls last
                            limit 1) img on true
where p.state = 1
  -- сравнение текстом: приведение неизвестной строки к enum дало бы ошибку вместо пустого списка
  and (prm.place_type is null or p.place_type::varchar = prm.place_type)
  and (prm.region_id is null or p.region_id = prm.region_id)
order by p.rating_avg desc nulls last, p.name_uz, p.id
limit (select size from prm) offset (select (page - 1) * size from prm)
```

- `p.state = 1` — только активные: `2` (на модерации) и `3` (отклонён) в выдачу не попадают.
- `count(*) over ()` — общее число строк до `limit`, одинаковое в каждой строке.
- `p.id` в `order by` — чтобы порядок был стабильным и строки не прыгали между страницами.

## Стадия `_body` (`js_eval_handler`)

```js
const data = variables.list;

// Список приходит массивом; одна строка может прийти объектом, пустой результат — пусто
let rows = [];
if (Array.isArray(data)) {
    rows = data;
} else if (data && data.id) {
    rows = [data];
}

const items = [];
for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    items.push({
        "id": String(r.id),
        "place_type": r.place_type,
        "name_uz": r.name_uz, "name_ru": r.name_ru, "name_en": r.name_en,
        "address_uz": r.address_uz, "address_ru": r.address_ru, "address_en": r.address_en,
        "latitude": r.latitude == null ? null : Number(String(r.latitude)),
        "longitude": r.longitude == null ? null : Number(String(r.longitude)),
        "rating_avg": r.rating_avg == null ? null : Number(String(r.rating_avg)),
        "reviews_count": r.reviews_count == null ? 0 : Number(String(r.reviews_count)),
        "region": r.region_id == null ? null : {
            "id": Number(String(r.region_id)),
            "name_uz": r.region_name_uz, "name_ru": r.region_name_ru, "name_en": r.region_name_en
        },
        "image": r.image_file_id || r.image_url ? { "file_id": r.image_file_id, "url": r.image_url } : null
    });
}

return {
    "items": items,
    "total": rows.length ? Number(String(rows[0].total)) : 0
};
```

## Проверить

- Что платформа подставляет вместо **непереданного** `#параметра` — `null` или ошибка.
  Если ошибка — фильтр без параметра работать не будет, нужен другой способ (например, `static_json` с умолчаниями).
- Есть ли `state` у `place_images` (мягкое удаление) — тогда добавить `and i.state = 1`.
- **`region_id` заполнен не у всех:** `v1/meal-place` его не пишет, поэтому рестораны могут
  выпадать из фильтра по региону. Сколько объектов без региона:
  ```sql
  select place_type, count(*) as total, count(region_id) as with_region
  from places
  where state = 1
  group by place_type
  order by place_type;
  ```
  Если пусто у многих — заполнить `region_id` по координатам (полигон `lists.geo_polygon`,
  если есть PostGIS) и дописать `region_id` в стадию `places` у `v1/meal-place`.
