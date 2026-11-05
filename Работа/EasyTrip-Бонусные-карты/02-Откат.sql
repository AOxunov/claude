-- =====================================================================================
-- Откат 01-DDL.sql: удаляет всё, что он создал, вместе с данными карт, скидок и розыгрышей.
-- В places пропадёт колонка card_discount_max_usd (потолки скидок объектов).
-- Запуск: psql -v ON_ERROR_STOP=1 -d microservice -f 02-Откат.sql
-- =====================================================================================

begin;
set local lock_timeout = '5s';

drop trigger if exists trg_bonus_payment_status on project.realpay_transaction;
drop trigger if exists trg_bonus_place_discount_history on project.places;

-- возвращает строки bonus_cards и держит таблицу — удалить до таблиц
drop function if exists project.bonus_user_cards(uuid);

drop view if exists project.bonus_prize_fund_balance;
drop view if exists project.bonus_card_mismatches;

drop table if exists
    project.bonus_draw_winners,
    project.bonus_draw_entries,
    project.bonus_prize_fund_ledger,
    project.bonus_draw_prizes,
    project.bonus_draws,
    project.bonus_card_ledger,
    project.bonus_discounts,
    project.bonus_cards,
    project.bonus_card_types,
    project.bonus_place_discount_history,
    project.bonus_errors,
    project.currency_rates;

-- остальные функции bonus_* и currency_rate* в схеме project (их триггеры ушли вместе с таблицами)
do
$$
    declare
        r record;
    begin
        for r in
            select p.oid::regprocedure as sig
            from pg_proc p
                     join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'project'
              and (p.proname like 'bonus\_%' or p.proname like 'currency\_rate%')
            loop
                execute 'drop function ' || r.sig;
            end loop;
    end
$$;

alter table project.places drop column if exists card_discount_max_usd;

commit;
