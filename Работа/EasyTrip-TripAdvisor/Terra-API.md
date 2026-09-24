---
tags: [работа, easy-trip, tripadvisor, api]
date: 2026-09-24
---

# TripAdvisor Terra API

Новый API TripAdvisor, замена Content API. Документация: `https://docs.terra.tripadvisor.com`
(индекс — `/llms.txt`, к любой странице можно дописать `.md`). Разобрано 2026-09-24.
Обзор задачи: [[00-Обзор]].

## Старый Content API

- Официальный FAQ Terra: Content API отключается, ключи перестают работать **31.08.2026**.
- Ключ Content API в Terra не работает: новый аккаунт на `tripadvisor.com/developers`,
  пакет Discover, новый ключ из Terra Dashboard.

## Основное

- Базовый URL: `https://terra.tripadvisor.com/api`, во всех запросах `version=1`.
- Ключ — **в заголовке** `X-API-Key` (не в URL). В конструкторе — поле `headers` стадии HTTP Request.
- Ошибки: `401` (нет/неверный/выключенный ключ, текст в `detail`), `403` (эндпоинт не входит
  в пакет, текст в `message`), `404` (объект не в allowlist), `429` (лимит).
- Пустые поля в ответе **отсутствуют**, а не `null` — проверять наличие.

## Эндпоинты

| Эндпоинт | Что даёт | Allowlist | Тарификация |
|---|---|---|---|
| `GET /catalog/locations/nearby` | весь каталог в круге/прямоугольнике, краткие данные | **не нужен** | за каждый объект в ответе |
| `GET /catalog/locations/search` | то же по тексту | не нужен | за каждый объект |
| `GET /locations/{id}` | полные данные | нужен (иначе 404) | 1 за объект |
| `GET /locations?id=1,2,3` | полные данные пачкой, ответ `{data: [...]}` | нужен (не свои — пропускаются) | за каждый объект |
| `GET /locations/{id}/photos` | фото, постранично (`size` по умолч. 100) | нужен | 1 за вызов |
| `GET /locations/nearby`, `/locations/search` | как catalog, но только allowlist | нужен | за каждый объект |
| `GET/POST /allowlist` | список разрешённых ID (APPEND / DELETE / OVERWRITE) | — | не тарифицируется (если доступен) |

### `catalog/locations/nearby` — главное для обхода города

- Область: `lat`+`lon`+`radius`+`unit` (радиус ≤ 8 км) **или** прямоугольник
  `sw_lat`, `sw_lon`, `ne_lat`, `ne_lon`. Смешивать нельзя (400).
- `category`: `RESTAURANT` / `HOTEL` / `ATTRACTION`.
- **Пагинация есть**: `page` (с 1), `size` ≤ 20, **без ограничения глубины** (у некаталожного
  `/locations/nearby` — не дальше 40-го результата). Ответ: `{data: [...], pagination: {page, size,
  total_elements, total_pages}}` → с первой страницы известно, сколько всего ресторанов в области.
- Сортировка по умолчанию `rating,desc` (лучшие первыми); `distance` — только для круга.
- `min_rating`, `locale` (повторяемый).
- Элемент: `{distance_kilometers, distance_miles, bearing, location: {id, names[], addresses[],
  coordinates, descriptions[], geo, geo_id, overall_rating, urls}}`.

Ограничение старого API «10 результатов без пагинации» в Terra **не действует**.

### `locations/{id}` — поля

`id`, `names[]` (`language`, `value`, `primary`), `descriptions[]`, `addresses[]`
(`formatted`, `street_address`, `city`, `language`…), `coordinates` (`latitude`, `longitude`),
`phone_numbers[]` (`type`, `value`), `official_email`, `urls` (`official`, `menu`,
`tripadvisor.main`…), `categories[]`, `attributes[]` (удобства: `id`, `name`, `type`),
`opening_hours` (`periods[]`: `day_of_week` = `Monday`…`Sunday`, `opens`/`closes` `HH:MM`;
`formatted[]`, `timezone`), `price_level` (`Cheap Eats` / `Mid Range` / `Fine Dining`),
`traveler_ratings.overall` (`rating`, `count`), `rankings[]`, `awards[]`, `status.value`
(`OPEN` / `CLOSED` / `TEMPORARILY_CLOSED`), `photos.total_count`.

### `locations/{id}/photos` — поля

`data[]`: `id`, `caption`, `photo` (`original_size_url`, `original_width/height`, `media_type`),
`source.name` (`Traveler` / `Management` — фото владельца лучше брать главным), `user`, `publish_ts`.

## Языки

`locale` повторяемый, в порядке приоритета: `locale=ru-RU&locale=en-US` → `names`,
`descriptions`, `addresses` приходят по записи на каждый язык **в одном вызове**
(оплата за объект, не за язык). Подписи справочников (категории, награды) — только по первому
локалю. Узбекского нет.

## Лимиты

| | Discover |
|---|---|
| Общий темп | 10 запросов/с |
| Суточная квота | 10 000, окно — скользящие 24 ч от первого вызова |
| Поиск и nearby (все четыре, общий лимит) | **1 запрос/с**, всплеск 5, 86 400 в сутки |

`429` — не повторять сразу, ждать с нарастающей паузой.

## Цены (Discover)

- Первые **1 000 тарифицируемых объектов — бесплатно, один раз на аккаунт** (не ежемесячно).
- Дальше за объект: $0.015 (до 1 000 в месяц), дешевле с объёмом, от 5 001 — $0.009.
- Ошибки 4xx/5xx не тарифицируются. В Dashboard можно поставить суточный лимит.

## Условия

- Caching Policy: копировать, скачивать, хранить контент нельзя, кроме Location ID.
- Photos: `original_size_url` — ссылка CDN; скачивать и размещать у себя фото запрещено,
  нужный размер — параметрами ресайза CDN.
- Linking Policy: фото, название и число отзывов должны ссылаться на страницу объекта на TripAdvisor.
- Бренд-гайд: логотип и атрибуция TripAdvisor.

Решение пользователя (2026-09-24): импорт делаем, условия известны.

## CORS фото

Проверено 2026-09-24: `media-cdn.tripadvisor.com` и `dynamic-media-cdn.tripadvisor.com` отдают
`Access-Control-Allow-Origin: *` → браузер может скачать фото через `fetch`. С какого домена
приходят фото в Terra — проверить на первом ответе.
