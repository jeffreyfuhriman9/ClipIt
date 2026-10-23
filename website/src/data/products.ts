import type { Product } from "../types/store.js";

/**
 * PLACEHOLDER CATALOG
 * Replace product copy, pricing, images, and features here. Checkout always reads
 * these server-side values, so a browser cannot submit a different price.
 */
export const products: Product[] = [
  {
    id: "clipit-button-placeholder",
    slug: "clipit-button",
    name: "The ClipIt Button",
    shortDescription: "Your instant sports highlight creator made simply through a button press.",
    description:
      "The ultimate sports enthusiast accessory - The ClipIt Button - allowing parents, athletes, and coaches to keep their head in the game while also gathering their favorite highlights!",
    priceCents: 3999,
    currency: "usd",
    image: "/images/button1pf.png",
    imageAlt: "ClipIt Button front and side view",
    // The product page automatically turns two or more entries into a swipeable gallery.
    images: [
      { src: "/images/button1pf.png", alt: "ClipIt Button front and side view" },
      { src: "/images/button4pf.png", alt: "ClipIt Button front view" },
      { src: "/images/button3pf.png", alt: "ClipIt Button angled view" },
      { src: "/images/button2pf.png", alt: "ClipIt Button back view" }
    ],
    features: [
      "Pair The ClipIt Button with the ClipIt companion app available on iOS and Android.",
      "Connects to your mobile device via Bluetooth",
      "No range limits - take your button anywhere while enjoying the game!",
      "Rechargeable battery through USB-C (USB-C cord not included)"
    ],
    active: true,
    requiresShipping: true
  },
  {
    id: "clipit-bundle-placeholder",
    slug: "clipit-bundle",
    name: "The ClipIt Starter Bundle",
    shortDescription: "Bundle and get the full setup including the ClipIt Button and Tripod.",
    description:
      "Stop watching the game through your phone. Set up the tripod, hit record, and simply just hit that ClipIt Button included in this bundle!",
    priceCents: 7999,
    currency: "usd",
    image: "/images/bundle.png",
    imageAlt: "ClipIt Button next to an open tripod",
    images: [
      { src: "/images/bundle.png", alt: "ClipIt Button next to an open tripod" },
      { src: "/images/bundle-accessories.png", alt: "Phone holder, folded tripod, and carry bag" }
    ],
    features: [
      "Included in bundle: The ClipIt Button and Tripod",
      "PLACEHOLDER: Bundle item two",
      "PLACEHOLDER: Bundle compatibility note"
    ],
    active: true,
    requiresShipping: true
  }
];

export function findProductBySlug(slug: string): Product | undefined {
  return products.find((product) => product.active && product.slug === slug);
}

export function findProductById(id: string): Product | undefined {
  return products.find((product) => product.active && product.id === id);
}
