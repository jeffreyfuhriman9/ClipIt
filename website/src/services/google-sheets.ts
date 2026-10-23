import { createSign } from "node:crypto";
import type { AppConfig } from "../config.js";
import type { OrderLine } from "./orders.js";

export type SheetOrder = {
  sessionId: string;
  customerName: string | null;
  customerEmail: string;
  // Stripe may return null for any individual address field, so preserve that
  // information instead of making the webhook fail on a partially filled address.
  address: { line1: string | null; line2: string | null; city: string | null; state: string | null; postalCode: string | null; country: string | null } | null;
  amountTotal: number | null;
  currency: string | null;
  lines: OrderLine[];
};

type GoogleToken = { accessToken: string; expiresAt: number };
type SpreadsheetMetadata = { sheets?: Array<{ properties?: { sheetId?: number; title?: string } }> };
type ValuesResponse = { values?: string[][] };
type AppendResponse = { updates?: { updatedRange?: string } };

const headers = [
  "Stripe checkout session", "Paid at (Mountain Time)", "Customer name", "Customer email", "Shipping address", "Items", "Quantity", "Total",
  "Payment confirmed", "Packed", "Label printed", "Shipped", "Tracking number", "Customer notified", "Notes"
];

function base64Url(value: string) {
  return Buffer.from(value).toString("base64url");
}

function formatAddress(order: SheetOrder) {
  if (!order.address) return "No shipping address collected";
  return [
    order.address.line1,
    order.address.line2,
    `${order.address.city}${order.address.state ? `, ${order.address.state}` : ""} ${order.address.postalCode}`,
    order.address.country
  ].filter(Boolean).join(", ");
}

function formatTotal(amount: number | null, currency: string | null) {
  if (amount === null || !currency) return "";
  return new Intl.NumberFormat("en-US", { style: "currency", currency: currency.toUpperCase() }).format(amount / 100);
}

function formatPaidAt(date: Date) {
  // America/Denver automatically displays MDT or MST as daylight saving changes.
  // Store a readable local time so fulfillment does not require manual UTC conversion.
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Denver",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    timeZoneName: "short"
  }).format(date);
}

/**
 * Writes only Stripe-verified purchases to a private Sheet. It checks the Stripe
 * Checkout session ID first, so normal webhook retries do not create duplicate rows.
 */
export class GoogleSheetsOrderStore {
  private token?: GoogleToken;
  private layoutReady?: Promise<number>;

  constructor(private readonly settings: NonNullable<AppConfig["googleSheets"]>) {}

  private async accessToken() {
    if (this.token && this.token.expiresAt > Date.now() + 60_000) return this.token.accessToken;

    const now = Math.floor(Date.now() / 1_000);
    const unsigned = `${base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${base64Url(JSON.stringify({
      iss: this.settings.serviceAccountEmail,
      scope: "https://www.googleapis.com/auth/spreadsheets",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3_600
    }))}`;
    const signer = createSign("RSA-SHA256");
    signer.update(unsigned);
    signer.end();
    const assertion = `${unsigned}.${signer.sign(this.settings.serviceAccountPrivateKey, "base64url")}`;
    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion })
    });
    if (!response.ok) throw new Error(`Google Sheets authentication failed (${response.status}).`);
    const body = await response.json() as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error("Google Sheets authentication did not return an access token.");
    this.token = { accessToken: body.access_token, expiresAt: Date.now() + (body.expires_in ?? 3_600) * 1_000 };
    return this.token.accessToken;
  }

  private spreadsheetUrl(path = "") {
    return `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(this.settings.spreadsheetId)}${path}`;
  }

  private async request<T>(url: string, init: RequestInit = {}) {
    const response = await fetch(url, {
      ...init,
      headers: { Authorization: `Bearer ${await this.accessToken()}`, "Content-Type": "application/json", ...init.headers }
    });
    if (!response.ok) throw new Error(`Google Sheets request failed (${response.status}).`);
    return response.status === 204 ? undefined as T : await response.json() as T;
  }

  private range(value: string) {
    return encodeURIComponent(`'${this.settings.tabName.replace(/'/g, "''")}'!${value}`);
  }

  private async ensureLayout() {
    const metadata = await this.request<SpreadsheetMetadata>(this.spreadsheetUrl("?fields=sheets.properties"));
    let sheet = metadata.sheets?.find((candidate) => candidate.properties?.title === this.settings.tabName)?.properties;
    if (!sheet) {
      const created = await this.request<{ replies?: Array<{ addSheet?: { properties?: { sheetId?: number; title?: string } } }> }>(
        this.spreadsheetUrl(":batchUpdate"),
        { method: "POST", body: JSON.stringify({ requests: [{ addSheet: { properties: { title: this.settings.tabName } } }] }) }
      );
      sheet = created.replies?.[0]?.addSheet?.properties;
    }
    if (typeof sheet?.sheetId !== "number") throw new Error("Google Sheets could not find the configured worksheet.");

    const existing = await this.request<ValuesResponse>(this.spreadsheetUrl(`/values/${this.range("A1:O1")}`));
    if (!existing.values?.[0]?.length) {
      await this.request(this.spreadsheetUrl(`/values/${this.range("A1:O1")}?valueInputOption=RAW`), {
        method: "PUT", body: JSON.stringify({ values: [headers] })
      });
    } else if (existing.values[0][1] === "Paid at (UTC)") {
      // Update the header of the existing ClipIt fulfillment sheet once, while
      // leaving any user-added columns or labels untouched.
      await this.request(this.spreadsheetUrl(`/values/${this.range("B1")}?valueInputOption=RAW`), {
        method: "PUT", body: JSON.stringify({ values: [[headers[1]]] })
      });
    }

    return sheet.sheetId;
  }

  private async addCheckboxes(sheetId: number, row: number) {
    // Apply checkbox formatting only to the newly added order. Formatting a huge
    // future range makes Sheets consider those blank rows part of the table.
    const checkboxColumns = [8, 9, 10, 11, 13];
    await this.request(this.spreadsheetUrl(":batchUpdate"), {
      method: "POST",
      body: JSON.stringify({
        requests: checkboxColumns.map((startColumnIndex) => ({
          setDataValidation: {
            range: { sheetId, startRowIndex: row - 1, endRowIndex: row, startColumnIndex, endColumnIndex: startColumnIndex + 1 },
            rule: { condition: { type: "BOOLEAN" }, showCustomUi: true, strict: true }
          }
        }))
      })
    });
  }

  async recordPaidOrder(order: SheetOrder) {
    this.layoutReady ??= this.ensureLayout();
    const sheetId = await this.layoutReady;

    const existing = await this.request<ValuesResponse>(this.spreadsheetUrl(`/values/${this.range("A2:A")}`));
    if (existing.values?.some(([sessionId]) => sessionId === order.sessionId)) return false;

    const items = order.lines.map((line) => `${line.productName} × ${line.quantity}`).join("; ");
    const quantity = order.lines.reduce((sum, line) => sum + line.quantity, 0);
    const appended = await this.request<AppendResponse>(this.spreadsheetUrl(`/values/${this.range("A:O")}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS`), {
      method: "POST",
      body: JSON.stringify({ values: [[
        order.sessionId, formatPaidAt(new Date()), order.customerName ?? "", order.customerEmail, formatAddress(order), items, quantity,
        formatTotal(order.amountTotal, order.currency), true, false, false, false, "", false, ""
      ]] })
    });
    const row = appended.updates?.updatedRange?.match(/![A-Z]+(\d+):/)?.[1];
    if (!row) throw new Error("Google Sheets did not return the appended order row.");
    await this.addCheckboxes(sheetId, Number(row));
    return true;
  }
}

export function createGoogleSheetsOrderStore(config: AppConfig) {
  return config.googleSheets ? new GoogleSheetsOrderStore(config.googleSheets) : undefined;
}
