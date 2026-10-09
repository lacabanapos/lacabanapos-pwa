ALTER TABLE public.cash_sessions
  ADD COLUMN IF NOT EXISTS card_sales_cents integer NOT NULL DEFAULT 0;
