import { Pool } from "pg";
import type Stripe from "stripe";
import type { AppConfig } from "../config.js";

export type OrderLine = {
  productId: string;
  productName: string;
  quantity: number;
  unitAmount: number;
};

export type FulfillmentOrder = {
  sessionId: string;
  customerName: string | null;
  customerEmail: string;
  address: {
    line1: string;
    line2: string | null;
    city: string;
    state: string | null;
    postalCode: string;
    country: string;
  } | null;
  amountTotal: number | null;
  currency: string | null;
  status: "paid" | "fulfilled";
  carrier: string | null;
  trackingNumber: string | null;
  shippedAt: string | null;
  createdAt: string;
  lines: OrderLine[];
};

type StoredOrderRow = Omit<FulfillmentOrder, "lines"> & { status: FulfillmentOrder["status"] };

function shippingAddress(session: Stripe.Checkout.Session) {
  // Stripe has used both shipping_details and collected_information over API
  // versions. Read either shape without trusting any browser-provided address.
  const extended = session as Stripe.Checkout.Session & {
    shipping_details?: { name?: string | null; address?: Stripe.Address | null } | null;
    collected_information?: { shipping_details?: { name?: string | null; address?: Stripe.Address | null } | null } | null;
  };
  const shipping = extended.shipping_details ?? extended.collected_information?.shipping_details;
  return shipping?.address ?? session.customer_details?.address ?? null;
}

export function paidOrderFromSession(session: Stripe.Checkout.Session, lines: OrderLine[]) {
  const address = shippingAddress(session);
  const customerName =
    (session as Stripe.Checkout.Session & { shipping_details?: { name?: string | null } | null }).shipping_details?.name ??
    session.customer_details?.name ??
    null;
  const customerEmail = session.customer_details?.email ?? session.customer_email;
  if (!customerEmail) throw new Error("Paid Checkout session is missing the customer email.");

  return {
    sessionId: session.id,
    customerName,
    customerEmail,
    address: address
      ? {
          line1: address.line1,
          line2: address.line2 ?? null,
          city: address.city,
          state: address.state ?? null,
          postalCode: address.postal_code,
          country: address.country
        }
      : null,
    amountTotal: session.amount_total ?? null,
    currency: session.currency ?? null,
    lines
  };
}

export class OrderStore {
  private readonly pool: Pool;
  private initialized?: Promise<void>;

  constructor(private readonly databaseUrl: string) {
    this.pool = new Pool({ connectionString: databaseUrl, ssl: { rejectUnauthorized: true } });
  }

  private async ensureSchema() {
    this.initialized ??= this.pool.query(`
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
    `).then(() => undefined);
    return this.initialized;
  }

  async recordPaidOrder(order: ReturnType<typeof paidOrderFromSession>) {
    await this.ensureSchema();
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(
        `INSERT INTO fulfillment_orders (
          stripe_session_id, customer_name, customer_email, shipping_line1, shipping_line2,
          shipping_city, shipping_state, shipping_postal_code, shipping_country, amount_total, currency
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
        ON CONFLICT (stripe_session_id) DO UPDATE SET
          customer_name=EXCLUDED.customer_name, customer_email=EXCLUDED.customer_email,
          shipping_line1=EXCLUDED.shipping_line1, shipping_line2=EXCLUDED.shipping_line2,
          shipping_city=EXCLUDED.shipping_city, shipping_state=EXCLUDED.shipping_state,
          shipping_postal_code=EXCLUDED.shipping_postal_code, shipping_country=EXCLUDED.shipping_country,
          amount_total=EXCLUDED.amount_total, currency=EXCLUDED.currency, updated_at=now()`,
        [
          order.sessionId, order.customerName, order.customerEmail, order.address?.line1 ?? null,
          order.address?.line2 ?? null, order.address?.city ?? null, order.address?.state ?? null,
          order.address?.postalCode ?? null, order.address?.country ?? null, order.amountTotal, order.currency
        ]
      );
      for (const line of order.lines) {
        await client.query(
          `INSERT INTO fulfillment_order_items (stripe_session_id, product_id, product_name, quantity, unit_amount)
           VALUES ($1,$2,$3,$4,$5)
           ON CONFLICT (stripe_session_id, product_id) DO UPDATE SET
             product_name=EXCLUDED.product_name, quantity=EXCLUDED.quantity, unit_amount=EXCLUDED.unit_amount`,
          [order.sessionId, line.productId, line.productName, line.quantity, line.unitAmount]
        );
      }
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async listOrders(): Promise<FulfillmentOrder[]> {
    await this.ensureSchema();
    const orders = await this.pool.query<{
      stripe_session_id: string; customer_name: string | null; customer_email: string;
      shipping_line1: string | null; shipping_line2: string | null; shipping_city: string | null;
      shipping_state: string | null; shipping_postal_code: string | null; shipping_country: string | null;
      amount_total: number | null; currency: string | null; fulfillment_status: FulfillmentOrder["status"];
      carrier: string | null; tracking_number: string | null; shipped_at: Date | null; created_at: Date;
    }>("SELECT * FROM fulfillment_orders ORDER BY created_at DESC");
    const items = await this.pool.query<{ stripe_session_id: string; product_id: string; product_name: string; quantity: number; unit_amount: number }>(
      "SELECT * FROM fulfillment_order_items ORDER BY product_name ASC"
    );
    const itemsByOrder = new Map<string, OrderLine[]>();
    for (const item of items.rows) {
      const lines = itemsByOrder.get(item.stripe_session_id) ?? [];
      lines.push({ productId: item.product_id, productName: item.product_name, quantity: item.quantity, unitAmount: item.unit_amount });
      itemsByOrder.set(item.stripe_session_id, lines);
    }
    return orders.rows.map((row) => ({
      sessionId: row.stripe_session_id,
      customerName: row.customer_name,
      customerEmail: row.customer_email,
      address: row.shipping_line1 && row.shipping_city && row.shipping_postal_code && row.shipping_country
        ? { line1: row.shipping_line1, line2: row.shipping_line2, city: row.shipping_city, state: row.shipping_state, postalCode: row.shipping_postal_code, country: row.shipping_country }
        : null,
      amountTotal: row.amount_total,
      currency: row.currency,
      status: row.fulfillment_status,
      carrier: row.carrier,
      trackingNumber: row.tracking_number,
      shippedAt: row.shipped_at?.toISOString() ?? null,
      createdAt: row.created_at.toISOString(),
      lines: itemsByOrder.get(row.stripe_session_id) ?? []
    }));
  }

  async updateFulfillment(sessionId: string, values: { status: "paid" | "fulfilled"; carrier: string; trackingNumber: string }) {
    await this.ensureSchema();
    const result = await this.pool.query(
      `UPDATE fulfillment_orders SET fulfillment_status=$2, carrier=$3, tracking_number=$4,
        shipped_at=CASE WHEN $2='fulfilled' THEN COALESCE(shipped_at, now()) ELSE NULL END,
        updated_at=now() WHERE stripe_session_id=$1 RETURNING stripe_session_id`,
      [sessionId, values.status, values.status === "fulfilled" ? values.carrier || null : null, values.status === "fulfilled" ? values.trackingNumber : null]
    );
    return Boolean(result.rowCount);
  }
}

export function createOrderStore(config: AppConfig) {
  return config.orders ? new OrderStore(config.orders.databaseUrl) : undefined;
}
