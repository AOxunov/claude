-- =====================================================================================
-- Миграция 05 (06.11.2026): новые суммы карт.
-- Было (по статье): 2x / 5x / 10x копили $40 / $250 / $1000, сразу 1× номинала, +1× в неделю.
-- Стало: копят $200 / $500 / $1000, сразу после оплаты $100, дальше +$100 каждые 7 дней
-- (2x — за 1 неделю, 5x — за 4, 10x — за 9). Сгорает в месяц по-прежнему $20 / $50 / $100.
-- В фонды — потраченное и сгоревшее / 10, пополам: 0.05 туристам + 0.05 объектам у всех карт.
--
-- Уже купленные карты условия не меняют (у каждой своя копия). На 06.11.2026 карт нет.
-- Запуск: весь файл одним прогоном (DataGrip: Ctrl+A, Ctrl+Enter; psql: -v ON_ERROR_STOP=1 -f).
-- После commit — проверочный запрос в конце файла.
-- =====================================================================================

begin;
set local lock_timeout = '5s';
set local role project;

update project.ti_bonus_card_types t
set total_usd         = v.total_usd,
    initial_usd       = v.initial_usd,
    accrual_usd       = v.accrual_usd,
    burn_usd          = v.burn_usd,
    fund_tourist_rate = v.fund_rate,
    fund_object_rate  = v.fund_rate,
    updated_at        = now()
from (values ('X2', 200, 100, 100, 20, 0.05),
             ('X5', 500, 100, 100, 50, 0.05),
             ('X10', 1000, 100, 100, 100, 0.05)) as v(code, total_usd, initial_usd, accrual_usd, burn_usd, fund_rate)
where t.code = v.code;

comment on column project.ti_bonus_card_types.fund_tourist_rate is 'Доля потраченного и сгоревшего в призовой фонд туристов: цена / всего / 2 (у X2, X5, X10 — 0.05)';
comment on column project.ti_bonus_card_types.fund_object_rate is 'То же в призовой фонд объектов. Вместе две доли = цена / всего: за жизнь карты в фонды уходит вся её цена';

commit;

-- Проверка: X2 20 / 200 / 100 / 100 / 20, X5 50 / 500 / 100 / 100 / 50, X10 100 / 1000 / 100 / 100 / 100,
-- доли везде 0.0500
select code, price_usd, total_usd, initial_usd, accrual_usd, burn_usd, fund_tourist_rate, fund_object_rate
from project.ti_bonus_card_types
order by sort_order;
