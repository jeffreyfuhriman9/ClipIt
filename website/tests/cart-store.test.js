// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { CART_STORAGE_KEY, createCartStore } from "../public/cart-store.js";

describe("browser cart persistence", () => {
  beforeEach(() => localStorage.clear());

  it("persists add, update, and remove operations", () => {
    const cart = createCartStore(localStorage);
    cart.add("clipit-button-placeholder", 2);
    expect(createCartStore(localStorage).getItems()).toEqual([
      { productId: "clipit-button-placeholder", quantity: 2 }
    ]);

    cart.update("clipit-button-placeholder", 3);
    expect(JSON.parse(localStorage.getItem(CART_STORAGE_KEY))).toEqual([
      { productId: "clipit-button-placeholder", quantity: 3 }
    ]);

    cart.remove("clipit-button-placeholder");
    expect(cart.getItems()).toEqual([]);
  });

  it("recovers safely from malformed saved data", () => {
    localStorage.setItem(CART_STORAGE_KEY, "not-json");
    expect(createCartStore(localStorage).getItems()).toEqual([]);
  });

  it("caps quantities at the server-supported maximum", () => {
    const cart = createCartStore(localStorage);
    cart.add("clipit-button-placeholder", 9);
    cart.add("clipit-button-placeholder", 5);
    expect(cart.getItems()[0].quantity).toBe(10);
  });
});
