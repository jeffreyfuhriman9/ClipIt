export const CART_STORAGE_KEY = "clipit-cart-v1";
export const MAX_QUANTITY = 10;

function normalizeItems(value) {
  if (!Array.isArray(value)) return [];
  const combined = new Map();

  for (const item of value) {
    if (!item || typeof item.productId !== "string") continue;
    const quantity = Number(item.quantity);
    if (!Number.isInteger(quantity) || quantity < 1) continue;
    combined.set(item.productId, Math.min(MAX_QUANTITY, (combined.get(item.productId) ?? 0) + quantity));
  }

  return [...combined.entries()].map(([productId, quantity]) => ({ productId, quantity }));
}

export function createCartStore(storage = globalThis.localStorage) {
  function read() {
    try {
      const raw = storage.getItem(CART_STORAGE_KEY);
      return raw ? normalizeItems(JSON.parse(raw)) : [];
    } catch {
      // Storage can fail in privacy modes, or old data can become malformed.
      return [];
    }
  }

  function write(items) {
    const normalized = normalizeItems(items);
    try {
      storage.setItem(CART_STORAGE_KEY, JSON.stringify(normalized));
    } catch {
      throw new Error("Your browser could not save the cart. Check privacy or storage settings.");
    }
    globalThis.dispatchEvent?.(new CustomEvent("clipit:cart-changed", { detail: normalized }));
    return normalized;
  }

  return {
    getItems: read,
    add(productId, quantity = 1) {
      const parsedQuantity = Number(quantity);
      if (!productId || !Number.isInteger(parsedQuantity) || parsedQuantity < 1) {
        throw new Error("Choose a valid quantity before adding this product.");
      }
      const items = read();
      const existing = items.find((item) => item.productId === productId);
      if (existing) existing.quantity = Math.min(MAX_QUANTITY, existing.quantity + parsedQuantity);
      else items.push({ productId, quantity: Math.min(MAX_QUANTITY, parsedQuantity) });
      return write(items);
    },
    update(productId, quantity) {
      const parsedQuantity = Number(quantity);
      if (!Number.isInteger(parsedQuantity)) throw new Error("Quantity must be a whole number.");
      if (parsedQuantity < 1) return this.remove(productId);
      const items = read();
      const existing = items.find((item) => item.productId === productId);
      if (!existing) throw new Error("That product is no longer in your cart.");
      existing.quantity = Math.min(MAX_QUANTITY, parsedQuantity);
      return write(items);
    },
    remove(productId) {
      return write(read().filter((item) => item.productId !== productId));
    },
    clear() {
      return write([]);
    },
    count() {
      return read().reduce((total, item) => total + item.quantity, 0);
    }
  };
}
