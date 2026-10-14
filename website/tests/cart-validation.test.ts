import { describe, expect, it } from "vitest";
import { CartValidationError, validateCart } from "../src/services/cart.js";
import { findProductById } from "../src/data/products.js";

describe("validateCart", () => {
  it("looks up authoritative server catalog data", () => {
    const [line] = validateCart({
      items: [{ productId: "clipit-button-placeholder", quantity: 2, priceCents: 1 }]
    });
    expect(line?.product.priceCents).toBe(findProductById("clipit-button-placeholder")?.priceCents);
    expect(line?.quantity).toBe(2);
  });

  it("rejects unknown products and invalid quantities", () => {
    expect(() => validateCart({ items: [{ productId: "unknown", quantity: 1 }] })).toThrow(
      CartValidationError
    );
    expect(() =>
      validateCart({ items: [{ productId: "clipit-button-placeholder", quantity: 0 }] })
    ).toThrow(CartValidationError);
  });

  it("combines duplicates without allowing the quantity limit to be bypassed", () => {
    expect(() =>
      validateCart({
        items: [
          { productId: "clipit-button-placeholder", quantity: 7 },
          { productId: "clipit-button-placeholder", quantity: 6 }
        ]
      })
    ).toThrow("Quantity cannot exceed 10");
  });
});
