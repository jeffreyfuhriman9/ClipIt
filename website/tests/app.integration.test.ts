import type Stripe from "stripe";
import request from "supertest";
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import type { StripeClient } from "../src/services/stripe.js";
import { findProductById, findProductBySlug } from "../src/data/products.js";

const config: AppConfig = {
  nodeEnv: "test",
  port: 3000,
  appUrl: "http://localhost:3000",
  stripeSecretKey: "sk_test_fake",
  stripeWebhookSecret: "whsec_test",
  shippingCountries: ["US"],
  automaticTax: false,
  appStoreUrl: "https://example.com/app-store",
  playStoreUrl: "https://example.com/play-store",
  smtp: undefined,
  contactToEmail: "support@clipitbutton.com"
};

function stripeMock(overrides: {
  constructEvent?: StripeClient["webhooks"]["constructEvent"];
  retrieve?: StripeClient["checkout"]["sessions"]["retrieve"];
} = {}) {
  const create = vi.fn().mockResolvedValue({
    id: "cs_test_created",
    url: "https://checkout.stripe.com/c/pay/cs_test_created"
  });
  const retrieve = overrides.retrieve ?? vi.fn().mockResolvedValue({ payment_status: "paid" });
  const constructEvent =
    overrides.constructEvent ??
    vi.fn().mockReturnValue({
      id: "evt_test",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_test_paid",
          payment_status: "paid",
          amount_total: 4999,
          currency: "usd"
        }
      }
    });

  return {
    client: {
      checkout: { sessions: { create, retrieve } },
      webhooks: { constructEvent }
    } as unknown as StripeClient,
    create,
    retrieve,
    constructEvent
  };
}

describe("storefront integration", () => {
  it("renders listing and product detail pages", async () => {
    const app = createApp({ config, stripe: stripeMock().client });
    await request(app).get("/products").expect(200).expect(new RegExp(findProductBySlug("clipit-button")!.name));
    await request(app).get("/products/clipit-button").expect(200).expect(/Secure checkout by Stripe/);
  });

  it("renders the contact page", async () => {
    const app = createApp({ config, stripe: stripeMock().client });
    await request(app).get("/contact").expect(200).expect(/We’d love to hear from you/);
  });

  it("creates Stripe Checkout from trusted catalog values", async () => {
    const stripe = stripeMock();
    const app = createApp({ config, stripe: stripe.client });
    const response = await request(app)
      .post("/api/checkout")
      .send({
        items: [{ productId: "clipit-button-placeholder", quantity: 2, priceCents: 1 }]
      })
      .expect(201);

    expect(response.body.url).toMatch(/^https:\/\/checkout\.stripe\.com/);
    const checkoutInput = stripe.create.mock.calls[0]?.[0];
    expect(checkoutInput.line_items[0].price_data.unit_amount).toBe(findProductById("clipit-button-placeholder")!.priceCents);
    expect(checkoutInput.line_items[0].quantity).toBe(2);
    expect(checkoutInput.success_url).toContain("{CHECKOUT_SESSION_ID}");
    expect(checkoutInput.metadata.reviewProductIds).toContain("clipit-button-placeholder");
  });

  it("returns a useful error when Stripe fails", async () => {
    const stripe = stripeMock();
    stripe.create.mockRejectedValueOnce(new Error("network unavailable"));
    const app = createApp({ config, stripe: stripe.client });
    const response = await request(app)
      .post("/api/checkout")
      .send({ items: [{ productId: "clipit-button-placeholder", quantity: 1 }] })
      .expect(500);
    expect(response.body.error).toMatch(/could not complete/i);
  });

  it("verifies the paid status on the success page", async () => {
    const stripe = stripeMock();
    const app = createApp({ config, stripe: stripe.client });
    await request(app)
      .get("/checkout/success?session_id=cs_test_paid")
      .expect(200)
      .expect(/Payment confirmed/);
    expect(stripe.retrieve).toHaveBeenCalledWith("cs_test_paid");
  });
});

describe("verified reviews", () => {
  const reviewData = {
    summary: { average: 5, count: 1, breakdown: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 1 } },
    reviews: [{
      id: "review-1",
      rating: 5,
      name: "Verified Customer",
      body: "This is a real verified-purchase review.",
      createdAt: "2026-01-01T00:00:00.000Z",
      verifiedPurchase: true as const,
      media: []
    }]
  };

  it("renders only reviews returned by the verified review store", async () => {
    const reviewStore = {
      recordPaidOrder: vi.fn().mockResolvedValue([]),
      claim: vi.fn(),
      getProductReviews: vi.fn().mockResolvedValue(reviewData),
      submit: vi.fn()
    };
    const app = createApp({ config, stripe: stripeMock().client, reviewStore });
    await request(app).get("/products/clipit-button").expect(200).expect(/Verified Customer/).expect(/Verified Purchase/);
    expect(reviewStore.getProductReviews).toHaveBeenCalledWith("clipit-button-placeholder");
  });

  it("requires a server-validated review claim before accepting a review", async () => {
    const reviewStore = {
      recordPaidOrder: vi.fn().mockResolvedValue([]),
      claim: vi.fn().mockResolvedValue({ productId: "clipit-button-placeholder" }),
      getProductReviews: vi.fn().mockResolvedValue({ summary: { average: 0, count: 0, breakdown: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 } }, reviews: [] }),
      submit: vi.fn().mockResolvedValue(undefined)
    };
    const app = createApp({ config, stripe: stripeMock().client, reviewStore });
    await request(app)
      .post("/api/reviews")
      .field("token", "a-private-review-token-that-is-long-enough")
      .field("name", "Taylor Customer")
      .field("rating", "5")
      .field("body", "This is an honest verified customer review.")
      .expect(201, { received: true });
    expect(reviewStore.submit).toHaveBeenCalledWith(
      "a-private-review-token-that-is-long-enough",
      { name: "Taylor Customer", rating: 5, body: "This is an honest verified customer review." },
      []
    );
  });
});

describe("contact form", () => {
  it("validates a visitor message before sending", async () => {
    const app = createApp({ config, stripe: stripeMock().client });
    await request(app)
      .post("/api/contact")
      .send({ name: "A", email: "not-an-email", subject: "", message: "short" })
      .expect(400)
      .expect(/name/i);
  });

  it("delivers valid messages only through the configured server-side mailer", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const app = createApp({ config, stripe: stripeMock().client, contactMailer: { send } });
    await request(app)
      .post("/api/contact")
      .send({
        name: "Taylor Customer",
        email: "taylor@example.com",
        subject: "Help with my ClipIt Button",
        message: "I would like help with a ClipIt product question."
      })
      .expect(202, { received: true });
    expect(send).toHaveBeenCalledWith({
      name: "Taylor Customer",
      email: "taylor@example.com",
      subject: "Help with my ClipIt Button",
      message: "I would like help with a ClipIt product question.",
      website: ""
    });
  });

  it("silently accepts bot-trap submissions without delivering them", async () => {
    const send = vi.fn();
    const app = createApp({ config, stripe: stripeMock().client, contactMailer: { send } });
    await request(app)
      .post("/api/contact")
      .send({
        name: "Taylor Customer",
        email: "taylor@example.com",
        subject: "Automated message",
        message: "This is a valid-looking automated message.",
        website: "https://spam.example"
      })
      .expect(202, { received: true });
    expect(send).not.toHaveBeenCalled();
  });
});

describe("Stripe webhook validation", () => {
  it("rejects missing or invalid signatures", async () => {
    const invalidStripe = stripeMock({
      constructEvent: vi.fn(() => {
        throw new Error("signature mismatch");
      }) as StripeClient["webhooks"]["constructEvent"]
    });
    const app = createApp({ config, stripe: invalidStripe.client });

    await request(app)
      .post("/webhooks/stripe")
      .set("Content-Type", "application/json")
      .send("{}")
      .expect(400);
    await request(app)
      .post("/webhooks/stripe")
      .set("Content-Type", "application/json")
      .set("stripe-signature", "bad-signature")
      .send("{}")
      .expect(400);
  });

  it("confirms signed paid sessions server-side", async () => {
    const stripe = stripeMock();
    const onPaidOrder = vi.fn();
    const app = createApp({ config, stripe: stripe.client, onPaidOrder });

    await request(app)
      .post("/webhooks/stripe")
      .set("Content-Type", "application/json")
      .set("stripe-signature", "valid-test-signature")
      .send("{\"id\":\"evt_test\"}")
      .expect(200, { received: true });

    expect(stripe.constructEvent).toHaveBeenCalledWith(
      expect.any(Buffer),
      "valid-test-signature",
      "whsec_test"
    );
    expect(onPaidOrder).toHaveBeenCalledTimes(1);
    const session = onPaidOrder.mock.calls[0]?.[0] as Stripe.Checkout.Session;
    expect(session.payment_status).toBe("paid");
  });

  it("records review eligibility only from a signed paid Stripe event", async () => {
    const stripe = stripeMock({
      constructEvent: vi.fn().mockReturnValue({
        id: "evt_review",
        type: "checkout.session.completed",
        data: { object: {
          id: "cs_test_review",
          payment_status: "paid",
          customer_details: { email: "buyer@example.com" },
          metadata: { reviewProductIds: '["clipit-button-placeholder"]' }
        } }
      }) as StripeClient["webhooks"]["constructEvent"]
    });
    const reviewStore = {
      recordPaidOrder: vi.fn().mockResolvedValue([]),
      claim: vi.fn(),
      getProductReviews: vi.fn(),
      submit: vi.fn()
    };
    const app = createApp({ config, stripe: stripe.client, reviewStore });
    await request(app).post("/webhooks/stripe").set("Content-Type", "application/json").set("stripe-signature", "valid").send("{}").expect(200);
    expect(reviewStore.recordPaidOrder).toHaveBeenCalledWith("cs_test_review", "buyer@example.com", ["clipit-button-placeholder"]);
  });

  it("records fulfillment data only from a signed paid Stripe event", async () => {
    const stripe = stripeMock({
      constructEvent: vi.fn().mockReturnValue({
        id: "evt_fulfillment",
        type: "checkout.session.completed",
        data: { object: {
          id: "cs_test_fulfillment",
          payment_status: "paid",
          amount_total: 3999,
          currency: "usd",
          customer_details: {
            name: "Taylor Customer",
            email: "buyer@example.com",
            address: { line1: "123 Test Street", line2: null, city: "Boise", state: "ID", postal_code: "83702", country: "US" }
          },
          metadata: { fulfillmentOrderLines: '[{"productId":"clipit-button-placeholder","productName":"The ClipIt Button","quantity":1,"unitAmount":3999}]' }
        } }
      }) as StripeClient["webhooks"]["constructEvent"]
    });
    const recordPaidOrder = vi.fn().mockResolvedValue(undefined);
    const orderStore = {
      recordPaidOrder,
      listOrders: vi.fn().mockResolvedValue([]),
      updateFulfillment: vi.fn().mockResolvedValue(true)
    };
    const fulfillmentConfig: AppConfig = {
      ...config,
      orders: { databaseUrl: "postgresql://example.invalid/orders", adminPassword: "a-secure-dashboard-password-24" }
    };
    const app = createApp({ config: fulfillmentConfig, stripe: stripe.client, orderStore });
    await request(app).post("/webhooks/stripe").set("Content-Type", "application/json").set("stripe-signature", "valid").send("{}").expect(200);
    expect(recordPaidOrder).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: "cs_test_fulfillment",
      customerEmail: "buyer@example.com",
      lines: [{ productId: "clipit-button-placeholder", productName: "The ClipIt Button", quantity: 1, unitAmount: 3999 }]
    }));
  });

  it("adds a Stripe-verified paid order to the configured Google Sheet store", async () => {
    const stripe = stripeMock({
      constructEvent: vi.fn().mockReturnValue({
        id: "evt_google_sheet",
        type: "checkout.session.completed",
        data: { object: {
          id: "cs_test_google_sheet",
          payment_status: "paid",
          amount_total: 3999,
          currency: "usd",
          customer_details: {
            name: "Taylor Customer",
            email: "buyer@example.com",
            address: { line1: "123 Test Street", line2: null, city: "Boise", state: "ID", postal_code: "83702", country: "US" }
          },
          metadata: { fulfillmentOrderLines: '[{"productId":"clipit-button-placeholder","productName":"The ClipIt Button","quantity":1,"unitAmount":3999}]' }
        } }
      }) as StripeClient["webhooks"]["constructEvent"]
    });
    const recordPaidOrder = vi.fn().mockResolvedValue(true);
    const app = createApp({ config, stripe: stripe.client, googleSheetsOrderStore: { recordPaidOrder } });
    await request(app).post("/webhooks/stripe").set("Content-Type", "application/json").set("stripe-signature", "valid").send("{}").expect(200);
    expect(recordPaidOrder).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: "cs_test_google_sheet",
      customerEmail: "buyer@example.com",
      lines: [{ productId: "clipit-button-placeholder", productName: "The ClipIt Button", quantity: 1, unitAmount: 3999 }]
    }));
  });

  it("asks Stripe to retry when downstream order handling fails", async () => {
    const stripe = stripeMock();
    const app = createApp({
      config,
      stripe: stripe.client,
      onPaidOrder: () => {
        throw new Error("temporary fulfillment failure");
      }
    });

    await request(app)
      .post("/webhooks/stripe")
      .set("Content-Type", "application/json")
      .set("stripe-signature", "valid-test-signature")
      .send("{}")
      .expect(500);
  });
});

describe("private fulfillment dashboard", () => {
  const fulfillmentConfig: AppConfig = {
    ...config,
    orders: { databaseUrl: "postgresql://example.invalid/orders", adminPassword: "a-secure-dashboard-password-24" }
  };
  const dashboardOrder = {
    sessionId: "cs_test_order",
    customerName: "Taylor Customer",
    customerEmail: "buyer@example.com",
    address: { line1: "123 Test Street", line2: null, city: "Boise", state: "ID", postalCode: "83702", country: "US" },
    amountTotal: 3999,
    currency: "usd",
    status: "paid" as const,
    carrier: null,
    trackingNumber: null,
    shippedAt: null,
    createdAt: "2026-10-15T00:00:00.000Z",
    lines: [{ productId: "clipit-button-placeholder", productName: "The ClipIt Button", quantity: 1, unitAmount: 3999 }]
  };

  function fulfillmentStore() {
    return {
      recordPaidOrder: vi.fn().mockResolvedValue(undefined),
      listOrders: vi.fn().mockResolvedValue([dashboardOrder]),
      updateFulfillment: vi.fn().mockResolvedValue(true)
    };
  }

  it("requires the fulfillment password before displaying customer data", async () => {
    const app = createApp({ config: fulfillmentConfig, stripe: stripeMock().client, orderStore: fulfillmentStore() });
    await request(app).get("/fulfillment").expect(401);
    await request(app)
      .get("/fulfillment")
      .auth("clipit", fulfillmentConfig.orders!.adminPassword)
      .expect(200)
      .expect(/123 Test Street/);
  });

  it("saves a tracking number only through an authenticated same-origin request", async () => {
    const orderStore = fulfillmentStore();
    const app = createApp({ config: fulfillmentConfig, stripe: stripeMock().client, orderStore });
    await request(app)
      .post("/fulfillment/cs_test_order")
      .auth("clipit", fulfillmentConfig.orders!.adminPassword)
      .set("Origin", fulfillmentConfig.appUrl)
      .type("form")
      .send({ status: "fulfilled", carrier: "USPS", trackingNumber: "9400TEST" })
      .expect(303);
    expect(orderStore.updateFulfillment).toHaveBeenCalledWith("cs_test_order", {
      status: "fulfilled", carrier: "USPS", trackingNumber: "9400TEST"
    });
  });
});
