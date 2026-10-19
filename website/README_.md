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
4. Use the Contact page to send a message. Paid Stripe orders can be tracked in the optional Google Sheets fulfillment sheet.

## Development Environment

To recreate the development environment, you need the following software and/or libraries with the specified versions:

* Node.js 22 or newer
* pnpm
* TypeScript, Express, EJS, Stripe, Zod, and Nodemailer
* VS Code is recommended, although the project can also be opened in Xcode as a text project.

## Google Sheets Fulfillment Setup

This is optional and does not require a Render database. After a Stripe-verified successful payment, the site adds one row to a private Google Sheet. The Sheet automatically receives columns for the customer, delivery address, items, total, tracking number, notes, and checkboxes for payment confirmed, packed, label printed, shipped, and customer notified.

1. While signed in as `clipitbutton@gmail.com`, create a Google Sheet for fulfillment.
2. In Google Cloud Console, create a project, enable the **Google Sheets API**, create a service account, then create and download a JSON key for that service account.
3. Copy the JSON key's `client_email` and share the Sheet with that address as an **Editor**. Do not make the Sheet public.
4. Copy the Sheet ID from its URL: it is the text between `/d/` and `/edit`.
5. In Render, add `GOOGLE_SHEETS_SPREADSHEET_ID`, `GOOGLE_SERVICE_ACCOUNT_EMAIL`, and `GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY` from the JSON key. Add `GOOGLE_SHEETS_TAB_NAME=Orders` unless you want a different tab name.
6. Deploy, then place a Stripe test-mode order. A successful webhook should add one row automatically.

Never commit the downloaded Google key file or paste it into GitHub. The app accepts either actual line breaks or literal `\n` characters in the private-key environment variable.

## Useful Websites to Learn More

I found these websites useful in developing this software:

* [Node.js Documentation](https://nodejs.org/docs/latest/api/)
* [Express Documentation](https://expressjs.com/)
* [Stripe Checkout Documentation](https://docs.stripe.com/checkout)
* [Render Documentation](https://render.com/docs)
* [Google Sheets API Documentation](https://developers.google.com/sheets/api)

## Future Work

The following items I plan to fix, improve, and/or add to this project in the future:

* [ ] Replace the placeholder product descriptions, images, prices, and app links.
* [ ] Connect the Google Sheets fulfillment sheet before accepting live orders.
* [ ] Connect shipping labels and automatic tracking updates.
* [ ] Add the final YouTube video, legal pages, shipping policy, and return policy.
