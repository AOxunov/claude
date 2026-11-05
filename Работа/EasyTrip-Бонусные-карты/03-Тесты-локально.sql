-- =====================================================================================
-- Тесты 01-DDL.sql. ТОЛЬКО ДЛЯ ЛОКАЛЬНОЙ КОПИИ БАЗЫ: добавляет тестовые объекты, мерчантов,
-- платежи, пополняет фонды.
-- Запуск: psql -v ON_ERROR_STOP=1 -d microservice -f 03-Тесты-локально.sql
-- Курс в тестах: 12 650,43 сума за $1. Первая неудачная проверка останавливает скрипт.
-- =====================================================================================

\set ON_ERROR_STOP 1
set client_min_messages = notice;

drop schema if exists bonus_test cascade;
create schema bonus_test;

create function bonus_test.ok(p_cond boolean, p_label text) returns void
    language plpgsql as
$$
begin
    if p_cond is distinct from true then
        raise exception 'FAIL: %', p_label;
    end if;
    raise notice 'ok: %', p_label;
end;
$$;

create function bonus_test.raises(p_sql text, p_label text) returns void
    language plpgsql as
$$
begin
    begin
        execute p_sql;
    exception
        when others then
            raise notice 'ok: % (ошибка: %)', p_label, sqlerrm;
            return;
    end;
    raise exception 'FAIL: % — ожидалась ошибка', p_label;
end;
$$;

-- платёж RealPay объекту через его мерчанта
create function bonus_test.pay(p_user uuid, p_place uuid, p_amount numeric) returns uuid
    language sql as
$$
insert into project.realpay_transaction (user_id, place_id, merchant_id, kassa_id, amount, state)
select p_user, m.place_id, m.id, m.kassa_id, p_amount, 1
from project.merchant m
where m.place_id = p_place
returning id
$$;

create function bonus_test.set_status(p_payment uuid, p_status varchar) returns void
    language sql as
$$
update project.realpay_transaction
set status = p_status, updated_at = now()
where id = p_payment
$$;

-- номер карты проходит проверку Луна целиком
create function bonus_test.luhn_ok(p_number varchar) returns boolean
    language sql as
$$
select project.bonus_luhn_digit(left(p_number, 15)) = right(p_number, 1)
$$;

\set u1 '00000000-0000-4000-8000-000000000001'
\set u2 '00000000-0000-4000-8000-000000000002'
\set u3 '00000000-0000-4000-8000-000000000003'
\set u4 '00000000-0000-4000-8000-000000000004'
\set u5 '00000000-0000-4000-8000-000000000005'
\set u6 '00000000-0000-4000-8000-000000000006'

-- ---------------------------------------------------------------- данные
insert into project.places (place_type, name_uz, card_discount_percentage, state, moderator_status)
values ('HOTEL', 'TEST easy-trip: продажа карт', 0, 1, 'ACCEPTED')
returning id as pl_card \gset
insert into project.places (place_type, name_uz, card_discount_percentage, state, moderator_status)
values ('HOTEL', 'TEST отель 10%', 10, 1, 'ACCEPTED')
returning id as pl_hotel \gset
insert into project.places (place_type, name_uz, card_discount_percentage, card_discount_max_usd, state, moderator_status)
values ('EATERY', 'TEST кафе 50% с потолком $50', 50, 50, 1, 'ACCEPTED')
returning id as pl_half \gset
insert into project.places (place_type, name_uz, card_discount_percentage, state, moderator_status)
values ('STORE', 'TEST магазин отклонён', 20, 1, 'REJECTED')
returning id as pl_rej \gset

insert into project.merchant (place_id, kassa_id, state, name)
values (:'pl_card', 'TEST-K-CARD', 1, 'easy-trip'),
       (:'pl_hotel', 'TEST-K-HOTEL', 1, 'hotel'),
       (:'pl_half', 'TEST-K-HALF', 1, 'cafe'),
       (:'pl_rej', 'TEST-K-REJ', 1, 'store');

select (now() at time zone 'Asia/Tashkent')::date as today \gset

-- ---------------------------------------------------------------- 1. Луна и курсы
select bonus_test.ok(project.bonus_luhn_digit('7992739871') = '3', 'Луна: 7992739871 → 3');

select bonus_test.ok(project.currency_rates_load_cbu(jsonb_build_array(
    jsonb_build_object('Ccy', 'USD', 'Rate', '12650.43', 'Nominal', '1', 'Date', to_char(:'today'::date, 'DD.MM.YYYY')),
    jsonb_build_object('Ccy', 'USD', 'Rate', '12600.00', 'Nominal', '1', 'Date', to_char(:'today'::date - 3, 'DD.MM.YYYY')),
    jsonb_build_object('Ccy', 'JPY', 'Rate', '820.50', 'Nominal', '10', 'Date', to_char(:'today'::date, 'DD.MM.YYYY'))
)) = 3, 'курсы ЦБ загружены');
select bonus_test.ok(project.currency_rates_load_cbu(
    jsonb_build_object('Ccy', 'USD', 'Rate', '12650.43', 'Nominal', '1', 'Date', to_char(:'today'::date, 'DD.MM.YYYY'))) = 0,
    'повторная загрузка ничего не меняет');
select bonus_test.ok((select rate from project.currency_rate('USD')) = 12650.43, 'курс USD сегодня');
select bonus_test.ok((select rate from project.currency_rates where currency = 'JPY') = 82.05, 'Nominal 10 учтён');
select bonus_test.ok((select rate from project.currency_rate('usd', now() - interval '2 days')) = 12600.00,
                     'курс на прошлую дату — последний не позже неё');
select bonus_test.raises($$select project.currency_rate('USD', now() + interval '30 days')$$, 'курс старше 7 дней — ошибка');

-- ---------------------------------------------------------------- 2. Покупка карты (через триггер)
select pay_amount as x5_amount, pay_amount as x5_amount_chk from project.bonus_card_quote('x5') \gset
select bonus_test.ok(:x5_amount = 632522, 'X5 = 50 × 12 650,43 = 632 522 сум (целые)');

select bonus_test.pay(:'u1', :'pl_card', :x5_amount) as p_card1 \gset
select project.bonus_card_order(:'p_card1', 'X5') as card1 \gset
select bonus_test.ok(project.bonus_card_order(:'p_card1', 'X5') = :'card1', 'повторный заказ — та же карта');
select bonus_test.ok((select status = 'PENDING' and card_number is null from project.bonus_cards where id = :'card1'),
                     'до оплаты карта PENDING без номера');

select bonus_test.pay(:'u1', :'pl_card', 1000) as p_bad \gset
select bonus_test.raises(format('select project.bonus_card_order(%L, %L)', :'p_bad', 'X5'), 'сумма не равна цене — ошибка');
select bonus_test.raises(format('select project.bonus_card_order(%L, %L)', :'p_bad', 'X7'), 'неизвестная карта — ошибка');

select bonus_test.set_status(:'p_card1', 'IN_PROGRESS');
select bonus_test.ok((select status from project.bonus_cards where id = :'card1') = 'PENDING', 'IN_PROGRESS ничего не меняет');
select bonus_test.set_status(:'p_card1', 'SUCCESS');
select bonus_test.ok((select status = 'ACTIVE' and balance_usd = 50 and accrued_usd = 50
                             and length(card_number) = 16 and bonus_test.luhn_ok(card_number)
                             and next_accrual_at = activated_at + interval '7 days'
                             and next_burn_at is null
                      from project.bonus_cards where id = :'card1'),
                     'оплата → карта активна, $50 сразу, номер 16 цифр по Луну, начисление через 7 дней');
select bonus_test.ok((select count(*) = 1 and sum(amount_usd) = 50 from project.bonus_card_ledger
                      where card_id = :'card1' and op_type = 'ISSUE'), 'в журнале ISSUE $50');

-- ---------------------------------------------------------------- 3. Начисления задним числом
select pay_amount as x10_amount from project.bonus_card_quote('X10') \gset
select bonus_test.pay(:'u2', :'pl_card', :x10_amount) as p_card2 \gset
select project.bonus_card_order(:'p_card2', 'X10') as card2 \gset
select project.bonus_card_activate(:'card2', now() - interval '70 days');
select bonus_test.ok((select accrued_usd = 1000 and balance_usd = 1000
                             and fully_accrued_at = activated_at + interval '63 days'
                             and next_accrual_at is null
                             and next_burn_at = project.bonus_add_interval(fully_accrued_at, interval '1 month')
                             and next_burn_at > now()
                      from project.bonus_cards where id = :'card2'),
                     'X10 за 70 дней: $100 + 9 × $100 = $1000, полностью на 63-й день, сгорание через месяц после');
select bonus_test.ok((select count(*) filter (where op_type = 'ACCRUAL') = 9 and count(*) = 10
                      from project.bonus_card_ledger where card_id = :'card2'), 'журнал: ISSUE + 9 ACCRUAL');
select project.bonus_card_process(:'card2');
select bonus_test.ok((select count(*) = 10 from project.bonus_card_ledger where card_id = :'card2'),
                     'повторная обработка ничего не добавила');

-- ---------------------------------------------------------------- 4. Сгорания
select pay_amount as x2_amount from project.bonus_card_quote('X2') \gset
select bonus_test.pay(:'u3', :'pl_card', :x2_amount) as p_card3 \gset
select project.bonus_card_order(:'p_card3', 'X2') as card3 \gset
select project.bonus_card_activate(:'card3', now() - interval '100 days');
select bonus_test.ok((select balance_usd = 0 and accrued_usd = 40 and next_burn_at is null
                      from project.bonus_cards where id = :'card3'),
                     'X2 без покупок 100 дней: накоплено $40 и сгорело дважды по $20');
select bonus_test.ok((select count(*) = 2 and sum(amount_usd) = -40
                             and min(occurred_at) = project.bonus_add_interval(
                                 (select fully_accrued_at from project.bonus_cards where id = :'card3'), interval '1 month')
                      from project.bonus_card_ledger where card_id = :'card3' and op_type = 'BURN'),
                     'первое сгорание — через месяц после полного накопления');
select bonus_test.ok((select count(*) = 4 and sum(amount_usd) filter (where fund = 'TOURIST') = 2
                             and sum(amount_usd) filter (where fund = 'OBJECT') = 2
                      from project.bonus_prize_fund_ledger where card_id = :'card3' and op_type = 'BURN'),
                     'сгоревшие $40 / 10 пополам: по $2 в каждый фонд');

-- ---------------------------------------------------------------- 5. Скидка с одной карты
select bonus_test.pay(:'u1', :'pl_hotel', 1000000) as p1 \gset
select discount_id as d1, discount_amount as d1_amount, discount_usd as d1_usd, pay_amount as d1_pay, balance_usd as d1_left
from project.bonus_discount_apply(:'p1') \gset
select bonus_test.ok(:d1_amount = 100000 and :d1_usd = 7.90 and :d1_pay = 900000 and :d1_left = 42.10,
                     '1 000 000 сум, отель 10%: скидка 100 000 сум = $7.90, к оплате 900 000, осталось $42.10');
select bonus_test.ok((select amount from project.realpay_transaction where id = :'p1') = 900000,
                     'в realpay_transaction сумма со скидкой');
select bonus_test.ok((select discount_id from project.bonus_discount_apply(:'p1')) = :'d1', 'повторный apply — та же скидка');
select bonus_test.set_status(:'p1', 'SUCCESS');
select bonus_test.ok((select status = 'CONFIRMED' and confirmed_at is not null from project.bonus_discounts where id = :'d1'),
                     'оплата → скидка подтверждена');
select bonus_test.ok((select last_spent_at is not null and balance_usd = 42.10 from project.bonus_cards where id = :'card1'),
                     'покупка отмечена на карте');
select bonus_test.ok((select count(*) = 2 and sum(amount_usd) = 0.79 from project.bonus_prize_fund_ledger
                      where discount_id = :'d1' and op_type = 'SPEND'), 'в фонды по $0.395 от $7.90');

select bonus_test.pay(:'u1', :'pl_rej', 500000) as p_rej \gset
select bonus_test.ok((select discount_id is null and pay_amount = 500000 from project.bonus_discount_apply(:'p_rej')),
                     'отклонённый модерацией объект — без скидки');
select bonus_test.pay(:'u6', :'pl_hotel', 500000) as p_nocard \gset
select bonus_test.ok((select discount_id is null and pay_amount = 500000 and balance_usd = 0
                      from project.bonus_discount_apply(:'p_nocard')), 'нет карты — без скидки');
select bonus_test.raises(format('select * from project.bonus_discount_apply(%L)', :'p_card1'),
                         'к платежу за карту скидка не применяется');

-- ---------------------------------------------------------------- 6. Две карты, потолок, отказ, возврат
select bonus_test.pay(:'u4', :'pl_card', :x2_amount) as p_card4a \gset
select project.bonus_card_order(:'p_card4a', 'X2') as card4a \gset
select project.bonus_card_activate(:'card4a', now() - interval '30 days');
select bonus_test.pay(:'u4', :'pl_card', :x5_amount) as p_card4b \gset
select project.bonus_card_order(:'p_card4b', 'X5') as card4b \gset
select project.bonus_card_activate(:'card4b', now() - interval '10 days');
select bonus_test.ok((select balance_usd from project.bonus_cards where id = :'card4a') = 40
                         and (select balance_usd from project.bonus_cards where id = :'card4b') = 100,
                     'у U4 две карты: X2 $40 (старая), X5 $100');

select bonus_test.pay(:'u4', :'pl_half', 2000000) as p2 \gset
select discount_id as d2, discount_amount as d2_amount, discount_usd as d2_usd from project.bonus_discount_apply(:'p2') \gset
select bonus_test.ok(:d2_amount = 632521 and :d2_usd = 50.00, 'кафе 50% с потолком $50: скидка 632 521 сум = $50');
select bonus_test.ok((select balance_usd from project.bonus_cards where id = :'card4a') = 0
                         and (select next_burn_at from project.bonus_cards where id = :'card4a') is null
                         and (select balance_usd from project.bonus_cards where id = :'card4b') = 90,
                     'списано сначала со старой ($40 → 0), остаток со следующей ($100 → 90)');
select bonus_test.set_status(:'p2', 'ERROR');
select bonus_test.ok((select status from project.bonus_discounts where id = :'d2') = 'RELEASED'
                         and (select balance_usd from project.bonus_cards where id = :'card4a') = 40
                         and (select next_burn_at is not null from project.bonus_cards where id = :'card4a')
                         and (select balance_usd from project.bonus_cards where id = :'card4b') = 100,
                     'оплата не прошла → средства вернулись на обе карты');
select bonus_test.ok(not exists (select 1 from project.bonus_prize_fund_ledger where discount_id = :'d2'),
                     'без оплаты в фонды ничего не ушло');

select bonus_test.pay(:'u4', :'pl_half', 200000) as p3 \gset
select discount_id as d3, discount_usd as d3_usd from project.bonus_discount_apply(:'p3') \gset
select bonus_test.ok(:d3_usd = 7.90 and (select balance_usd from project.bonus_cards where id = :'card4a') = 32.10,
                     '200 000 сум в кафе: $7.90 со старой карты');
select bonus_test.set_status(:'p3', 'SUCCESS');
select bonus_test.set_status(:'p3', 'CANCELLED');
select bonus_test.ok((select status from project.bonus_discounts where id = :'d3') = 'REFUNDED'
                         and (select balance_usd from project.bonus_cards where id = :'card4a') = 40,
                     'отмена оплаты → скидка вернулась на карту');
select bonus_test.ok((select count(*) = 4 and sum(amount_usd) = 0 from project.bonus_prize_fund_ledger
                      where discount_id = :'d3'), 'взносы в фонды сняты зеркально');

-- ---------------------------------------------------------------- 7. Новый платёж снимает старый резерв; поздняя оплата
select bonus_test.pay(:'u1', :'pl_hotel', 500000) as pa \gset
select discount_id as da from project.bonus_discount_apply(:'pa') \gset
select bonus_test.ok((select balance_usd from project.bonus_cards where id = :'card1') = 38.15, 'резерв $3.95');
select bonus_test.pay(:'u1', :'pl_hotel', 300000) as pb \gset
select discount_id as db from project.bonus_discount_apply(:'pb') \gset
select bonus_test.ok((select status from project.bonus_discounts where id = :'da') = 'RELEASED'
                         and (select balance_usd from project.bonus_cards where id = :'card1') = 39.73,
                     'новый платёж туриста снял резерв прежнего неоплаченного');
select bonus_test.set_status(:'pa', 'SUCCESS');
select bonus_test.ok((select status = 'CONFIRMED' and shortfall_usd = 0 from project.bonus_discounts where id = :'da')
                         and (select balance_usd from project.bonus_cards where id = :'card1') = 35.78,
                     'поздняя оплата снятого резерва: списано заново, недостачи нет');
select bonus_test.set_status(:'pb', 'SUCCESS');

select bonus_test.pay(:'u5', :'pl_card', :x2_amount) as p_card5 \gset
select project.bonus_card_order(:'p_card5', 'X2') as card5 \gset
select bonus_test.set_status(:'p_card5', 'SUCCESS');
select bonus_test.pay(:'u5', :'pl_half', 1000000) as pc \gset
select discount_id as dc, discount_usd as dc_usd from project.bonus_discount_apply(:'pc') \gset
select bonus_test.ok(:dc_usd = 20.00, 'скидка ограничена остатком $20');
select bonus_test.pay(:'u5', :'pl_half', 100000) as pd \gset
select discount_id as dd from project.bonus_discount_apply(:'pd') \gset
select bonus_test.set_status(:'pc', 'SUCCESS');
select bonus_test.ok((select status = 'CONFIRMED' and shortfall_usd = 3.95 from project.bonus_discounts where id = :'dc')
                         and (select balance_usd from project.bonus_cards where id = :'card5') = 0,
                     'поздняя оплата, денег уже не хватает: недостача $3.95 записана, карта в ноль');
select bonus_test.set_status(:'pd', 'SUCCESS');

-- ---------------------------------------------------------------- 8. bonus_sync: триггер выключен, резерв истёк, сбой триггера
alter table project.realpay_transaction disable trigger trg_bonus_payment_status;
select bonus_test.pay(:'u4', :'pl_hotel', 100000) as p4 \gset
select discount_id as d4 from project.bonus_discount_apply(:'p4') \gset
select bonus_test.set_status(:'p4', 'SUCCESS');
alter table project.realpay_transaction enable trigger trg_bonus_payment_status;
select bonus_test.ok((select status from project.bonus_discounts where id = :'d4') = 'RESERVED', 'без триггера скидка висит');
select project.bonus_sync() as sync1 \gset
select bonus_test.ok((select status from project.bonus_discounts where id = :'d4') = 'CONFIRMED', 'bonus_sync подтвердил');

select bonus_test.pay(:'u4', :'pl_hotel', 100000) as p5 \gset
select discount_id as d5 from project.bonus_discount_apply(:'p5') \gset
update project.bonus_discounts set reserved_at = now() - interval '1 hour' where id = :'d5';
select project.bonus_sync() as sync2 \gset
select bonus_test.ok((select status from project.bonus_discounts where id = :'d5') = 'RELEASED', 'резерв старше 30 минут снят');

create temp table saved_def as
select pg_get_functiondef('project.bonus_on_payment_status(uuid, varchar)'::regprocedure) as def;
create or replace function project.bonus_on_payment_status(p_payment_id uuid, p_status varchar) returns void
    language plpgsql as
$$
begin
    raise exception 'тестовый сбой';
end;
$$;
select bonus_test.pay(:'u4', :'pl_hotel', 100000) as p6 \gset
select discount_id as d6 from project.bonus_discount_apply(:'p6') \gset
select bonus_test.set_status(:'p6', 'SUCCESS');
select bonus_test.ok((select status from project.realpay_transaction where id = :'p6') = 'SUCCESS'
                         and (select status from project.bonus_discounts where id = :'d6') = 'RESERVED'
                         and exists (select 1 from project.bonus_errors where payment_id = :'p6' and message = 'тестовый сбой'),
                     'сбой бонусов не мешает сохранить статус платежа, ошибка записана');
do
$$
    begin
        execute (select def from saved_def);
    end
$$;
select project.bonus_sync() as sync3 \gset
select bonus_test.ok((select status from project.bonus_discounts where id = :'d6') = 'CONFIRMED', 'после сбоя bonus_sync догнал');

-- отмена оплаты карты
select bonus_test.pay(:'u6', :'pl_card', :x2_amount) as p_card6 \gset
select project.bonus_card_order(:'p_card6', 'X2') as card6 \gset
select bonus_test.set_status(:'p_card6', 'SUCCESS');
select bonus_test.set_status(:'p_card6', 'CANCELLED');
select bonus_test.ok((select status = 'REVOKED' and balance_usd = 0 from project.bonus_cards where id = :'card6')
                         and (select sum(amount_usd) = -20 from project.bonus_card_ledger where card_id = :'card6' and op_type = 'REVOKE'),
                     'платёж за карту отменён → карта отозвана, остаток списан');

select bonus_test.ok((select count(*) = 2 from project.bonus_user_cards(:'u4')), 'bonus_user_cards: у U4 две карты');
select bonus_test.ok(not exists (select 1 from project.bonus_card_mismatches), 'кеш остатков совпадает с журналом');

-- ---------------------------------------------------------------- 9. Скидка объекта: история
update project.places set card_discount_percentage = 15 where id = :'pl_hotel';
update project.places set card_discount_percentage = 15 where id = :'pl_hotel';
update project.places set card_discount_max_usd = 30 where id = :'pl_hotel';
select bonus_test.ok((select array_agg(discount_percent || '/' || coalesce(max_discount_usd::text, '-') order by created_at, id)
                      from project.bonus_place_discount_history where place_id = :'pl_hotel') = array ['10/-', '15/-', '15/30.00'],
                     'история скидки: 10% → 15% → потолок $30, повтор без изменений не пишется');

-- ---------------------------------------------------------------- 10. Розыгрыш туристов
select bonus_test.ok((select collected_usd from project.bonus_prize_fund_balance where fund = 'TOURIST') = 3.79
                         and (select collected_usd from project.bonus_prize_fund_balance where fund = 'OBJECT') = 3.79,
                     'в фонды собрано по $3.79: (потрачено $35.80 + сгорело $40) / 10 пополам');
insert into project.bonus_prize_fund_ledger (fund, op_type, amount_usd, occurred_at, comment)
values ('TOURIST', 'ADJUST', 100, now(), 'тест: пополнение'),
       ('OBJECT', 'ADJUST', 100, now(), 'тест: пополнение');

select project.bonus_draw_create('TOURIST', now() - interval '120 days', now(), array [5, 3, 2], 'Тест туристы') as draw_t \gset
select bonus_test.raises(format('select * from project.bonus_draw_run(%L, null)', :'draw_t'), 'без фиксации провести нельзя');
select entries_hash as draw_t_hash, random_request as draw_t_req from project.bonus_draw_freeze(:'draw_t') \gset
select bonus_test.ok((select array_agg(user_id::text || '=' || weight_cents order by entry_no) from project.bonus_draw_entries
                      where draw_id = :'draw_t')
                         = array [:'u3' || '=4000', :'u1' || '=1422', :'u5' || '=2000', :'u4' || '=158'],
                     'участники по порядку первого события: U3 сгорело $40, U1 $14.22, U5 $20 (с недостачей), U4 $1.58 (возврат не считается)');
select bonus_test.ok((select bool_and(range_to - range_from + 1 = weight_cents)
                             and min(range_from) = 1 and max(range_to) = 7580
                      from project.bonus_draw_entries where draw_id = :'draw_t'), 'диапазоны билетов подряд 1..7580');
select bonus_test.ok((select status = 'FROZEN' and prizes_count = 3 and prize_total_usd = 10 and total_weight_cents = 7580
                      from project.bonus_draws where id = :'draw_t'), 'зафиксирован, 3 места на $10');
select bonus_test.ok((select sum(amount_usd) = -10 from project.bonus_prize_fund_ledger where draw_id = :'draw_t'),
                     'призы списаны из фонда до random.org');
select bonus_test.raises(format('insert into project.bonus_draw_prizes (draw_id, place_no, amount_usd) values (%L, 9, 1)', :'draw_t'),
                         'после фиксации призы не меняются');
select bonus_test.raises(format('select * from project.bonus_draw_run(%L, %L)', :'draw_t',
                                jsonb_build_object('result', jsonb_build_object('random', jsonb_build_object(
                                        'data', jsonb_build_array(0.5, 0.25, 0.999),
                                        'userData', jsonb_build_object('draw_id', :'draw_t', 'entries_hash', 'чужой'))))::text),
                         'ответ random.org с чужим userData — ошибка');

select json_agg(t) as winners_t
from project.bonus_draw_run(:'draw_t', jsonb_build_object('jsonrpc', '2.0', 'result', jsonb_build_object('random',
        jsonb_build_object('data', jsonb_build_array(0.5, 0.25, 0.999),
                           'userData', jsonb_build_object('draw_id', :'draw_t', 'entries_hash', :'draw_t_hash'),
                           'serialNumber', 1), 'signature', 'тест'), 'id', 1)::text) t \gset
select bonus_test.ok((select array_agg(user_id::text || '=' || amount_usd || '#' || ticket order by round_no)
                      from project.bonus_draw_winners where draw_id = :'draw_t')
                         = array [:'u3' || '=5.00#3791', :'u1' || '=3.00#896', :'u4' || '=2.00#2156'],
                     'победители: билет 3791 из 7580 → U3; 896 из 3580 → U1; 2156 из 2158 → U4');
select bonus_test.ok((select count(*) = 3 from project.bonus_draw_run(:'draw_t', null)), 'повторный run отдаёт тех же');

-- ---------------------------------------------------------------- 11. Розыгрыш объектов, цепочка
select project.bonus_draw_create('OBJECT', now() - interval '120 days', now(), array [4], 'Тест объекты') as draw_o \gset
select entries_hash as draw_o_hash from project.bonus_draw_freeze(:'draw_o') \gset
select bonus_test.ok((select array_agg(place_id::text || '=' || weight_cents order by entry_no) from project.bonus_draw_entries
                      where draw_id = :'draw_o') = array [:'pl_hotel' || '=1580', :'pl_half' || '=2000'],
                     'объекты: отель $15.80, кафе $20 — выданные скидки');
select count(*) as n from project.bonus_draw_run(:'draw_o', jsonb_build_object('result', jsonb_build_object('random',
        jsonb_build_object('data', jsonb_build_array(0.6),
                           'userData', jsonb_build_object('draw_id', :'draw_o', 'entries_hash', :'draw_o_hash'))))::text) \gset
select bonus_test.ok((select place_id from project.bonus_draw_winners where draw_id = :'draw_o') = :'pl_half',
                     'билет 2149 из 3580 → кафе');
select bonus_test.ok((select prev_hash from project.bonus_draws where id = :'draw_o')
                         = (select hash from project.bonus_draws where id = :'draw_t'), 'prev_hash ссылается на прошлый розыгрыш');

-- пустой период: участников нет, random.org не нужен
select project.bonus_draw_create('TOURIST', '2020-01-01', '2020-01-02', array [1]) as draw_e \gset
select bonus_test.ok((select entries_count = 0 and prizes_count = 0 and prize_total_usd = 0
                      from project.bonus_draw_freeze(:'draw_e')), 'пустой период: 0 участников, призы не списаны');
select count(*) as n from project.bonus_draw_run(:'draw_e', null) \gset
select bonus_test.ok((select status from project.bonus_draws where id = :'draw_e') = 'DONE', 'пустой розыгрыш проведён');

select bonus_test.ok((select count(*) = 3 and bool_and(hash_ok and chain_ok and entries_ok)
                      from project.bonus_draw_chain_check()), 'цепочка из трёх розыгрышей сходится');

-- правка задним числом видна
select bonus_test.raises(format('update project.bonus_draw_winners set amount_usd = 500 where draw_id = %L and round_no = 1', :'draw_t'),
                         'сумму выигрыша не изменить');
select bonus_test.raises(format('update project.bonus_draws set title = %L where id = %L', 'x', :'draw_t'),
                         'проведённый розыгрыш не изменить');
alter table project.bonus_draw_winners disable trigger trg_bonus_draw_winners_guard;
update project.bonus_draw_winners set amount_usd = 500 where draw_id = :'draw_t' and round_no = 1;
select bonus_test.ok((select not hash_ok and chain_ok from project.bonus_draw_chain_check() where draw_id = :'draw_t'),
                     'подмена суммы при выключенной защите — хеш не сходится');
update project.bonus_draw_winners set amount_usd = 5 where draw_id = :'draw_t' and round_no = 1;
alter table project.bonus_draw_winners enable trigger trg_bonus_draw_winners_guard;
alter table project.bonus_draw_entries disable trigger trg_bonus_draw_entries_append_only;
update project.bonus_draw_entries set weight_cents = 4001, range_to = 4001 where draw_id = :'draw_t' and entry_no = 1;
select bonus_test.ok((select not entries_ok from project.bonus_draw_chain_check() where draw_id = :'draw_t'),
                     'подмена веса участника — хеш участников не сходится');
update project.bonus_draw_entries set weight_cents = 4000, range_to = 4000 where draw_id = :'draw_t' and entry_no = 1;
alter table project.bonus_draw_entries enable trigger trg_bonus_draw_entries_append_only;
select bonus_test.ok((select bool_and(hash_ok and chain_ok and entries_ok) from project.bonus_draw_chain_check()),
                     'после возврата значений цепочка снова сходится');

-- выплата: меняются только поля выплаты
update project.bonus_draw_winners
set payout_status = 'PAID', paid_at = now(), paid_amount = 63252, paid_currency = 'UZS', paid_rate = 12650.43
where draw_id = :'draw_t' and round_no = 1;
select bonus_test.ok((select payout_status from project.bonus_draw_winners where draw_id = :'draw_t' and round_no = 1) = 'PAID',
                     'выплата отмечена');

-- ---------------------------------------------------------------- 12. Ежедневные, нехватка фонда, отмена, ранняя фиксация
select project.bonus_draw_create_daily('TOURIST', :'today'::date - 1, array [1, 0.5]) as daily1 \gset
select bonus_test.ok(project.bonus_draw_create_daily('TOURIST', :'today'::date - 1) = :'daily1', 'ежедневный за день — один');
select bonus_test.ok((select period_from = (:'today'::date - 1)::timestamp at time zone 'Asia/Tashkent'
                             and period_to - period_from = interval '1 day'
                      from project.bonus_draws where id = :'daily1'), 'границы суток по Ташкенту');
select project.bonus_draw_create_daily('TOURIST', :'today'::date - 2) as daily2 \gset
select bonus_test.ok((select array_agg(amount_usd order by place_no) from project.bonus_draw_prizes where draw_id = :'daily2')
                         = array [1.00, 0.50], 'без призов — копия призов последнего ежедневного');

select project.bonus_draw_create('TOURIST', now() - interval '120 days', now(), array [100000]) as draw_big \gset
select bonus_test.raises(format('select * from project.bonus_draw_freeze(%L)', :'draw_big'), 'фонда не хватает — ошибка');
select bonus_test.ok((select status from project.bonus_draws where id = :'draw_big') = 'DRAFT'
                         and not exists (select 1 from project.bonus_draw_entries where draw_id = :'draw_big'),
                     'розыгрыш остался черновиком, участники не записаны');

select project.bonus_draw_create('TOURIST', now() - interval '1 day', now() + interval '1 day', array [1]) as draw_future \gset
select bonus_test.raises(format('select * from project.bonus_draw_freeze(%L)', :'draw_future'), 'период не кончился — ошибка');

select balance_usd as fund_before from project.bonus_prize_fund_balance where fund = 'TOURIST' \gset
select project.bonus_draw_create('TOURIST', now() - interval '120 days', now(), array [1]) as draw_c \gset
select count(*) as n from project.bonus_draw_freeze(:'draw_c') \gset
select project.bonus_draw_cancel(:'draw_c', 'тест');
select bonus_test.ok((select balance_usd from project.bonus_prize_fund_balance where fund = 'TOURIST') = :fund_before,
                     'отмена зафиксированного розыгрыша вернула призы в фонд');
select bonus_test.raises(format('select project.bonus_draw_cancel(%L)', :'draw_t'), 'проведённый не отменить');

-- ---------------------------------------------------------------- 13. Журналы только для добавления, итоговая сверка
select bonus_test.raises($$update project.bonus_card_ledger set amount_usd = 1000 where op_type = 'ISSUE'$$, 'журнал карт не правится');
select bonus_test.raises($$delete from project.bonus_prize_fund_ledger$$, 'журнал фонда не удаляется');
select bonus_test.ok(not exists (select 1 from project.bonus_card_mismatches), 'итог: кеш остатков совпадает с журналом');
select bonus_test.ok((select count(*) = 0 from project.bonus_errors where message <> 'тестовый сбой'), 'итог: других сбоев нет');

\echo '=== ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ ==='
