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
  reviews?: {
    databaseUrl: string;
    media: {
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

  const reviewValues = [
    parsed.data.DATABASE_URL,
    parsed.data.REVIEW_MEDIA_BUCKET,
    parsed.data.REVIEW_MEDIA_ENDPOINT,
    parsed.data.REVIEW_MEDIA_ACCESS_KEY_ID,
    parsed.data.REVIEW_MEDIA_SECRET_ACCESS_KEY,
    parsed.data.REVIEW_MEDIA_PUBLIC_BASE_URL
  ];
  if (reviewValues.some(Boolean) && !reviewValues.every(Boolean)) {
    throw new Error("Configure all DATABASE_URL and REVIEW_MEDIA_* values, or omit all of them to disable reviews.");
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
    reviews: reviewValues.every(Boolean)
      ? {
          databaseUrl: parsed.data.DATABASE_URL!,
          media: {
            bucket: parsed.data.REVIEW_MEDIA_BUCKET!,
            region: parsed.data.REVIEW_MEDIA_REGION,
            endpoint: parsed.data.REVIEW_MEDIA_ENDPOINT!,
            accessKeyId: parsed.data.REVIEW_MEDIA_ACCESS_KEY_ID!,
            secretAccessKey: parsed.data.REVIEW_MEDIA_SECRET_ACCESS_KEY!,
            publicBaseUrl: parsed.data.REVIEW_MEDIA_PUBLIC_BASE_URL!.replace(/\/$/, "")
          }
        }
      : undefined
  };
}
