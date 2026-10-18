-- Run once against ORDER_DATABASE_URL before enabling the private fulfillment dashboard.
CREATE TABLE IF NOT EXISTS fulfillment_orders (
  stripe_session_id TEXT PRIMARY KEY,
  customer_name TEXT,
  customer_email TEXT NOT NULL,
  shipping_line1 TEXT,
  shipping_line2 TEXT,
  shipping_city TEXT,
  shipping_state TEXT,
  shipping_postal_code TEXT,
  shipping_country TEXT,
  amount_total INTEGER,
  currency TEXT,
  fulfillment_status TEXT NOT NULL DEFAULT 'paid' CHECK (fulfillment_status IN ('paid', 'fulfilled')),
  carrier TEXT,
  tracking_number TEXT,
  shipped_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fulfillment_order_items (
  stripe_session_id TEXT NOT NULL REFERENCES fulfillment_orders(stripe_session_id) ON DELETE CASCADE,
  product_id TEXT NOT NULL,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_amount INTEGER NOT NULL CHECK (unit_amount >= 0),
  PRIMARY KEY (stripe_session_id, product_id)
);

CREATE INDEX IF NOT EXISTS fulfillment_orders_created_at ON fulfillment_orders(created_at DESC);
