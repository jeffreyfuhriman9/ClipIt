# ClipIt Store

A small, production-oriented e-commerce starter for the ClipIt Button and companion app. The app uses one Node.js/TypeScript service with Express-rendered pages, a browser-persisted cart, and Stripe-hosted Checkout.

> **Important:** Product names, prices, descriptions, images, app links, benefits, and compatibility statements are placeholders. Review every placeholder before accepting an order.

## Why this stack

Express + TypeScript keeps the storefront and secure checkout API in one deployable service. Compared with a separate React front end and API, it has fewer moving parts, no browser-side framework upgrade cycle, fast server-rendered pages, and a straightforward custom-domain deployment. Stripe Checkout is hosted by Stripe, so card data never reaches this app.

## What is included

- Responsive home, product listing, product detail, cart, payment result, 404, and error pages
- Catalog structure ready for products, bundles, or accessories
- Cart add/update/remove with `localStorage` persistence and malformed-data recovery
- Server-authoritative prices and quantity limits
- Stripe-hosted Checkout, shipping-address collection, optional Stripe Tax, and signed webhook handling
- Sticky primary navigation and a rate-limited contact form with server-side SMTP delivery
- Security headers, content security policy, request-size limits, checkout rate limiting, graceful shutdown, and a health endpoint
- Verified-purchase reviews: star ratings, aggregate breakdowns, accessible review form, upload descriptions, and one-time links issued only after a signed paid Stripe webhook
- Unit and integration tests for cart persistence, validation, checkout creation/errors, review eligibility/submission, success verification, and webhook validation/retries
- Render deployment blueprint and custom-domain instructions

## Project structure

```text
.
├── public/
│   ├── images/                 # Clearly labeled placeholder SVG art
│   ├── cart-store.js           # Cart persistence logic (unit tested)
│   ├── store.js                # Storefront interactions and checkout request
│   └── styles.css              # Responsive design system
├── src/
│   ├── data/products.ts        # EDIT THIS: all product content and prices
│   ├── services/cart.ts        # Server-side cart validation
│   ├── services/stripe.ts      # Stripe client configuration
│   ├── types/store.ts
│   ├── app.ts                  # Pages, checkout API, webhook, errors, security
│   ├── config.ts               # Validated environment configuration
│   └── server.ts               # Process startup and graceful shutdown
├── tests/                      # Unit and integration tests
├── views/                      # EJS page templates and partials
├── .env.example
├── render.yaml
├── package.json
└── tsconfig.json
```

## 1. Install and run locally

Install Node.js 22 LTS or newer from [nodejs.org](https://nodejs.org/), then open Terminal in this folder:

```bash
corepack enable
pnpm install
cp .env.example .env
pnpm dev
```

Open <http://localhost:3000>. Browsing and cart behavior work without Stripe keys; checkout intentionally returns a setup message until the keys are configured.

If you prefer npm, use `npm install`, `npm run dev`, and the matching `npm run ...` commands below.

## 2. Replace placeholder content

Start with [`src/data/products.ts`](src/data/products.ts). Each product has:

- a stable `id` used by carts and Stripe metadata;
- a URL-safe `slug`;
- display copy and an image path;
- `priceCents` in the smallest currency unit (`4999` means $49.99);
- an `active` flag; and
- `requiresShipping`, which controls whether Stripe collects a shipping address.

Product features live in `src/data/products.ts`. Homepage testimonials live in [`src/data/testimonials.ts`](src/data/testimonials.ts). Testimonials ship with clearly marked placeholders: replace them only with accurate, consented customer feedback. Product-page reviews are deliberately not stored in source code: they appear only after a verified purchaser submits one through the flow below. The homepage testimonial rail scrolls automatically, supports mouse dragging and touch scrolling, and pauses for hover, keyboard focus, and reduced-motion preferences.

Replace SVGs in `public/images/` with approved product assets, keeping either the same filenames or updating the catalog paths. Search the project for `PLACEHOLDER` before launch:

```bash
rg -n "PLACEHOLDER|replace_me|example\.com" . --glob '!node_modules/**'
```

Also replace the footer support email in `views/partials/footer.ejs` and review the hero/app copy in `views/home.ejs`.

### Add product-gallery photos

Each catalog item has an `images` array in [`src/data/products.ts`](src/data/products.ts). Place your approved product files in `public/images/`, then add each image and meaningful alt text to that product's array:

```ts
images: [
  { src: "/images/clipit-button-front.jpg", alt: "Describe the front view accurately" },
  { src: "/images/clipit-button-side.jpg", alt: "Describe the side view accurately" }
]
```

The first entry is the main product-page photo. If you also want to change the listing/cart image, update that product's existing `image` and `imageAlt` fields to match it. Two or more entries automatically show thumbnail selection, previous/next controls, keyboard arrow-key navigation, and touch swipe on the product page. There is no public upload control for product images, which keeps storefront content under your control; add or replace these approved files from VS Code when you update the catalog.

### Add the How It Works YouTube video

Paste your YouTube watch, Share, Shorts, or embed URL into your local `.env` file, then restart `pnpm dev`:

```env
HOW_IT_WORKS_YOUTUBE_URL=https://www.youtube.com/watch?v=YOUR_VIDEO_ID
```

The home-page section appears only when this setting is present. The server accepts only a valid YouTube video ID and renders the privacy-enhanced `youtube-nocookie.com` player. On Render, add the same variable under the service’s Environment settings and redeploy.

## 3. Configure Stripe test mode

1. Create or sign in to a Stripe account and switch to a test sandbox.
2. Copy the test secret key from **Developers → API keys** into `.env` as `STRIPE_SECRET_KEY`. It begins with `sk_test_`.
3. Install the [Stripe CLI](https://docs.stripe.com/stripe-cli), sign in, and forward test webhooks:

   ```bash
   stripe login
   stripe listen --forward-to localhost:3000/webhooks/stripe
   ```

4. Copy the CLI’s `whsec_...` signing secret into `.env` as `STRIPE_WEBHOOK_SECRET`, then restart the app.
5. Add a product to the cart and continue to checkout. On Stripe’s hosted test page, use:
   - success: `4242 4242 4242 4242`;
   - any future expiration date;
   - any three-digit CVC; and
   - any syntactically valid remaining values.

For failure testing, use Stripe’s current decline and authentication test cards from its testing documentation. Never use real card details in test mode.

### Webhook behavior and fulfillment

The webhook validates Stripe’s signature against the **raw request body** and confirms `payment_status === "paid"`. The default handler records a structured confirmation in application logs. The `onPaidOrder` callback in `src/app.ts` is the intended integration point for a fulfillment provider or transactional email service.

Those services were deliberately not invented or added. Before shipping real orders, connect that callback to your selected fulfillment workflow and store processed Stripe event IDs in durable storage so downstream actions remain idempotent across retries and deploys. Stripe remains the payment/order record in this starter.

### Configure the contact form

The Contact page sends messages to `support@clipitbutton.com`. It needs an SMTP account before it can deliver live email; the app intentionally returns a safe setup error rather than sending through an unconfigured service.

1. Choose an email delivery provider that supports SMTP, or use an SMTP account you control.
2. Obtain its SMTP host, port, username, password/app password, and approved From address.
3. Add these **only to `.env` locally or Render environment variables in production**:

   ```env
   SMTP_HOST=your-provider-host
   SMTP_PORT=587
   SMTP_SECURE=false
   SMTP_USER=your-smtp-username
   SMTP_PASS=your-smtp-password-or-app-password
   CONTACT_FROM_EMAIL=ClipIt Website <no-reply@your-domain.example>
   CONTACT_TO_EMAIL=support@clipitbutton.com
   ```

   Port `587` commonly uses `SMTP_SECURE=false` and upgrades to TLS; port `465` uses `SMTP_SECURE=true`. Follow your provider’s documented values.
4. Restart the server, submit a message at `/contact`, then reply to the received email to confirm the Reply-To address works.

The form validates name, email, and message length; rate-limits submissions; includes a hidden bot trap; and never logs message content or email addresses. SMTP credentials are never sent to the browser.

### Configure verified-purchase reviews

Reviews are disabled until **all** review variables are configured. This avoids ever displaying a “Verified Purchase” badge based on browser input. The signed Stripe `checkout.session.completed` (or asynchronous-payment-success) webhook writes the purchased product IDs and buyer email to Postgres, creates a random one-time review token, and emails its link using the SMTP account already configured for Contact. The database stores only a SHA-256 hash of that token.

1. Create a PostgreSQL database. On Render, use **New → PostgreSQL** and copy its internal `DATABASE_URL` into the web service. If you use another host, require TLS and use its secure connection string.
2. Run the included migration once:

   ```bash
   psql "$DATABASE_URL" -f db/migrations/001_verified_reviews.sql
   ```

   The service has a safe `CREATE TABLE IF NOT EXISTS` fallback, but applying the migration is the normal production practice.
3. Create an S3-compatible bucket for review uploads—for example Cloudflare R2 or AWS S3. Give the app credential **only** permission to write objects in a `reviews/` prefix. Configure a separate public CDN/custom media hostname for delivered review media; it should permit only read access. Do not use your Stripe or database credentials here.
4. Add all values below to `.env` locally and to Render in production. Values are validated as an all-or-nothing group:

   ```env
   DATABASE_URL=postgresql://...
   REVIEW_MEDIA_BUCKET=clipit-review-media
   REVIEW_MEDIA_REGION=auto
   REVIEW_MEDIA_ENDPOINT=https://YOUR-S3-COMPATIBLE-ENDPOINT
   REVIEW_MEDIA_ACCESS_KEY_ID=...
   REVIEW_MEDIA_SECRET_ACCESS_KEY=...
   REVIEW_MEDIA_PUBLIC_BASE_URL=https://media.your-domain.example
   ```

5. Ensure `SMTP_*` and `CONTACT_FROM_EMAIL` are configured too; they deliver the private one-time review links. Review requests are transactional post-purchase email—confirm this fits your email/privacy policy.

The app accepts no more than five attachments per review: JPG, PNG, or WebP images up to 5 MB each, or MP4/WebM videos up to 25 MB each. It checks browser hints first and reads the actual file signature again on the server; every upload needs a short accessible description. A database constraint blocks duplicate product reviews by the same buyer email even if two tabs submit at once. Rate limiting plus a honeypot reduce automated abuse.

#### End-to-end review test

1. Configure the database, media bucket/CDN, SMTP, Stripe test keys, and Stripe CLI webhook forwarding.
2. Make a Stripe test payment with `4242 4242 4242 4242`.
3. Confirm the webhook returns `200` in the Stripe CLI and a review-invitation email reaches the Checkout email address.
4. Open the private link, submit a rating/review (and optionally an allowed file plus its description), then open the product page.
5. Confirm the rating summary, breakdown, submitted review, media, and **Verified Purchase** badge appear. Reopen the link and submit again: it must be rejected. Complete another test order using the same email and confirm the duplicate-review guard rejects a second review for that product.

## 4. Test and build

```bash
pnpm test
pnpm typecheck
pnpm build
pnpm start
```

`pnpm start` runs the compiled production build. The server binds to `0.0.0.0` and respects the `PORT` environment variable.

## 5. Deploy on Render

Render is the simplest fit for this single Node service and supports managed HTTPS plus custom domains.

1. Create a Git repository for this folder and push it to GitHub or GitLab. Do not commit `.env`.
2. In Render, choose **New → Blueprint** and select the repository. `render.yaml` supplies the build, start, health check, and non-secret defaults.
3. Set the prompted secrets/values:
   - `APP_URL=https://your-domain.example` (temporarily use the Render URL before the domain is connected);
   - `STRIPE_SECRET_KEY=sk_test_...` while testing;
   - `STRIPE_WEBHOOK_SECRET=whsec_...` from the deployed endpoint;
   - both companion-app URLs, even if they temporarily remain explicit placeholder destinations.
   - SMTP/contact-form variables, if you want the Contact page to deliver messages.
4. In Stripe Workbench/Webhooks, add `https://YOUR-HOST/webhooks/stripe` and subscribe to:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
5. Copy that endpoint’s signing secret into Render. It is different from the Stripe CLI’s local signing secret.
6. Run a complete test payment against the deployed test-mode site and confirm a `Stripe payment confirmed` log entry.

### Custom domain, DNS, and HTTPS

1. In the Render service, open **Settings → Custom Domains → Add Custom Domain** and enter your root domain or `www` hostname.
2. At your DNS provider, point the records Render shows you to the service’s `onrender.com` hostname. Typically:
   - root/apex: `ANAME` or `ALIAS` to the Render hostname (use Render’s displayed fallback if your provider lacks these);
   - `www`: `CNAME` to the Render hostname.
3. Remove conflicting `AAAA` records while configuring Render, then click **Verify** in Render.
4. Render automatically issues and renews TLS certificates and redirects HTTP to HTTPS.
5. Change `APP_URL` to the final `https://...` domain.
6. Create a new Stripe webhook endpoint using the final domain, update `STRIPE_WEBHOOK_SECRET`, and test once more.

Always follow the exact DNS targets displayed for your service because providers handle apex domains differently.

## 6. Go-live checklist

- Replace every `PLACEHOLDER`, example URL, support email, image, price, and product claim.
- Decide which countries you will ship to and set `SHIPPING_COUNTRIES` (comma-separated ISO codes such as `US,CA`).
- Decide shipping charges/fulfillment. This starter collects addresses but does not invent shipping rates.
- Configure Stripe Tax and set `STRIPE_AUTOMATIC_TAX=true` only after verifying registrations and tax settings with a qualified advisor.
- Add your privacy, terms, shipping, returns/refunds, and contact policies; requirements depend on your business and jurisdiction.
- Connect the paid-order callback to durable, idempotent fulfillment and email handling.
- Configure Postgres and an S3-compatible review-media bucket/CDN if you enable reviews; complete the review test above.
- Complete test-mode success, decline, retry, mobile, and webhook tests.
- Replace test keys with live keys, create a live-mode webhook endpoint, and make a controlled live purchase.
- Protect the Stripe account with MFA and limit Render access to trusted team members.
- Add uptime/error monitoring and confirm logs do not contain sensitive customer data.

## Xcode workflow

Xcode can edit and run this project, though it is not specialized for Node/TypeScript.

1. In Xcode choose **File → Open** and select this project folder (not an individual file).
2. Use Xcode’s source navigator to edit TypeScript, EJS, CSS, and JavaScript files.
3. Run the app from Xcode’s integrated terminal if available, or keep macOS Terminal beside Xcode and run `pnpm dev` from the project folder.
4. Open <http://localhost:3000> in a browser; the dev process automatically restarts after server-file changes. Refresh the browser for template/CSS changes.

For this web stack, VS Code or another TypeScript-focused editor is easier because it provides richer Node task/debug integration and extension support. Xcode remains perfectly usable as a text editor, and no `.xcodeproj` is required.

## Common issues

**Checkout says it is not configured**  
`STRIPE_SECRET_KEY` is missing from the running process. Confirm `.env` exists beside `package.json` and restart the server.

**Webhook returns “Invalid Stripe signature”**  
Use the signing secret for that exact endpoint and environment. The local Stripe CLI, deployed test endpoint, and live endpoint each have different `whsec_...` values. Do not move the webhook route below JSON parsing in `src/app.ts`.

**Checkout redirects to the wrong host**  
Set `APP_URL` to the exact public origin, with `https://` in production and no path or trailing slash.

**Cart does not persist**  
Check whether private browsing or browser policies block local storage. Cart data is local to a browser/device and intentionally does not require an account.

**Render domain will not verify**  
Remove stale/conflicting `A`, `CNAME`, or `AAAA` records, use the target Render displays, allow DNS propagation time, and verify again.

**A paid order did not trigger your custom fulfillment**  
Check Stripe webhook delivery logs and Render logs. Return a non-2xx status when your handler fails so Stripe retries; store event IDs before adding side effects to prevent duplicate fulfillment.

**Review links are not delivered**  
Confirm the signed Stripe webhook succeeded, then check the app logs and the configured SMTP sender's delivery logs. Review links are sent only when `DATABASE_URL`, every `REVIEW_MEDIA_*` value, and SMTP are configured.

**Review images or videos do not load**  
Confirm `REVIEW_MEDIA_PUBLIC_BASE_URL` is the exact public/CDN origin and that its bucket/CDN policy allows reads. The app adds this configured origin to its Content Security Policy; a different media hostname will be blocked intentionally.

## Security model

- The secret Stripe key and webhook signing secret exist only in server environment variables.
- The browser submits product IDs and quantities; server catalog prices are authoritative.
- Stripe hosts payment fields and handles payment credentials.
- The webhook uses the untouched raw payload plus Stripe signature verification.
- The success page is informational; order confirmation/fulfillment relies on the signed webhook.
- Review eligibility is created only by the signed paid Stripe webhook; review tokens are random, one-time, and stored hashed. The review API verifies the token against Postgres and product association before publishing anything.
- Uploaded media is type- and size-validated server-side before storage. Use scoped storage credentials and a read-only CDN/public origin.
- `.env` is ignored by Git; `.env.example` contains names and placeholders only.

Dependencies should be reviewed and updated routinely. Run `pnpm audit` and the test suite before deploying dependency upgrades.
