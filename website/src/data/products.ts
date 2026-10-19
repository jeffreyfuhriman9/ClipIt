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
    shortDescription: "Your instant highlight creator made simply through a button press.",
    description:
      "The ultimate sports enthusiast accessory - The ClipIt Button. Allows parents, athletes, and coaches to keep their head in the game while also gathering their favorite highlights!",
    priceCents: 4499,
    currency: "usd",
    image: "/images/ClipIt_Product_2.png",
    imageAlt: "ClipIt Button Product Photo",
    // Add approved product photos here after placing them in public/images/.
    // The product page automatically turns two or more entries into a swipeable gallery.
    images: [{ src: "/images/ClipIt_Product_2.png", alt: "ClipIt Button Product main photo" },
      { src: "/images/ClipIt_Product_1.png", alt: "ClipIt Button Product photo 1" },
      { src: "/images/ClipIt_Product_3.png", alt: "ClipIt Button Product photo 3" },
      { src: "/images/ClipIt_Product_4.png", alt: "ClipIt Button Product photo 4" },
      { src: "/images/ClipIt_Product_5.png", alt: "ClipIt Button Product photo 5" },
      { src: "/images/ClipIt_Product_6.png", alt: "ClipIt Button Product photo 6" }
    ],
    badge: "Placeholder product",
    features: [
      "Pair The ClipIt Button with the ClipIt companion app available on iOS and Android and start capturing your favorite clips.",
      "Up to 60+ ft of Bluetooth range",
      "USB-C charging"
    ],
    active: true,
    requiresShipping: true
  },
  {
    id: "clipit-bundle-placeholder",
    slug: "clipit-bundle",
    name: "ClipIt Bundle — Placeholder Product",
    shortDescription: "PLACEHOLDER: Add an approved bundle summary here.",
    description:
      "PLACEHOLDER: Explain the bundle contents and value after the real offer is finalized.",
    priceCents: 7999,
    currency: "usd",
    image: "/images/bundle.png",
    imageAlt: "Placeholder artwork for a future ClipIt bundle",
    images: [{ src: "/images/bundle.png", alt: "Placeholder artwork for a future ClipIt bundle" }],
    badge: "Example future listing",
    features: [
      "PLACEHOLDER: Bundle item one",
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
