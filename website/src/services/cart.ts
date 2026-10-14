import { z } from "zod";
import { findProductById } from "../data/products.js";
import type { CartItemInput, ValidatedCartLine } from "../types/store.js";

export const MAX_QUANTITY_PER_PRODUCT = 10;
export const MAX_CART_ITEMS = 50;

const cartSchema = z.object({
  items: z
    .array(
      z.object({
        productId: z.string().min(1).max(100),
        quantity: z.number().int().min(1).max(MAX_QUANTITY_PER_PRODUCT)
      })
    )
    .min(1, "Your cart is empty.")
    .max(MAX_CART_ITEMS, "Your cart contains too many line items.")
});

export class CartValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CartValidationError";
  }
}

export function validateCart(input: unknown): ValidatedCartLine[] {
  const result = cartSchema.safeParse(input);
  if (!result.success) {
    const message = result.error.issues[0]?.message ?? "The cart is invalid.";
    throw new CartValidationError(message);
  }

  const quantities = new Map<string, number>();
  for (const item of result.data.items as CartItemInput[]) {
    quantities.set(item.productId, (quantities.get(item.productId) ?? 0) + item.quantity);
  }

  return [...quantities.entries()].map(([productId, quantity]) => {
    if (quantity > MAX_QUANTITY_PER_PRODUCT) {
      throw new CartValidationError(
        `Quantity cannot exceed ${MAX_QUANTITY_PER_PRODUCT} for a single product.`
      );
    }
    const product = findProductById(productId);
    if (!product) {
      throw new CartValidationError("One or more products are unavailable. Refresh your cart.");
    }
    return { product, quantity };
  });
}
