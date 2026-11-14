
(function () {
  // Hamburger menu: open / close (link, X, Esc, Back); focus moves into the menu and back.
  var overlay = document.getElementById('pnav-overlay'), toggle = document.querySelector('.pnav-toggle');
  if (!overlay || !toggle) return;
  var closeBtn = overlay.querySelector('.pnav-close'), menu = overlay.querySelector('.pnav-menu');
  // Scroll lock keeps the page where it was (overflow: hidden on html/body jumps it to the top).
  var keptY = 0;
  function open() {
    keptY = window.scrollY; document.body.style.top = -keptY + 'px';
    overlay.classList.add('is-open'); overlay.setAttribute('aria-hidden', 'false');
    toggle.setAttribute('aria-expanded', 'true'); toggle.setAttribute('aria-label', 'Close menu');
    document.documentElement.classList.add('pnav-lock');
    var cur = menu.querySelector('[aria-current]') || menu.querySelector('a'); if (cur) cur.focus({ preventScroll: true });
  }
  function close(back) {
    if (!overlay.classList.contains('is-open')) return;
    overlay.classList.remove('is-open'); overlay.setAttribute('aria-hidden', 'true');
    toggle.setAttribute('aria-expanded', 'false'); toggle.setAttribute('aria-label', 'Open menu');
    document.documentElement.classList.remove('pnav-lock'); document.body.style.top = '';
    window.scrollTo(0, keptY);
    if (back !== false) toggle.focus({ preventScroll: true });
  }
  toggle.addEventListener('click', function () { overlay.classList.contains('is-open') ? close() : open(); });
  if (closeBtn) closeBtn.addEventListener('click', function () { close(); });
  menu.querySelectorAll('a').forEach(function (a, i) {
    a.style.setProperty('--i', i);
    a.addEventListener('click', function () { close(false); });
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') close(); });
  var hereBtn = document.querySelector('.pnav-here');
  if (hereBtn) hereBtn.addEventListener('click', function () { open(); });

  // Jump buttons: ↑ after the first screen, ↓ until the last screen.
  var up = document.querySelector('.pnav-jump-top'), down = document.querySelector('.pnav-jump-end');
  var still = window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
  if (up) up.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: still }); });
  if (down) down.addEventListener('click', function () {
    window.scrollTo({ top: document.documentElement.scrollHeight, behavior: still });
  });
  var jumpTick = false;
  function jumps() {
    jumpTick = false;
    var y = window.scrollY, h = window.innerHeight, total = document.documentElement.scrollHeight;
    if (up) up.classList.toggle('is-on', y > h * 0.8);
    if (down) down.classList.toggle('is-on', total - (y + h) > h * 0.8);
  }
  window.addEventListener('scroll', function () { if (!jumpTick) { jumpTick = true; requestAnimationFrame(jumps); } }, { passive: true });
  window.addEventListener('resize', jumps);
  jumps();

  // Current section: shown in the bar and marked in the menu. Recomputed on scroll frames.
  var here = document.querySelector('.pnav-here');
  var items = Array.prototype.slice.call(menu.querySelectorAll('a[href^="#"]'))
    .map(function (a) { return { a: a, el: document.getElementById(a.getAttribute('href').slice(1)) }; })
    .filter(function (x) { return x.el; });
  if (!items.length) return;
  var current = null, ticking = false;
  function pick() {
    ticking = false;
    if (overlay.classList.contains('is-open')) return;
    var bar = document.querySelector('.pnav').offsetHeight + 24, hit = items[0];
    items.forEach(function (x) { if (x.el.getBoundingClientRect().top <= bar) hit = x; });
    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) hit = items[items.length - 1];
    if (hit === current) return;
    if (current) current.a.removeAttribute('aria-current');
    current = hit; hit.a.setAttribute('aria-current', 'true');
    if (here) here.textContent = hit.a.textContent;
  }
  window.addEventListener('scroll', function () { if (!ticking) { ticking = true; requestAnimationFrame(pick); } }, { passive: true });
  window.addEventListener('resize', pick);
  pick();
})();
