import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();

if (!config.stripeSecretKey) {
  console.warn("STRIPE_SECRET_KEY is missing; storefront browsing works but checkout is disabled.");
}
if (!config.stripeWebhookSecret) {
  console.warn("STRIPE_WEBHOOK_SECRET is missing; signed payment confirmation is disabled.");
}

const app = createApp({ config });
const server = app.listen(config.port, "0.0.0.0", () => {
  console.info(`ClipIt storefront listening on ${config.appUrl}`);
});

function shutdown(signal: string) {
  console.info(`${signal} received; stopping new connections.`);
  server.close((error) => {
    if (error) {
      console.error("Graceful shutdown failed.", error);
      process.exit(1);
    }
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
