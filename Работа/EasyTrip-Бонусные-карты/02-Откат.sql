-- =====================================================================================
-- Откат 01-DDL.sql: удаляет всё, что он создал, вместе с данными карт, скидок и розыгрышей.
-- В places пропадёт колонка card_discount_max_usd (потолки скидок объектов).
-- Запуск: psql -v ON_ERROR_STOP=1 -d microservice -f 02-Откат.sql
-- =====================================================================================

begin;
set local lock_timeout = '5s';
-- удалять может только владелец — роль project, как и в 01-DDL.sql
set local role project;

drop trigger if exists ti_trg_bonus_payment_status on project.realpay_transaction;
drop trigger if exists ti_trg_bonus_place_discount_history on project.places;

-- возвращает строки ti_bonus_cards и держит таблицу — удалить до таблиц
drop function if exists project.ti_bonus_user_cards(uuid);

drop view if exists project.ti_bonus_prize_fund_balance;
drop view if exists project.ti_bonus_card_mismatches;

drop table if exists
    project.ti_bonus_draw_winners,
    project.ti_bonus_draw_entries,
    project.ti_bonus_prize_fund_ledger,
    project.ti_bonus_draw_prizes,
    project.ti_bonus_draws,
    project.ti_bonus_card_ledger,
    project.ti_bonus_discounts,
    project.ti_bonus_cards,
    project.ti_bonus_card_types,
    project.ti_bonus_place_discount_history,
    project.ti_bonus_errors,
    project.ti_currency_rates;

-- остальные функции ti_bonus_* и ti_currency_rate* в схеме project (их триггеры ушли вместе с таблицами)
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
              and (p.proname like 'ti\_bonus\_%' or p.proname like 'ti\_currency\_rate%')
            loop
                execute 'drop function ' || r.sig;
            end loop;
    end
$$;

alter table project.places drop column if exists card_discount_max_usd;

commit;
