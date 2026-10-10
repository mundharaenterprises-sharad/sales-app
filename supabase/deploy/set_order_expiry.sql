-- =============================================================================
-- set_order_expiry.sql
--
-- Run this in the Supabase SQL Editor. Changes one number.
--
-- How long a submitted order holds stock before giving it back.
--
-- While an order is held, its quantities are **reserved**: they still show on
-- the Stock screen as on hand, but not as available, and no other rep can
-- sell them. When the time runs out a scheduled job marks the order
-- **Expired** and releases the reservation. The order is not deleted and
-- nothing is lost — an expired order can be reinstated from the Orders
-- screen, and will be, if there is still stock for it.
--
-- The trade is straightforward. Longer means a rep's order survives a slow
-- week at the office. It also means stock sitting unsellable against orders
-- that may never be billed, which at the wrong moment is a sale you could
-- have made and did not.
--
-- Two days was the original setting. This moves it to six.
--
-- It applies to orders submitted AFTER it is run. An order already in flight
-- keeps the expiry date it was given when the rep submitted it; to extend
-- those as well, run the second statement too.
--
-- Safe to run twice.
-- =============================================================================

update public.app_setting
   set reservation_expiry_days = 6
 where id = (select id from public.app_setting limit 1);


-- -----------------------------------------------------------------------------
-- Optional: give orders that are already waiting the longer window too.
--
-- Only touches orders still holding stock. Anything already expired stays
-- expired — reinstate those from the Orders screen instead, which checks that
-- the stock is actually there before handing it back.
--
-- Delete the `-- ` from the three lines below to run it.
-- -----------------------------------------------------------------------------

-- update public.sales_order
--    set expires_at = submitted_at + interval '6 days'
--  where status = 'SUBMITTED' and submitted_at is not null;


-- -----------------------------------------------------------------------------
-- What it says now.
-- -----------------------------------------------------------------------------

select
  reservation_expiry_days                        as days_an_order_holds_stock,
  (select count(*) from public.sales_order
    where status = 'SUBMITTED')                  as orders_holding_stock_now,
  (select count(*) from public.sales_order
    where status = 'SUBMITTED' and expires_at < now() + interval '2 days')
                                                 as due_to_expire_within_two_days
from public.app_setting;
