-- Run once against DATABASE_URL before enabling verified reviews.
-- The app also uses CREATE TABLE IF NOT EXISTS during startup as a deployment-safe
-- fallback, but migrations should be part of your normal release process.
CREATE TABLE IF NOT EXISTS review_orders (
  stripe_session_id TEXT PRIMARY KEY,
  customer_email TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS review_order_items (
  id BIGSERIAL PRIMARY KEY,
  stripe_session_id TEXT NOT NULL REFERENCES review_orders(stripe_session_id) ON DELETE CASCADE,
  product_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  reviewed_at TIMESTAMPTZ,
  UNIQUE (stripe_session_id, product_id)
);

CREATE TABLE IF NOT EXISTS product_reviews (
  id UUID PRIMARY KEY,
  order_item_id BIGINT NOT NULL UNIQUE REFERENCES review_order_items(id),
  product_id TEXT NOT NULL,
  customer_email TEXT NOT NULL,
  reviewer_name TEXT NOT NULL,
  rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Blocks a second review even if the same buyer completes a later order.
  UNIQUE (product_id, customer_email)
);

CREATE TABLE IF NOT EXISTS review_media (
  id UUID PRIMARY KEY,
  review_id UUID NOT NULL REFERENCES product_reviews(id) ON DELETE CASCADE,
  object_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'video')),
  public_url TEXT NOT NULL,
  alt_text TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS product_reviews_product_created
  ON product_reviews(product_id, created_at DESC);
