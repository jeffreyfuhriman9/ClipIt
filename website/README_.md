# ClipIt Storefront

This is the ClipIt Button online storefront. Customers can view products, add items to a cart, submit contact messages, and pay through Stripe Checkout. I also added product reviews, a companion-app section, responsive design, and a private fulfillment dashboard for future orders.

## Instructions for Build and Use

Steps to build and/or run the software:

1. Install Node.js 22 or newer and pnpm.
2. In this folder, run `pnpm install`.
3. Copy `.env.example` to `.env` and add the Stripe test values.
4. Run `pnpm dev` and open `http://localhost:3000`.

Instructions for using the software:

1. Browse the products and add an item to the cart.
2. Update quantities or remove items from the cart.
3. Continue to Stripe Checkout and use Stripe's test card `4242 4242 4242 4242` while in test mode.
4. Use the Contact page to send a message, or use the private fulfillment page after the database is configured.

## Development Environment

To recreate the development environment, you need the following software and/or libraries with the specified versions:

* Node.js 22 or newer
* pnpm
* TypeScript, Express, EJS, Stripe, Zod, and Nodemailer
* VS Code is recommended, although the project can also be opened in Xcode as a text project.

## Useful Websites to Learn More

I found these websites useful in developing this software:

* [Node.js Documentation](https://nodejs.org/docs/latest/api/)
* [Express Documentation](https://expressjs.com/)
* [Stripe Checkout Documentation](https://docs.stripe.com/checkout)
* [Render Documentation](https://render.com/docs)

## Future Work

The following items I plan to fix, improve, and/or add to this project in the future:

* [ ] Replace the placeholder product descriptions, images, prices, and app links.
* [ ] Finish configuring the production database and fulfillment dashboard.
* [ ] Connect shipping labels and automatic tracking updates.
* [ ] Add the final YouTube video, legal pages, shipping policy, and return policy.
