import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, timingSafeEqual } from "node:crypto";
import compression from "compression";
import express, { type NextFunction, type Request, type Response } from "express";
import rateLimit from "express-rate-limit";
import helmet from "helmet";
import multer, { MulterError } from "multer";
import type Stripe from "stripe";
import { z } from "zod";
import { loadConfig, type AppConfig } from "./config.js";
import { findProductBySlug, products } from "./data/products.js";
import { testimonials } from "./data/testimonials.js";
import { CartValidationError, validateCart } from "./services/cart.js";
import { createStripeClient, type StripeClient } from "./services/stripe.js";
import { createContactMailer, type ContactMailer } from "./services/contact.js";
import { createOrderStore, paidOrderFromSession, type OrderLine, type OrderStore } from "./services/orders.js";
import { createGoogleSheetsOrderStore, type GoogleSheetsOrderStore } from "./services/google-sheets.js";
import {
  createReviewStore,
  ReviewClaimError,
  ReviewValidationError,
  sendReviewInvitations,
  type ReviewData,
  type ReviewUpload
} from "./services/reviews.js";

const currentDir = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(currentDir, "..");

type AppDependencies = {
  config?: AppConfig;
  stripe?: StripeClient;
  onPaidOrder?: (session: Stripe.Checkout.Session) => Promise<void> | void;
  contactMailer?: ContactMailer;
  reviewStore?: {
    recordPaidOrder(sessionId: string, customerEmail: string, products: string[]): Promise<Array<{ productId: string; token: string }>>;
    claim(token: string): Promise<{ productId: string } | undefined>;
    getProductReviews(productId: string): Promise<ReviewData>;
    submit(token: string, values: { name: string; rating: number; body: string }, uploads: ReviewUpload[]): Promise<void>;
  };
  orderStore?: Pick<OrderStore, "recordPaidOrder" | "listOrders" | "updateFulfillment">;
  googleSheetsOrderStore?: Pick<GoogleSheetsOrderStore, "recordPaidOrder">;
};

const contactSchema = z.object({
  name: z.string().trim().min(2, "Please enter your name.").max(100),
  email: z.string().trim().email("Please enter a valid email address.").max(254),
  subject: z
    .string()
    .trim()
    .min(3, "Please enter a subject.")
    .max(160)
    .regex(/^[^\r\n]+$/, "Please enter the subject on one line."),
  message: z.string().trim().min(10, "Please enter a message of at least 10 characters.").max(5_000),
  // Bots often complete every input. Real visitors never see this field.
  website: z.string().max(1_000).optional().default("")
});

const reviewSchema = z.object({
  token: z.string().min(20, "This review link is invalid."),
  name: z.string().trim().min(2, "Please enter your name.").max(80),
  rating: z.coerce.number().int().min(1, "Choose a rating from 1 to 5.").max(5, "Choose a rating from 1 to 5."),
  body: z.string().trim().min(10, "Please write at least 10 characters.").max(5_000),
  website: z.string().max(1_000).optional().default("")
});

const fulfillmentSchema = z
  .object({
    status: z.enum(["paid", "fulfilled"]),
    carrier: z.string().trim().max(80, "Carrier name is too long.").regex(/^[^\r\n]*$/, "Carrier name must be one line."),
    trackingNumber: z.string().trim().max(160, "Tracking number is too long.").regex(/^[^\r\n]*$/, "Tracking number must be one line.")
  })
  .superRefine((values, context) => {
    if (values.status === "fulfilled" && !values.trackingNumber) {
      context.addIssue({ code: "custom", path: ["trackingNumber"], message: "Enter a tracking number before marking an order fulfilled." });
    }
  });

const emptyReviews: ReviewData = {
  summary: { average: 0, count: 0, breakdown: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 } },
  reviews: []
};

function parseReviewProductIds(metadata: Stripe.Metadata | null | undefined) {
  const raw = metadata?.reviewProductIds;
  if (!raw) return [];
  try {
    const values = JSON.parse(raw);
    return Array.isArray(values) && values.every((value) => typeof value === "string") ? values : [];
  } catch {
    return [];
  }
}

function parseFulfillmentOrderLines(metadata: Stripe.Metadata | null | undefined): OrderLine[] {
  const raw = metadata?.fulfillmentOrderLines;
  if (!raw) return [];
  try {
    const values: unknown = JSON.parse(raw);
    if (!Array.isArray(values)) return [];
    return values.flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const line = value as Record<string, unknown>;
      const quantity = line.quantity;
      const unitAmount = line.unitAmount;
      if (
        typeof line.productId !== "string" || typeof line.productName !== "string" ||
        typeof quantity !== "number" || typeof unitAmount !== "number" ||
        !Number.isInteger(quantity) || !Number.isInteger(unitAmount) ||
        quantity <= 0 || unitAmount < 0
      ) return [];
      return [{ productId: line.productId, productName: line.productName, quantity, unitAmount }];
    });
  } catch {
    return [];
  }
}

function credentialsMatch(request: Request, password: string) {
  const authorization = request.get("authorization");
  if (!authorization?.startsWith("Basic ")) return false;
  try {
    const decoded = Buffer.from(authorization.slice(6), "base64").toString("utf8");
    const separator = decoded.indexOf(":");
    if (separator < 0 || decoded.slice(0, separator) !== "clipit") return false;
    const expected = createHash("sha256").update(password).digest();
    const actual = createHash("sha256").update(decoded.slice(separator + 1)).digest();
    return timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

function sameOrigin(request: Request, appUrl: string) {
  const source = request.get("origin") ?? request.get("referer");
  if (!source) return false;
  try {
    return new URL(source).origin === appUrl;
  } catch {
    return false;
  }
}

function formatMoney(cents: number, currency = "usd") {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase()
  }).format(cents / 100);
}

function wantsJson(request: Request) {
  return request.path.startsWith("/api/") || request.path.startsWith("/webhooks/");
}

export function createApp(dependencies: AppDependencies = {}) {
  const config = dependencies.config ?? loadConfig();
  const stripe =
    dependencies.stripe ??
    (config.stripeSecretKey ? createStripeClient(config.stripeSecretKey) : undefined);
  const contactMailer = dependencies.contactMailer ?? createContactMailer(config);
  const reviewStore = dependencies.reviewStore ?? createReviewStore(config);
  const orderStore = dependencies.orderStore ?? createOrderStore(config);
  const googleSheetsOrderStore = dependencies.googleSheetsOrderStore ?? createGoogleSheetsOrderStore(config);
  const reviewMediaOrigin = config.reviews ? new URL(config.reviews.media.publicBaseUrl).origin : undefined;
  const app = express();

  app.set("trust proxy", 1);
  app.set("view engine", "ejs");
  app.set("views", path.join(projectRoot, "views"));
  app.disable("x-powered-by");

  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'"],
          imgSrc: ["'self'", "data:", ...(reviewMediaOrigin ? [reviewMediaOrigin] : [])],
          mediaSrc: ["'self'", ...(reviewMediaOrigin ? [reviewMediaOrigin] : [])],
          connectSrc: ["'self'"],
          frameSrc: ["https://www.youtube-nocookie.com"],
          frameAncestors: ["'none'"]
        }
      },
      referrerPolicy: { policy: "strict-origin-when-cross-origin" }
    })
  );

  /*
   * Stripe verifies the signature against the exact request bytes. This route must
   * stay before express.json(), or body parsing will make signature checks fail.
   */
  app.post(
    "/webhooks/stripe",
    express.raw({ type: "application/json", limit: "1mb" }),
    async (request, response) => {
      if (!stripe || !config.stripeWebhookSecret) {
        response.status(503).json({ error: "Stripe webhook is not configured." });
        return;
      }

      const signature = request.headers["stripe-signature"];
      if (!signature || Array.isArray(signature)) {
        response.status(400).json({ error: "Missing Stripe signature." });
        return;
      }

      let event: Stripe.Event;
      try {
        event = stripe.webhooks.constructEvent(
          request.body as Buffer,
          signature,
          config.stripeWebhookSecret
        );
      } catch (error) {
        console.warn("Rejected Stripe webhook with an invalid signature.", error);
        response.status(400).json({ error: "Invalid Stripe signature." });
        return;
      }

      try {
        if (
          event.type === "checkout.session.completed" ||
          event.type === "checkout.session.async_payment_succeeded"
        ) {
          const session = event.data.object as Stripe.Checkout.Session;
          if (session.payment_status === "paid") {
            const customerEmail = session.customer_details?.email ?? session.customer_email;
            const productIds = parseReviewProductIds(session.metadata);
            if (reviewStore && customerEmail && productIds.length) {
              const claims = await reviewStore.recordPaidOrder(session.id, customerEmail, productIds);
              await sendReviewInvitations(config, customerEmail, claims);
            }
            if (orderStore || googleSheetsOrderStore) {
              const orderLines = parseFulfillmentOrderLines(session.metadata);
              if (!orderLines.length) throw new Error("Paid Checkout session is missing fulfillment line items.");
              // This persists only data from Stripe's signed event plus the server-created
              // checkout metadata. Browser-provided cart prices and addresses are never used.
              const paidOrder = paidOrderFromSession(session, orderLines);
              await orderStore?.recordPaidOrder(paidOrder);
              if (googleSheetsOrderStore) {
                const added = await googleSheetsOrderStore.recordPaidOrder(paidOrder);
                console.info(`Google Sheets fulfillment row ${added ? "added" : "already existed"}.`);
              }
            }
            // Any future downstream side effect must remain idempotent because Stripe retries.
            await dependencies.onPaidOrder?.(session);
            console.info(
              JSON.stringify({
                message: "Stripe payment confirmed",
                eventId: event.id,
                checkoutSessionId: session.id,
                amountTotal: session.amount_total,
                currency: session.currency
              })
            );
          }
        }
        response.json({ received: true });
      } catch (error) {
        // A 500 tells Stripe to retry. Never return 200 if fulfillment processing failed.
        console.error("Stripe webhook processing failed.", error);
        response.status(500).json({ error: "Webhook processing failed." });
      }
    }
  );

  app.use(compression());
  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: false, limit: "100kb" }));
  app.use(
    express.static(path.join(projectRoot, "public"), {
      // Assets keep stable filenames in this starter, so use a short cache instead
      // of `immutable`; edits should reach customers without a filename build step.
      maxAge: config.nodeEnv === "production" ? "1h" : 0
    })
  );

  app.use((request, response, next) => {
    response.locals.currentPath = request.path;
    response.locals.products = products.filter((product) => product.active);
    response.locals.formatMoney = formatMoney;
    response.locals.appStoreUrl = config.appStoreUrl;
    response.locals.playStoreUrl = config.playStoreUrl;
    next();
  });

  async function loadReviewSummaries() {
    const activeProducts = products.filter((product) => product.active);
    if (!reviewStore) {
      return Object.fromEntries(activeProducts.map((product) => [product.id, emptyReviews.summary]));
    }
    const results = await Promise.all(
      activeProducts.map(async (product) => [product.id, (await reviewStore.getProductReviews(product.id)).summary] as const)
    );
    return Object.fromEntries(results);
  }

  app.get("/", async (_request, response, next) => {
    try {
      response.render("home", {
        title: "ClipIt Storefront",
        featuredProducts: products.filter((product) => product.active),
        reviewSummaries: await loadReviewSummaries(),
        howItWorksVideoEmbedUrl: config.howItWorksVideoEmbedUrl,
        testimonials
      });
    } catch (error) {
      next(error);
    }
  });

  app.get("/products", async (_request, response, next) => {
    try {
      response.render("products", { title: "Products — ClipIt", reviewSummaries: await loadReviewSummaries() });
    } catch (error) {
      next(error);
    }
  });

  app.get("/products/:slug", async (request, response, next) => {
    const product = findProductBySlug(request.params.slug);
    if (!product) {
      next();
      return;
    }
    try {
      const reviewData = reviewStore ? await reviewStore.getProductReviews(product.id) : emptyReviews;
      response.render("product", { title: `${product.name} — ClipIt`, product, reviewData });
    } catch (error) {
      next(error);
    }
  });

  app.get("/cart", (_request, response) => {
    response.render("cart", { title: "Your cart — ClipIt" });
  });

  app.get("/contact", (_request, response) => {
    response.render("contact", { title: "Contact ClipIt" });
  });

  app.get("/reviews/new", async (request, response, next) => {
    const token = typeof request.query.token === "string" ? request.query.token : "";
    if (!reviewStore || !token) {
      response.status(404).render("404", { title: "Review link unavailable — ClipIt" });
      return;
    }
    try {
      const claim = await reviewStore.claim(token);
      const product = claim ? products.find((candidate) => candidate.id === claim.productId) : undefined;
      if (!claim || !product) {
        response.status(410).render("review-unavailable", { title: "Review link unavailable — ClipIt" });
        return;
      }
      response.render("review-form", { title: `Review ${product.name} — ClipIt`, product, token });
    } catch (error) {
      next(error);
    }
  });

  const checkoutLimiter = rateLimit({
    windowMs: 60_000,
    limit: config.nodeEnv === "test" ? 1_000 : 15,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    message: { error: "Too many checkout attempts. Please wait a minute and try again." }
  });

  app.post("/api/checkout", checkoutLimiter, async (request, response, next) => {
    try {
      if (!stripe) {
        response.status(503).json({
          error: "Checkout is not configured yet. Add Stripe test keys to your environment."
        });
        return;
      }

      const lines = validateCart(request.body);
      const needsShipping = lines.some((line) => line.product.requiresShipping);
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        line_items: lines.map(({ product, quantity }) => ({
          quantity,
          price_data: {
            currency: product.currency,
            unit_amount: product.priceCents,
            product_data: {
              name: product.name,
              description: product.shortDescription,
              metadata: { catalogProductId: product.id }
            }
          }
        })),
        success_url: `${config.appUrl}/checkout/success?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${config.appUrl}/checkout/cancel`,
        billing_address_collection: "auto",
        ...(needsShipping
          ? {
              shipping_address_collection: {
                // Stripe's SDK validates these ISO codes again before the API request.
                allowed_countries: config.shippingCountries as Stripe.Checkout.SessionCreateParams.ShippingAddressCollection.AllowedCountry[]
              }
            }
          : {}),
        automatic_tax: { enabled: config.automaticTax },
        metadata: {
          catalogVersion: "placeholder-v1",
          itemCount: String(lines.reduce((total, line) => total + line.quantity, 0)),
          // This is a server-derived product list. It is consumed only by the
          // signed Stripe webhook to issue review links after payment succeeds.
          reviewProductIds: JSON.stringify([...new Set(lines.map((line) => line.product.id))]),
          // The fulfillment dashboard trusts this only after Stripe verifies the
          // signed webhook. It captures the exact catalog values at checkout time.
          fulfillmentOrderLines: JSON.stringify(
            lines.map(({ product, quantity }) => ({
              productId: product.id,
              productName: product.name,
              quantity,
              unitAmount: product.priceCents
            }))
          )
        }
      });

      if (!session.url) {
        throw new Error("Stripe did not return a Checkout URL.");
      }
      response.status(201).json({ url: session.url });
    } catch (error) {
      if (error instanceof CartValidationError) {
        response.status(400).json({ error: error.message });
        return;
      }
      next(error);
    }
  });

  const contactLimiter = rateLimit({
    windowMs: 60 * 60 * 1_000,
    limit: config.nodeEnv === "test" ? 1_000 : 5,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    message: { error: "Too many messages were sent from this connection. Please try again later." }
  });

  app.post("/api/contact", contactLimiter, async (request, response, next) => {
    const parsed = contactSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({ error: parsed.error.issues[0]?.message ?? "Please check the form." });
      return;
    }
    if (parsed.data.website) {
      // Pretend success to avoid teaching automated senders how the trap works.
      response.status(202).json({ received: true });
      return;
    }
    if (!contactMailer) {
      response.status(503).json({
        error: "Contact messages are not configured yet. Please try again later."
      });
      return;
    }

    try {
      await contactMailer.send(parsed.data);
      // Never log visitor message bodies or email addresses.
      console.info("Contact form message delivered.");
      response.status(202).json({ received: true });
    } catch (error) {
      console.error("Contact form delivery failed.", error);
      next(error);
    }
  });

  const reviewUpload = multer({
    storage: multer.memoryStorage(),
    limits: { files: 5, fileSize: 25 * 1024 * 1024, fields: 12, fieldSize: 6_000, parts: 18 },
    // File signatures are checked again in ReviewStore; MIME headers alone are untrusted.
    fileFilter: (_request, file, callback) => callback(null, /^(image\/(jpeg|png|webp)|video\/(mp4|webm))$/.test(file.mimetype))
  });
  const reviewLimiter = rateLimit({
    windowMs: 60 * 60 * 1_000,
    limit: config.nodeEnv === "test" ? 1_000 : 10,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    message: { error: "Too many review attempts. Please try again later." }
  });

  app.post("/api/reviews", reviewLimiter, reviewUpload.array("media", 5), async (request, response, next) => {
    if (!reviewStore) {
      response.status(503).json({ error: "Reviews are not configured yet." });
      return;
    }
    const parsed = reviewSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).json({ error: parsed.error.issues[0]?.message ?? "Please check the form." });
      return;
    }
    // Honeypot responses intentionally do not reveal the anti-spam check.
    if (parsed.data.website) {
      response.status(202).json({ received: true });
      return;
    }
    const files = Array.isArray(request.files) ? request.files : [];
    const altText = files.map((file, index) => {
      const value = request.body[`mediaAlt${index}`];
      return typeof value === "string" ? value.trim() : "";
    });
    try {
      await reviewStore.submit(
        parsed.data.token,
        { name: parsed.data.name, rating: parsed.data.rating, body: parsed.data.body },
        files.map((file, index) => ({ buffer: file.buffer, originalName: file.originalname, altText: altText[index] ?? "" }))
      );
      response.status(201).json({ received: true });
    } catch (error) {
      if (error instanceof ReviewClaimError) {
        response.status(410).json({ error: error.message });
        return;
      }
      if (error instanceof ReviewValidationError) {
        response.status(400).json({ error: error.message });
        return;
      }
      // The database constraint is the final race-safe duplicate-review guard.
      if (typeof error === "object" && error && "code" in error && error.code === "23505") {
        response.status(409).json({ error: "You have already reviewed this product." });
        return;
      }
      next(error);
    }
  });

  app.get("/checkout/success", async (request, response, next) => {
    const sessionId = typeof request.query.session_id === "string" ? request.query.session_id : "";
    if (!stripe || !sessionId.startsWith("cs_")) {
      response.status(400).render("checkout-status", {
        title: "Unable to verify payment — ClipIt",
        status: "unknown",
        message: "We could not verify this checkout session. Please check your Stripe receipt."
      });
      return;
    }

    try {
      // This display is convenient for the customer; fulfillment still relies on the
      // signed webhook because customers may close the browser before reaching here.
      const session = await stripe.checkout.sessions.retrieve(sessionId);
      const paid = session.payment_status === "paid";
      response.status(paid ? 200 : 202).render("checkout-status", {
        title: paid ? "Payment confirmed — ClipIt" : "Payment processing — ClipIt",
        status: paid ? "paid" : "processing",
        message: paid
          ? "Your payment was confirmed by Stripe. Save your Stripe receipt for your records."
          : "Stripe is still processing this payment. Your receipt will confirm the final result."
      });
    } catch (error) {
      next(error);
    }
  });

  app.get("/checkout/cancel", (_request, response) => {
    response.render("checkout-status", {
      title: "Checkout canceled — ClipIt",
      status: "canceled",
      message: "No payment was completed. Your cart is still here when you are ready."
    });
  });

  const fulfillmentLimiter = rateLimit({
    windowMs: 15 * 60 * 1_000,
    limit: config.nodeEnv === "test" ? 1_000 : 10,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    message: "Too many dashboard sign-in attempts. Please wait and try again."
  });

  function requireFulfillmentAccess(request: Request, response: Response) {
    if (!config.orders || !orderStore) {
      response.status(503).render("500", { title: "Fulfillment dashboard is not configured — ClipIt" });
      return false;
    }
    if (!credentialsMatch(request, config.orders.adminPassword)) {
      response.set("WWW-Authenticate", 'Basic realm="ClipIt fulfillment", charset="UTF-8"');
      response.status(401).type("text").send("Sign-in required.");
      return false;
    }
    return true;
  }

  app.get("/fulfillment", fulfillmentLimiter, async (request, response, next) => {
    if (!requireFulfillmentAccess(request, response)) return;
    try {
      const notice = request.query.updated === "1" ? "Order fulfillment details saved." : undefined;
      response.render("fulfillment", { title: "Fulfillment — ClipIt", orders: await orderStore!.listOrders(), notice });
    } catch (error) {
      next(error);
    }
  });

  app.post("/fulfillment/:sessionId", fulfillmentLimiter, async (request, response, next) => {
    if (!requireFulfillmentAccess(request, response)) return;
    if (!sameOrigin(request, config.appUrl)) {
      response.status(403).type("text").send("This dashboard request was blocked for safety. Reload the page and try again.");
      return;
    }
    const parsed = fulfillmentSchema.safeParse(request.body);
    if (!parsed.success) {
      response.status(400).type("text").send(parsed.error.issues[0]?.message ?? "Please check the fulfillment form.");
      return;
    }
    try {
      const sessionId = request.params.sessionId;
      if (typeof sessionId !== "string") {
        response.status(400).type("text").send("A valid order session ID is required.");
        return;
      }
      const updated = await orderStore!.updateFulfillment(sessionId, parsed.data);
      if (!updated) {
        response.status(404).type("text").send("Order not found.");
        return;
      }
      response.redirect(303, "/fulfillment?updated=1");
    } catch (error) {
      next(error);
    }
  });

  app.get("/health", (_request, response) => {
    response.json({ status: "ok" });
  });

  app.use((request, response) => {
    if (wantsJson(request)) {
      response.status(404).json({ error: "Not found." });
      return;
    }
    response.status(404).render("404", { title: "Page not found — ClipIt" });
  });

  app.use((error: unknown, request: Request, response: Response, _next: NextFunction) => {
    const detail = error instanceof Error ? error.message : "Unknown error";
    console.error("Request failed.", { path: request.path, detail });
    if (wantsJson(request)) {
      if (error instanceof MulterError) {
        response.status(400).json({ error: error.code === "LIMIT_FILE_SIZE" ? "Each video can be up to 25 MB; each image can be up to 5 MB." : "You can upload up to five files." });
        return;
      }
      response.status(500).json({
        error: "We could not complete that request. Please try again."
      });
      return;
    }
    response.status(500).render("500", { title: "Something went wrong — ClipIt" });
  });

  return app;
}
