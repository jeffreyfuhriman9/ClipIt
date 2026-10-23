import { createCartStore } from "/cart-store.js";

const cart = createCartStore();
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

function showMessage(message, tone = "success") {
  const element = document.querySelector("#site-message");
  if (!element) return;
  element.textContent = message;
  element.dataset.tone = tone;
  element.hidden = false;
  window.clearTimeout(showMessage.timeout);
  showMessage.timeout = window.setTimeout(() => {
    element.hidden = true;
  }, 4200);
}

function updateCartCount() {
  const count = cart.count();
  document.querySelectorAll("[data-cart-count]").forEach((element) => {
    element.textContent = String(count);
    element.setAttribute("aria-label", `${count} ${count === 1 ? "item" : "items"}`);
  });
}

function addToCart(productId, quantity = 1) {
  try {
    cart.add(productId, quantity);
    updateCartCount();
    showMessage("Added to your cart.");
  } catch (error) {
    showMessage(error instanceof Error ? error.message : "Could not update your cart.", "error");
  }
}

document.querySelectorAll("[data-add-to-cart]").forEach((button) => {
  button.addEventListener("click", () => addToCart(button.dataset.addToCart));
});

document.querySelectorAll("[data-add-form]").forEach((form) => {
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const data = new FormData(form);
    addToCart(form.dataset.addForm, Number(data.get("quantity")));
  });
});

function setupCartPage() {
  const page = document.querySelector("[data-cart-page]");
  if (!page) return;

  const catalogElement = document.querySelector("#catalog-data");
  const linesElement = document.querySelector("#cart-lines");
  const template = document.querySelector("#cart-line-template");
  const emptyState = document.querySelector("#empty-cart");
  const subtotalElement = document.querySelector("#cart-subtotal");
  const checkoutButton = document.querySelector("#checkout-button");
  const checkoutError = document.querySelector("#checkout-error");

  if (!catalogElement || !linesElement || !template || !emptyState || !subtotalElement || !checkoutButton) return;
  const catalog = JSON.parse(catalogElement.textContent || "[]");

  function render() {
    const items = cart.getItems();
    linesElement.replaceChildren();
    let subtotal = 0;

    for (const item of items) {
      const product = catalog.find((entry) => entry.id === item.productId);
      if (!product) continue;
      subtotal += product.priceCents * item.quantity;
      const line = template.content.cloneNode(true);
      const image = line.querySelector("[data-line-image]");
      image.src = product.image;
      image.alt = product.imageAlt;
      line.querySelector("[data-line-name]").textContent = product.name;
      line.querySelector("[data-line-price]").textContent = `${money.format(product.priceCents / 100)} each`;
      line.querySelector("[data-line-total]").textContent = money.format((product.priceCents * item.quantity) / 100);
      const quantity = line.querySelector("[data-line-quantity]");
      quantity.value = String(item.quantity);
      quantity.addEventListener("change", () => {
        try {
          cart.update(item.productId, Number(quantity.value));
          render();
        } catch (error) {
          showMessage(error instanceof Error ? error.message : "Could not change quantity.", "error");
        }
      });
      line.querySelector("[data-line-remove]").addEventListener("click", () => {
        cart.remove(item.productId);
        render();
        showMessage("Removed from your cart.");
      });
      linesElement.append(line);
    }

    const isEmpty = subtotal === 0;
    page.hidden = isEmpty;
    emptyState.hidden = !isEmpty;
    subtotalElement.textContent = money.format(subtotal / 100);
    checkoutButton.disabled = isEmpty;
    updateCartCount();
  }

  checkoutButton.addEventListener("click", async () => {
    checkoutError.hidden = true;
    checkoutButton.disabled = true;
    checkoutButton.textContent = "Opening secure checkout…";
    try {
      const response = await fetch("/api/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ items: cart.getItems() })
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.url) {
        throw new Error(result.error || "Checkout could not be started. Please try again.");
      }
      window.location.assign(result.url);
    } catch (error) {
      checkoutError.textContent = error instanceof Error ? error.message : "A network error occurred.";
      checkoutError.hidden = false;
      checkoutButton.disabled = false;
      checkoutButton.textContent = "Continue to secure checkout";
    }
  });

  render();
}

function clearPaidCart() {
  const status = document.querySelector("[data-checkout-status]")?.dataset.checkoutStatus;
  if (status === "paid") cart.clear();
}

function setupContactForm() {
  const form = document.querySelector("[data-contact-form]");
  if (!form) return;
  const button = form.querySelector('button[type="submit"]');
  const error = form.querySelector("[data-contact-error]");
  const success = form.querySelector("[data-contact-success]");
  const attachmentInput = form.querySelector("[data-contact-attachments]");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    error.hidden = true;
    success.hidden = true;
    button.disabled = true;
    button.textContent = "Sending…";
    if (!form.reportValidity()) return;
    const attachments = Array.from(attachmentInput?.files || []);
    const invalidAttachment = attachments.find((file) =>
      !/^(image\\/(jpeg|png|webp)|application\\/pdf)$/.test(file.type) || file.size > 5 * 1024 * 1024
    );
    if (attachments.length > 3 || invalidAttachment) {
      error.textContent = "Attach up to three JPG, PNG, WebP, or PDF files. Each file can be up to 5 MB.";
      error.hidden = false;
      return;
    }
    const data = new FormData(form);

    try {
      const response = await fetch("/api/contact", {
        method: "POST",
        headers: { Accept: "application/json" },
        body: data
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error || "We could not send your message. Please try again.");
      form.reset();
      success.hidden = false;
    } catch (requestError) {
      error.textContent = requestError instanceof Error ? requestError.message : "A network error occurred.";
      error.hidden = false;
    } finally {
      button.disabled = false;
      button.textContent = "Send message";
    }
  });
}

function setupReviewForm() {
  const form = document.querySelector("[data-review-form]");
  if (!form) return;
  const fileInput = form.querySelector("[data-review-media]");
  const descriptions = form.querySelector("[data-media-descriptions]");
  const button = form.querySelector('button[type="submit"]');
  const error = form.querySelector("[data-review-error]");
  const success = form.querySelector("[data-review-success]");

  fileInput?.addEventListener("change", () => {
    descriptions?.replaceChildren();
    const files = Array.from(fileInput.files || []);
    if (files.length > 5) {
      error.textContent = "You can upload up to five photos or videos.";
      error.hidden = false;
      return;
    }
    error.hidden = true;
    files.forEach((file, index) => {
      const label = document.createElement("label");
      label.className = "media-alt-label";
      label.textContent = `Description for ${file.name}`;
      const input = document.createElement("input");
      input.name = `mediaAlt${index}`;
      input.maxLength = 200;
      input.required = true;
      input.placeholder = "Describe what is shown or heard";
      label.append(input);
      descriptions?.append(label);
    });
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    error.hidden = true;
    success.hidden = true;
    if (!form.reportValidity()) return;
    const files = Array.from(fileInput?.files || []);
    const invalidFile = files.find((file) => {
      const image = /^(image\/jpeg|image\/png|image\/webp)$/.test(file.type);
      const video = /^(video\/mp4|video\/webm)$/.test(file.type);
      return (!image && !video) || (image && file.size > 5 * 1024 * 1024) || (video && file.size > 25 * 1024 * 1024);
    });
    if (files.length > 5 || invalidFile) {
      error.textContent = "Use up to five JPG, PNG, WebP, MP4, or WebM files within the posted size limits.";
      error.hidden = false;
      return;
    }
    button.disabled = true;
    button.textContent = "Publishing…";
    try {
      const response = await fetch("/api/reviews", {
        method: "POST",
        headers: { Accept: "application/json" },
        body: new FormData(form)
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error || "We could not publish your review. Please try again.");
      form.reset();
      descriptions?.replaceChildren();
      window.location.assign("/reviews/thanks");
    } catch (requestError) {
      error.textContent = requestError instanceof Error ? requestError.message : "A network error occurred.";
      error.hidden = false;
      button.disabled = false;
      button.textContent = "Publish review";
    }
  });
}

function setupProductGallery() {
  const gallery = document.querySelector("[data-product-gallery]");
  if (!gallery) return;
  const mainImage = gallery.querySelector("[data-gallery-main]");
  const previous = gallery.querySelector("[data-gallery-previous]");
  const next = gallery.querySelector("[data-gallery-next]");
  const thumbnails = [...gallery.querySelectorAll("[data-gallery-thumbnail]")];
  let images;
  try {
    images = JSON.parse(gallery.dataset.galleryImages || "[]");
  } catch {
    return;
  }
  if (!mainImage || images.length < 2) return;
  let currentIndex = 0;
  let pointerStartX;

  function show(index) {
    currentIndex = (index + images.length) % images.length;
    const image = images[currentIndex];
    mainImage.src = image.src;
    mainImage.alt = image.alt;
    thumbnails.forEach((thumbnail, thumbnailIndex) => {
      if (thumbnailIndex === currentIndex) thumbnail.setAttribute("aria-current", "true");
      else thumbnail.removeAttribute("aria-current");
    });
  }

  previous?.addEventListener("click", () => show(currentIndex - 1));
  next?.addEventListener("click", () => show(currentIndex + 1));
  thumbnails.forEach((thumbnail) => {
    thumbnail.addEventListener("click", () => show(Number(thumbnail.dataset.galleryIndex)));
  });
  gallery.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") { event.preventDefault(); show(currentIndex - 1); }
    if (event.key === "ArrowRight") { event.preventDefault(); show(currentIndex + 1); }
  });
  gallery.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "touch") pointerStartX = event.clientX;
  });
  gallery.addEventListener("pointerup", (event) => {
    if (pointerStartX === undefined || event.pointerType !== "touch") return;
    const movement = event.clientX - pointerStartX;
    pointerStartX = undefined;
    if (Math.abs(movement) < 40) return;
    show(movement > 0 ? currentIndex - 1 : currentIndex + 1);
  });
  gallery.addEventListener("pointercancel", () => { pointerStartX = undefined; });
}

function setupTestimonialScroller() {
  const viewport = document.querySelector("[data-testimonial-viewport]");
  const track = document.querySelector("[data-testimonial-track]");
  if (!viewport || !track || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  let paused = false;
  let dragging = false;
  let pointerStartX = 0;
  let scrollStart = 0;
  let animationFrame;

  // Two identical sets make the reset at halfway visually seamless.
  function animate() {
    if (!paused && !dragging) {
      viewport.scrollLeft += 0.32;
      if (viewport.scrollLeft >= track.scrollWidth / 2) viewport.scrollLeft = 0;
    }
    animationFrame = window.requestAnimationFrame(animate);
  }

  viewport.addEventListener("pointerenter", () => { paused = true; });
  viewport.addEventListener("pointerleave", () => { if (!dragging) paused = false; });
  viewport.addEventListener("focusin", () => { paused = true; });
  viewport.addEventListener("focusout", () => { paused = false; });
  viewport.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "mouse" || event.button !== 0) return;
    dragging = true;
    paused = true;
    pointerStartX = event.clientX;
    scrollStart = viewport.scrollLeft;
    viewport.setPointerCapture(event.pointerId);
    viewport.classList.add("is-dragging");
  });
  viewport.addEventListener("pointermove", (event) => {
    if (dragging) viewport.scrollLeft = scrollStart - (event.clientX - pointerStartX);
  });
  function endDrag(event) {
    if (!dragging) return;
    dragging = false;
    if (viewport.hasPointerCapture(event.pointerId)) viewport.releasePointerCapture(event.pointerId);
    viewport.classList.remove("is-dragging");
    paused = false;
  }
  viewport.addEventListener("pointerup", endDrag);
  viewport.addEventListener("pointercancel", endDrag);
  window.addEventListener("pagehide", () => window.cancelAnimationFrame(animationFrame), { once: true });
  animationFrame = window.requestAnimationFrame(animate);
}

clearPaidCart();
updateCartCount();
setupCartPage();
setupContactForm();
setupReviewForm();
setupProductGallery();
setupTestimonialScroller();
window.addEventListener("storage", updateCartCount);
window.addEventListener("clipit:cart-changed", updateCartCount);
