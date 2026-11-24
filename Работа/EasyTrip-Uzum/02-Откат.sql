-- =====================================================================================
-- Откат 01-DDL.sql: удаляет всё, что создала миграция доставки Uzum, ВМЕСТЕ С ДАННЫМИ
-- (точки с токенами, операторы, заявки, события). Существующие таблицы не трогает.
-- База microservice. Эндпоинты в platon удаляются отдельно — раздел «Откат» в 00-Обзор.md.
-- =====================================================================================

begin;
set local lock_timeout = '5s';
set local role project;

-- функции, которые возвращают строки вью; потом сама вью (она вызывает uzum_stage);
-- потом остальные функции (зависят от типов таблиц) и таблицы
drop function if exists project.uzum_save(uuid, uuid, varchar, text);
drop function if exists project.uzum_claims_list(uuid, uuid, varchar, boolean, integer, integer);
drop view if exists project.uzum_claims_v;

do
$$
    declare
        f regprocedure;
    begin
        for f in
            select p.oid::regprocedure
            from pg_proc p
                     join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'project'
              and p.proname like 'uzum\_%'
            loop
                execute format('drop function %s', f);
            end loop;
    end
$$;

drop table if exists project.uzum_claim_events;
drop table if exists project.uzum_claims;
drop table if exists project.uzum_operators;
drop table if exists project.uzum_points;
drop table if exists project.uzum_settings;

commit;
