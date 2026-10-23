import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { S3Client } from "@aws-sdk/client-s3";
import { fileTypeFromBuffer } from "file-type";
import { Pool } from "pg";
import nodemailer from "nodemailer";
import type { AppConfig } from "../config.js";

export type PublicReview = {
  id: string;
  rating: number;
  name: string;
  body: string;
  createdAt: string;
  verifiedPurchase: true;
  media: Array<{ kind: "image" | "video"; url: string; altText: string }>;
};

export type ReviewSummary = { average: number; count: number; breakdown: Record<number, number> };
export type ReviewData = { summary: ReviewSummary; reviews: PublicReview[] };
export type ReviewUpload = { buffer: Buffer; originalName: string; altText: string };
export type ReviewClaim = { productId: string; token: string };

export class ReviewValidationError extends Error {}
export class ReviewClaimError extends Error {}

type Claim = { orderItemId: number; productId: string; customerEmail: string };
const accepted = new Map([
  ["image/jpeg", { kind: "image" as const, extension: "jpg", maxBytes: 5 * 1024 * 1024 }],
  ["image/png", { kind: "image" as const, extension: "png", maxBytes: 5 * 1024 * 1024 }],
  ["image/webp", { kind: "image" as const, extension: "webp", maxBytes: 5 * 1024 * 1024 }],
  ["video/mp4", { kind: "video" as const, extension: "mp4", maxBytes: 25 * 1024 * 1024 }],
  ["video/webm", { kind: "video" as const, extension: "webm", maxBytes: 25 * 1024 * 1024 }]
]);

function tokenHash(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

export class ReviewStore {
  private readonly pool: Pool;
  private s3?: S3Client;
  private s3Module?: Promise<typeof import("@aws-sdk/client-s3")>;
  private initialized?: Promise<void>;

  constructor(private readonly config: NonNullable<AppConfig["reviews"]>) {
    this.pool = new Pool({ connectionString: config.databaseUrl, ssl: { rejectUnauthorized: true } });
  }

  private async getS3() {
    if (!this.config.media) throw new ReviewValidationError("Photo and video uploads are not enabled.");
    // Do not load the large AWS SDK during ordinary storefront startup. Reviews
    // are optional, and this keeps browsing/checkout independent of media storage.
    this.s3Module ??= import("@aws-sdk/client-s3");
    const module = await this.s3Module;
    this.s3 ??= new module.S3Client({
      region: this.config.media.region,
      endpoint: this.config.media.endpoint,
      forcePathStyle: false,
      credentials: { accessKeyId: this.config.media.accessKeyId, secretAccessKey: this.config.media.secretAccessKey }
    });
    return { client: this.s3, PutObjectCommand: module.PutObjectCommand };
  }

  private async ensureSchema() {
    this.initialized ??= this.pool.query(`
      CREATE TABLE IF NOT EXISTS review_orders (
        stripe_session_id TEXT PRIMARY KEY, customer_email TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE TABLE IF NOT EXISTS review_order_items (
        id BIGSERIAL PRIMARY KEY, stripe_session_id TEXT NOT NULL REFERENCES review_orders(stripe_session_id) ON DELETE CASCADE,
        product_id TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, reviewed_at TIMESTAMPTZ,
        UNIQUE (stripe_session_id, product_id)
      );
      CREATE TABLE IF NOT EXISTS product_reviews (
        id UUID PRIMARY KEY, order_item_id BIGINT NOT NULL UNIQUE REFERENCES review_order_items(id),
        product_id TEXT NOT NULL, customer_email TEXT NOT NULL, reviewer_name TEXT NOT NULL,
        rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5), body TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (product_id, customer_email)
      );
      CREATE TABLE IF NOT EXISTS review_media (
        id UUID PRIMARY KEY, review_id UUID NOT NULL REFERENCES product_reviews(id) ON DELETE CASCADE,
        object_key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL CHECK (kind IN ('image', 'video')),
        public_url TEXT NOT NULL, alt_text TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS product_reviews_product_created ON product_reviews(product_id, created_at DESC);
    `).then(() => undefined);
    return this.initialized;
  }

  async recordPaidOrder(sessionId: string, customerEmail: string, products: string[]): Promise<ReviewClaim[]> {
    await this.ensureSchema();
    const client = await this.pool.connect();
    const claims: ReviewClaim[] = [];
    try {
      await client.query("BEGIN");
      await client.query(
        "INSERT INTO review_orders (stripe_session_id, customer_email) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [sessionId, customerEmail]
      );
      for (const productId of [...new Set(products)]) {
        const existing = await client.query("SELECT id FROM review_order_items WHERE stripe_session_id=$1 AND product_id=$2", [sessionId, productId]);
        if (existing.rowCount) continue;
        const token = randomBytes(32).toString("base64url");
        await client.query(
          "INSERT INTO review_order_items (stripe_session_id, product_id, token_hash) VALUES ($1, $2, $3)",
          [sessionId, productId, tokenHash(token)]
        );
        claims.push({ productId, token });
      }
      await client.query("COMMIT");
      return claims;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally { client.release(); }
  }

  async claim(token: string): Promise<Claim | undefined> {
    await this.ensureSchema();
    const result = await this.pool.query<Claim>(`
      SELECT i.id AS "orderItemId", i.product_id AS "productId", o.customer_email AS "customerEmail"
      FROM review_order_items i JOIN review_orders o ON o.stripe_session_id=i.stripe_session_id
      WHERE i.token_hash=$1 AND i.reviewed_at IS NULL`, [tokenHash(token)]);
    return result.rows[0];
  }

  async getProductReviews(productId: string): Promise<ReviewData> {
    await this.ensureSchema();
    const [reviewsResult, counts] = await Promise.all([
      this.pool.query(`SELECT id, rating, reviewer_name, body, created_at FROM product_reviews WHERE product_id=$1 ORDER BY created_at DESC`, [productId]),
      this.pool.query(`SELECT rating, COUNT(*)::int AS count FROM product_reviews WHERE product_id=$1 GROUP BY rating`, [productId])
    ]);
    const media = await this.pool.query(`SELECT review_id, kind, public_url, alt_text FROM review_media WHERE review_id = ANY($1::uuid[])`, [reviewsResult.rows.map((row) => row.id)]);
    const mediaByReview = new Map<string, PublicReview["media"]>();
    for (const row of media.rows) {
      const list = mediaByReview.get(row.review_id) ?? [];
      list.push({ kind: row.kind, url: row.public_url, altText: row.alt_text });
      mediaByReview.set(row.review_id, list);
    }
    const breakdown: Record<number, number> = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
    for (const row of counts.rows) breakdown[Number(row.rating)] = row.count;
    const reviews = reviewsResult.rows.map((row) => ({
      id: row.id, rating: Number(row.rating), name: row.reviewer_name, body: row.body,
      createdAt: new Date(row.created_at).toISOString(), verifiedPurchase: true as const,
      media: mediaByReview.get(row.id) ?? []
    }));
    const total = reviews.length;
    return { summary: { count: total, average: total ? reviews.reduce((sum, review) => sum + review.rating, 0) / total : 0, breakdown }, reviews };
  }

  async submit(token: string, values: { name: string; rating: number; body: string }, uploads: ReviewUpload[]) {
    const claim = await this.claim(token);
    if (!claim) throw new ReviewClaimError("This review link is invalid, expired, or already used.");
    if (uploads.length > 5) throw new ReviewValidationError("You can upload up to five photos or videos.");
    if (uploads.length && !this.config.media) {
      throw new ReviewValidationError("Photo and video uploads are not enabled for reviews yet.");
    }
    const prepared = [] as Array<{ key: string; url: string; kind: "image" | "video"; altText: string; buffer: Buffer; contentType: string }>;
    for (const upload of uploads) {
      const type = await fileTypeFromBuffer(upload.buffer);
      const allowed = type && accepted.get(type.mime);
      if (!upload.altText.trim() || upload.altText.length > 200) {
        throw new ReviewValidationError("Add a short description for every uploaded photo or video.");
      }
      if (!allowed || upload.buffer.length > allowed.maxBytes) {
        throw new ReviewValidationError("Uploads must be JPG, PNG, WebP, MP4, or WebM and within the stated size limits.");
      }
      const key = `reviews/${claim.productId}/${randomUUID()}.${allowed.extension}`;
      prepared.push({ key, url: `${this.config.media!.publicBaseUrl}/${key}`, kind: allowed.kind, altText: upload.altText, buffer: upload.buffer, contentType: type.mime });
    }
    if (prepared.length) {
      const s3 = await this.getS3();
      for (const item of prepared) await s3.client.send(new s3.PutObjectCommand({ Bucket: this.config.media!.bucket, Key: item.key, Body: item.buffer, ContentType: item.contentType, CacheControl: "public, max-age=31536000, immutable" }));
    }
    await this.ensureSchema();
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const locked = await client.query<Claim>(`SELECT i.id AS "orderItemId", i.product_id AS "productId", o.customer_email AS "customerEmail" FROM review_order_items i JOIN review_orders o ON o.stripe_session_id=i.stripe_session_id WHERE i.token_hash=$1 AND i.reviewed_at IS NULL FOR UPDATE`, [tokenHash(token)]);
      if (!locked.rowCount) throw new ReviewClaimError("This review link is no longer available.");
      const reviewId = randomUUID();
      await client.query(`INSERT INTO product_reviews (id, order_item_id, product_id, customer_email, reviewer_name, rating, body) VALUES ($1,$2,$3,$4,$5,$6,$7)`, [reviewId, claim.orderItemId, claim.productId, claim.customerEmail, values.name, values.rating, values.body]);
      for (const item of prepared) await client.query(`INSERT INTO review_media (id, review_id, object_key, kind, public_url, alt_text) VALUES ($1,$2,$3,$4,$5,$6)`, [randomUUID(), reviewId, item.key, item.kind, item.url, item.altText]);
      await client.query("UPDATE review_order_items SET reviewed_at=now() WHERE id=$1", [claim.orderItemId]);
      await client.query("COMMIT");
    } catch (error) { await client.query("ROLLBACK"); throw error; } finally { client.release(); }
  }
}

export function createReviewStore(config: AppConfig) {
  return config.reviews ? new ReviewStore(config.reviews) : undefined;
}

/**
 * Review invitations are sent only after Stripe's signed webhook marks a Checkout
 * session as paid. The opaque token is stored hashed, so a database leak cannot be
 * used to submit a review as a purchaser.
 */
export async function sendReviewInvitations(
  config: AppConfig,
  customerEmail: string,
  claims: ReviewClaim[]
) {
  if (!config.smtp || !claims.length) return;
  const transporter = nodemailer.createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    secure: config.smtp.secure,
    auth: { user: config.smtp.user, pass: config.smtp.pass },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000
  });
  await Promise.all(
    claims.map((claim) => {
      const reviewUrl = `${config.appUrl}/reviews/new?token=${encodeURIComponent(claim.token)}`;
      return transporter.sendMail({
        from: config.smtp!.from,
        to: customerEmail,
        replyTo: config.contactToEmail,
        subject: "Share feedback on your recent purchase",
        text: [
          "Thank you for your purchase.",
          "",
          "Use this private link to leave one verified review for the product you purchased:",
          reviewUrl,
          "",
          "This link can be used once. If you did not place this order, you can ignore this email."
        ].join("\n"),
        disableFileAccess: true,
        disableUrlAccess: true
      });
    })
  );
}
