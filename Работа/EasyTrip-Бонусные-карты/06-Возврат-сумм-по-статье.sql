-- =====================================================================================
-- Миграция 06 (06.11.2026): суммы карт снова по статье.
-- Утром 06.11 суммы меняли на $200 / $500 / $1000 (миграция 05), потом решение отменили,
-- 05 удалена. Здесь — те же значения, с которыми модуль накатан 05.11.2026:
--   X2:  цена $20,  сразу $20,  +$20 через 7 дней        → $40   (1 неделя),  в фонды 0.25 + 0.25;
--   X5:  цена $50,  сразу $50,  +$50 каждые 7 дней       → $250  (4 недели),  в фонды 0.1 + 0.1;
--   X10: цена $100, сразу $100, +$100 каждые 7 дней      → $1000 (9 недель),  в фонды 0.05 + 0.05.
-- Сгорает в месяц номинал: $20 / $50 / $100. В фонды — потраченное и сгоревшее, делённое на
-- кратность карты (2 / 5 / 10), пополам туристам и объектам: за жизнь карты в фонды уходит её цена.
--
-- Запускать можно в любом случае:
--   * 05 не запускали — значения уже такие: update 0 строк, комментарии к колонкам те же;
--   * 05 запускали — update 2 строки (X2 и X5; X10 в обоих вариантах одинаковая).
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
from (values ('X2', 40, 20, 20, 20, 0.25),
             ('X5', 250, 50, 50, 50, 0.1),
             ('X10', 1000, 100, 100, 100, 0.05)) as v(code, total_usd, initial_usd, accrual_usd, burn_usd, fund_rate)
where t.code = v.code
  and (t.total_usd, t.initial_usd, t.accrual_usd, t.burn_usd, t.fund_tourist_rate, t.fund_object_rate)
      is distinct from (v.total_usd, v.initial_usd, v.accrual_usd, v.burn_usd, v.fund_rate, v.fund_rate);

comment on column project.ti_bonus_card_types.fund_tourist_rate is 'Доля потраченного и сгоревшего в призовой фонд туристов: 1 / кратность / 2 (X2 — 0.25, X5 — 0.1, X10 — 0.05)';
comment on column project.ti_bonus_card_types.fund_object_rate is 'То же в призовой фонд объектов. Вместе две доли = 1 / кратность: за жизнь карты в фонды уходит вся её цена';

commit;

-- Проверка (цена / всего / сразу / прибавка / сгорает, доли):
--   X2  20 / 40 / 20 / 20 / 20,          0.2500 и 0.2500
--   X5  50 / 250 / 50 / 50 / 50,         0.1000 и 0.1000
--   X10 100 / 1000 / 100 / 100 / 100,    0.0500 и 0.0500
select code, price_usd, total_usd, initial_usd, accrual_usd, burn_usd, fund_tourist_rate, fund_object_rate
from project.ti_bonus_card_types
order by sort_order;
