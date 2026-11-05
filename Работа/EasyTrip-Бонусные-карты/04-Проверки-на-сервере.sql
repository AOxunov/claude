-- =====================================================================================
-- Проверки до и после накатки 01-DDL.sql на сервер. Только чтение, ничего не меняют.
-- База microservice. Выполнять по одному запросу (в DataGrip — курсор в запросе, Ctrl+Enter).
-- =====================================================================================


-- ---------------------------------------------------------------- ДО накатки

-- 1. Версия: нужна 13 или новее (на 02.11.2026 была 17)
select version();

-- 2. Права. Скрипт переходит на роль project (set local role project) и всё создаёт от её имени.
--    Нужно: роль project есть, мне можно на неё переходить, project владеет places и
--    realpay_transaction (новая колонка и триггеры) и может создавать объекты в схеме project.
--    Все четыре колонки после «я» — true.
select current_user                                                          as я,
       exists (select 1 from pg_roles r where r.rolname = 'project')          as роль_есть,
       pg_has_role(current_user, 'project', 'SET')                           as могу_перейти,
       (select bool_and(t.tableowner = 'project')
        from pg_tables t
        where t.schemaname = 'project'
          and t.tablename in ('places', 'realpay_transaction'))             as project_владелец,
       has_schema_privilege('project', 'project', 'CREATE')                  as project_создаёт;

-- 3. Имена свободны: обе строки — 0
select 'объекты ti_ в project' as что, count(*) as сколько
from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'project'
  and c.relname like 'ti\_%'
union all
select 'колонка places.card_discount_max_usd', count(*)
from information_schema.columns
where table_schema = 'project'
  and table_name = 'places'
  and column_name = 'card_discount_max_usd';

-- 4. Долгие транзакции. Они могут держать places или realpay_transaction, а скрипт ждёт
--    блокировку не дольше 5 секунд и потом падает целиком. Пусто — хорошо.
select pid, usename, state, now() - xact_start as длится, left(query, 80) as запрос
from pg_stat_activity
where datname = current_database()
  and xact_start < now() - interval '1 minute'
order by xact_start;


-- ---------------------------------------------------------------- ПОСЛЕ накатки

-- 5. Типы карт: X2, X5, X10; доли в фонды 0.25 / 0.1 / 0.05
select code, price_usd, total_usd, fund_tourist_rate, fund_object_rate
from project.ti_bonus_card_types
order by sort_order;

-- 6. Всё создано: 12 таблиц, 2 вью, 38 функций, 8 триггеров
select 'таблицы' as что, count(*) as сколько
from pg_tables
where schemaname = 'project'
  and tablename like 'ti\_%'
union all
select 'вью', count(*)
from pg_views
where schemaname = 'project'
  and viewname like 'ti\_%'
union all
select 'функции', count(*)
from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'project'
  and p.proname like 'ti\_%'
union all
select 'триггеры', count(*)
from pg_trigger
where tgname like 'ti\_trg%';

-- 7. История скидок стартовала с текущих скидок: два числа совпадают
select (select count(*) from project.ti_bonus_place_discount_history)                as в_истории,
       (select count(*) from project.places where card_discount_percentage > 0) as объектов_со_скидкой;

-- 8. Владелец новых таблиц — тот же, что у places (под ним работает конструктор)
select tablename as таблица, tableowner as владелец
from pg_tables
where schemaname = 'project'
  and tablename in ('places', 'ti_bonus_cards', 'ti_currency_rates');
