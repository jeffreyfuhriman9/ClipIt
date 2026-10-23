import "dotenv/config";
import { z } from "zod";

const optionalText = z.preprocess(
  (value) => (value === "" ? undefined : value),
  z.string().min(1).optional()
);
const optionalUrl = z.preprocess(
  (value) => (value === "" ? undefined : value),
  z.string().url().optional()
);

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  APP_URL: z.string().url().default("http://localhost:3000"),
  STRIPE_SECRET_KEY: z.string().min(1).optional(),
  STRIPE_WEBHOOK_SECRET: z.string().min(1).optional(),
  SHIPPING_COUNTRIES: z.string().default("US"),
  STRIPE_AUTOMATIC_TAX: z.string().default("false"),
  APP_STORE_URL: z.string().url().default("https://example.com/replace-with-app-store-url"),
  PLAY_STORE_URL: z.string().url().default("https://example.com/replace-with-play-store-url"),
  HOW_IT_WORKS_YOUTUBE_URL: optionalUrl,
  SMTP_HOST: optionalText,
  SMTP_PORT: z.coerce.number().int().min(1).max(65535).default(587),
  SMTP_SECURE: z.string().default("false"),
  SMTP_USER: optionalText,
  SMTP_PASS: optionalText,
  CONTACT_FROM_EMAIL: z.preprocess(
    (value) => (value === "" ? undefined : value),
    z.string().min(3).optional()
  ),
  CONTACT_TO_EMAIL: z.string().email().default("support@clipitbutton.com"),
  ORDER_DATABASE_URL: optionalText,
  FULFILLMENT_ADMIN_PASSWORD: optionalText,
  GOOGLE_SHEETS_SPREADSHEET_ID: optionalText,
  GOOGLE_SERVICE_ACCOUNT_EMAIL: z.preprocess(
    (value) => (value === "" ? undefined : value),
    z.string().email().optional()
  ),
  GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY: optionalText,
  GOOGLE_SHEETS_TAB_NAME: z.string().trim().min(1).max(100).default("Orders"),
  DATABASE_URL: optionalText,
  REVIEW_MEDIA_BUCKET: optionalText,
  REVIEW_MEDIA_REGION: z.string().default("auto"),
  REVIEW_MEDIA_ENDPOINT: optionalUrl,
  REVIEW_MEDIA_ACCESS_KEY_ID: optionalText,
  REVIEW_MEDIA_SECRET_ACCESS_KEY: optionalText,
  REVIEW_MEDIA_PUBLIC_BASE_URL: optionalUrl
});

const countryCode = /^[A-Z]{2}$/;

function toYouTubeEmbedUrl(value: string | undefined) {
  if (!value) return undefined;
  const parsed = new URL(value);
  const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
  let videoId: string | null = null;
  if (host === "youtu.be") videoId = parsed.pathname.slice(1).split("/")[0] ?? null;
  if (host === "youtube.com") {
    videoId = parsed.searchParams.get("v") ?? parsed.pathname.match(/^\/(?:embed|shorts)\/([^/?]+)/)?.[1] ?? null;
  }
  if (!videoId || !/^[A-Za-z0-9_-]{11}$/.test(videoId)) {
    throw new Error("HOW_IT_WORKS_YOUTUBE_URL must be a valid YouTube video URL.");
  }
  return `https://www.youtube-nocookie.com/embed/${videoId}`;
}

export type AppConfig = {
  nodeEnv: "development" | "test" | "production";
  port: number;
  appUrl: string;
  stripeSecretKey?: string;
  stripeWebhookSecret?: string;
  shippingCountries: string[];
  automaticTax: boolean;
  appStoreUrl: string;
  playStoreUrl: string;
  howItWorksVideoEmbedUrl?: string;
  smtp?: {
    host: string;
    port: number;
    secure: boolean;
    user: string;
    pass: string;
    from: string;
  };
  contactToEmail: string;
  orders?: {
    databaseUrl: string;
    adminPassword: string;
  };
  googleSheets?: {
    spreadsheetId: string;
    serviceAccountEmail: string;
    serviceAccountPrivateKey: string;
    tabName: string;
  };
  reviews?: {
    databaseUrl: string;
    // Media storage is optional. A database-only setup supports verified star and
    // text reviews without asking a small store to operate an object-storage bucket.
    media?: {
      bucket: string;
      region: string;
      endpoint: string;
      accessKeyId: string;
      secretAccessKey: string;
      publicBaseUrl: string;
    };
  };
};

export function loadConfig(source: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = envSchema.safeParse(source);
  if (!parsed.success) {
    throw new Error(`Invalid environment configuration: ${parsed.error.message}`);
  }

  const shippingCountries = parsed.data.SHIPPING_COUNTRIES.split(",")
    .map((value) => value.trim().toUpperCase())
    .filter(Boolean);

  if (!shippingCountries.length || shippingCountries.some((code) => !countryCode.test(code))) {
    throw new Error("SHIPPING_COUNTRIES must be a comma-separated list of two-letter country codes.");
  }

  const appUrl = parsed.data.APP_URL.replace(/\/$/, "");
  const howItWorksVideoEmbedUrl = toYouTubeEmbedUrl(parsed.data.HOW_IT_WORKS_YOUTUBE_URL);
  if (parsed.data.NODE_ENV === "production" && !appUrl.startsWith("https://")) {
    throw new Error("APP_URL must use https:// in production.");
  }

  const smtpValues = [
    parsed.data.SMTP_HOST,
    parsed.data.SMTP_USER,
    parsed.data.SMTP_PASS,
    parsed.data.CONTACT_FROM_EMAIL
  ];
  const smtpIsPartiallyConfigured = smtpValues.some(Boolean) && !smtpValues.every(Boolean);
  if (smtpIsPartiallyConfigured) {
    throw new Error(
      "Configure all SMTP_* values plus CONTACT_FROM_EMAIL, or omit all of them to keep contact delivery disabled."
    );
  }

  const orderValues = [parsed.data.ORDER_DATABASE_URL, parsed.data.FULFILLMENT_ADMIN_PASSWORD];
  if (orderValues.some(Boolean) && !orderValues.every(Boolean)) {
    throw new Error(
      "Configure both ORDER_DATABASE_URL and FULFILLMENT_ADMIN_PASSWORD, or omit both to keep fulfillment disabled."
    );
  }
  if (parsed.data.FULFILLMENT_ADMIN_PASSWORD && parsed.data.FULFILLMENT_ADMIN_PASSWORD.length < 24) {
    throw new Error("FULFILLMENT_ADMIN_PASSWORD must be at least 24 characters.");
  }

  const googleSheetsValues = [
    parsed.data.GOOGLE_SHEETS_SPREADSHEET_ID,
    parsed.data.GOOGLE_SERVICE_ACCOUNT_EMAIL,
    parsed.data.GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY
  ];
  if (googleSheetsValues.some(Boolean) && !googleSheetsValues.every(Boolean)) {
    throw new Error(
      "Configure GOOGLE_SHEETS_SPREADSHEET_ID, GOOGLE_SERVICE_ACCOUNT_EMAIL, and GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY together, or omit all of them to disable Google Sheets fulfillment."
    );
  }

  const reviewMediaValues = [
    parsed.data.REVIEW_MEDIA_BUCKET,
    parsed.data.REVIEW_MEDIA_ENDPOINT,
    parsed.data.REVIEW_MEDIA_ACCESS_KEY_ID,
    parsed.data.REVIEW_MEDIA_SECRET_ACCESS_KEY,
    parsed.data.REVIEW_MEDIA_PUBLIC_BASE_URL
  ];
  if (reviewMediaValues.some(Boolean) && !reviewMediaValues.every(Boolean)) {
    throw new Error("Configure every REVIEW_MEDIA_* value together, or omit all of them for text-only reviews.");
  }
  if (reviewMediaValues.some(Boolean) && !parsed.data.DATABASE_URL) {
    throw new Error("DATABASE_URL is required when REVIEW_MEDIA_* values are configured.");
  }

  return {
    nodeEnv: parsed.data.NODE_ENV,
    port: parsed.data.PORT,
    appUrl,
    stripeSecretKey: parsed.data.STRIPE_SECRET_KEY,
    stripeWebhookSecret: parsed.data.STRIPE_WEBHOOK_SECRET,
    shippingCountries,
    automaticTax: parsed.data.STRIPE_AUTOMATIC_TAX.toLowerCase() === "true",
    appStoreUrl: parsed.data.APP_STORE_URL,
    playStoreUrl: parsed.data.PLAY_STORE_URL,
    howItWorksVideoEmbedUrl,
    smtp: smtpValues.every(Boolean)
      ? {
          host: parsed.data.SMTP_HOST!,
          port: parsed.data.SMTP_PORT,
          secure: parsed.data.SMTP_SECURE.toLowerCase() === "true",
          user: parsed.data.SMTP_USER!,
          pass: parsed.data.SMTP_PASS!,
          from: parsed.data.CONTACT_FROM_EMAIL!
        }
      : undefined,
    contactToEmail: parsed.data.CONTACT_TO_EMAIL,
    orders: orderValues.every(Boolean)
      ? {
          databaseUrl: parsed.data.ORDER_DATABASE_URL!,
          adminPassword: parsed.data.FULFILLMENT_ADMIN_PASSWORD!
      }
      : undefined,
    googleSheets: googleSheetsValues.every(Boolean)
      ? {
          spreadsheetId: parsed.data.GOOGLE_SHEETS_SPREADSHEET_ID!,
          serviceAccountEmail: parsed.data.GOOGLE_SERVICE_ACCOUNT_EMAIL!,
          // Render environment variables keep literal "\\n" characters; Node needs real line breaks.
          serviceAccountPrivateKey: parsed.data.GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY!.replace(/\\n/g, "\n"),
          tabName: parsed.data.GOOGLE_SHEETS_TAB_NAME
        }
      : undefined,
    reviews: parsed.data.DATABASE_URL
      ? {
          databaseUrl: parsed.data.DATABASE_URL!,
          media: reviewMediaValues.every(Boolean)
            ? {
            bucket: parsed.data.REVIEW_MEDIA_BUCKET!,
            region: parsed.data.REVIEW_MEDIA_REGION,
            endpoint: parsed.data.REVIEW_MEDIA_ENDPOINT!,
            accessKeyId: parsed.data.REVIEW_MEDIA_ACCESS_KEY_ID!,
            secretAccessKey: parsed.data.REVIEW_MEDIA_SECRET_ACCESS_KEY!,
            publicBaseUrl: parsed.data.REVIEW_MEDIA_PUBLIC_BASE_URL!.replace(/\/$/, "")
            }
            : undefined
        }
      : undefined
  };
}
