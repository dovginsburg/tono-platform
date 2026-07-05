/* tono — shared nav + footer include + active-link highlighting */
(function () {
  const path = (location.pathname.split('/').pop() || 'index.html').toLowerCase();

  const navHTML = `
  <nav class="nav">
    <div class="nav-inner">
      <a href="index.html" class="logo">
        <span class="logo-dot"></span>
        tono
      </a>
      <div class="nav-links" id="navLinks">
        <a href="index.html" data-page="index.html">Home</a>
        <a href="features.html" data-page="features.html">Features</a>
        <a href="demo.html" data-page="demo.html">Demo</a>
        <a href="pricing.html" data-page="pricing.html">Pricing</a>
        <a href="about.html" data-page="about.html">About</a>
      <a href="brand.html" data-page="brand.html">Brand</a>
      </div>
      <a href="#download" class="nav-cta">Download</a>
      <button class="nav-burger" id="navBurger" aria-label="Toggle menu">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <line x1="4" y1="7" x2="20" y2="7"/>
          <line x1="4" y1="12" x2="20" y2="12"/>
          <line x1="4" y1="17" x2="20" y2="17"/>
        </svg>
      </button>
    </div>
    <div class="nav-mobile" id="navMobile">
      <a href="index.html" data-page="index.html">Home</a>
      <a href="features.html" data-page="features.html">Features</a>
      <a href="demo.html" data-page="demo.html">Demo</a>
      <a href="pricing.html" data-page="pricing.html">Pricing</a>
      <a href="about.html" data-page="about.html">About</a>
      <a href="brand.html" data-page="brand.html">Brand</a>
      <a href="index.html#download" class="nav-cta-mobile">Download</a>
    </div>
  </nav>
  `;

  const footerHTML = `
  <footer>
    <div class="footer-inner">
      <div class="footer-brand">
        <a href="index.html" class="logo">
          <span class="logo-dot"></span>
          tono
        </a>
        <p>The keyboard that coaches your tone in real time — before you hit send.</p>
      </div>
      <div class="footer-col">
        <h4>Product</h4>
        <ul>
          <li><a href="features.html">Features</a></li>
          <li><a href="demo.html">Live demo</a></li>
          <li><a href="pricing.html">Pricing</a></li>
          <li><a href="index.html#download">Download</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Company</h4>
        <ul>
          <li><a href="about.html">About</a></li>
          <li><a href="mailto:hello@tonoit.com">Contact</a></li>
          <li><a href="mailto:press@tonoit.com">Press</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Legal</h4>
        <ul>
          <li><a href="privacy.html">Privacy</a></li>
          <li><a href="terms.html">Terms</a></li>
        </ul>
      </div>
    </div>
    <div class="footer-bottom">
      <span>&copy; 2026 tono. All rights reserved.</span>
      <div class="footer-links-inline">
        <a href="privacy.html">Privacy</a>
        <a href="terms.html">Terms</a>
        <a href="mailto:hello@tonoit.com">hello@tonoit.com</a>
      </div>
    </div>
  </footer>
  `;

  // Inject nav at top of body, footer at bottom
  document.addEventListener('DOMContentLoaded', function () {
    // Insert nav as first child of body
    document.body.insertAdjacentHTML('afterbegin', navHTML);
    // Insert footer as last child of body
    document.body.insertAdjacentHTML('beforeend', footerHTML);

    // Mark active link
    document.querySelectorAll('[data-page]').forEach(function (a) {
      if (a.getAttribute('data-page') === path) a.classList.add('active');
    });

    // Burger toggle
    const burger = document.getElementById('navBurger');
    const mobile = document.getElementById('navMobile');
    if (burger && mobile) {
      burger.addEventListener('click', function () {
        mobile.classList.toggle('open');
      });
    }

    // Scroll reveal
    const reveals = document.querySelectorAll('.reveal');
    if ('IntersectionObserver' in window && reveals.length) {
      const io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add('visible');
            io.unobserve(e.target);
          }
        });
      }, { threshold: 0.1 });
      reveals.forEach(function (el) { io.observe(el); });
    } else {
      reveals.forEach(function (el) { el.classList.add('visible'); });
    }
  });
})();
