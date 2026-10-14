export type Product = {
  id: string;
  slug: string;
  name: string;
  shortDescription: string;
  description: string;
  priceCents: number;
  currency: "usd";
  image: string;
  imageAlt: string;
  images: ProductImage[];
  badge?: string;
  features: string[];
  active: boolean;
  requiresShipping: boolean;
};

export type ProductImage = {
  src: string;
  alt: string;
};

export type CustomerQuote = {
  quote: string;
  name: string;
  context: string;
};

export type CartItemInput = {
  productId: string;
  quantity: number;
};

export type ValidatedCartLine = {
  product: Product;
  quantity: number;
};
