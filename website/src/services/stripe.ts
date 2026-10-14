import Stripe from "stripe";

export type StripeClient = Pick<
  Stripe,
  "checkout" | "webhooks"
>;

export function createStripeClient(secretKey: string): Stripe {
  // The server key is never sent to the browser. Stripe Checkout hosts all card fields,
  // so raw payment credentials never pass through this application.
  return new Stripe(secretKey, {
    appInfo: { name: "ClipIt Store", version: "1.0.0" },
    maxNetworkRetries: 2,
    timeout: 20_000
  });
}
