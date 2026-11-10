const backTop = document.querySelector('.back-top');
const heroArt = document.querySelector('.hero-visual, .download-hero-featured img');
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const wide = matchMedia('(min-width: 761px)');
let scrollFrame = 0;

function updateScroll() {
  scrollFrame = 0;
  const offset = Math.max(0, window.scrollY);
  backTop.hidden = offset < 520;
  if (heroArt) heroArt.style.transform = motion.matches ? '' : `translateY(${Math.min(26, offset * .075)}px)`;
}
window.addEventListener('scroll', () => {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScroll);
}, { passive: true });
motion.addEventListener('change', updateScroll);
updateScroll();

if ('IntersectionObserver' in window && 'animate' in Element.prototype) {
  const entered = new Set();
  const animations = new Map();
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const element = entry.target;
      if (!entry.isIntersecting) {
        if (!animations.has(element)) entered.delete(element);
        continue;
      }
      if (entry.intersectionRatio < .08 || entered.has(element)) continue;
      entered.add(element);
      if (motion.matches || element.contains(document.activeElement)) continue;

      const distance = entry.boundingClientRect.top < 0 ? -28 : 28;
      const animation = element.animate([
        { opacity: .22, transform: `translateY(${distance}px)` },
        { opacity: 1, transform: 'none' },
      ], {
        duration: 780,
        delay: wide.matches ? Number(element.dataset.revealDelay || 0) : 0,
        easing: 'cubic-bezier(.22,.65,.26,1)',
        fill: 'backwards',
      });
      animations.set(element, animation);
      animation.addEventListener('finish', () => {
        animations.delete(element);
        const bounds = element.getBoundingClientRect();
        if (bounds.bottom <= 0 || bounds.top >= window.innerHeight) entered.delete(element);
      }, { once: true });
    }
  }, { threshold: [0, .08] });
  for (const element of document.querySelectorAll('[data-reveal]')) {
    element.addEventListener('focusin', () => {
      animations.get(element)?.cancel();
      animations.delete(element);
    });
    observer.observe(element);
  }
  motion.addEventListener('change', () => {
    if (!motion.matches) return;
    for (const animation of animations.values()) animation.cancel();
    animations.clear();
  });
}

const stationBand = document.querySelector('.station-band');
if (stationBand) {
  const track = stationBand.querySelector('.station-track');
  const marks = track.firstElementChild;
  const duplicate = marks.cloneNode(true);
  duplicate.setAttribute('aria-hidden', 'true');
  track.append(duplicate);
  track.style.setProperty('--station-duration', `${marks.getBoundingClientRect().width / 36}s`);
  stationBand.setAttribute('data-marquee', '');
  const toggle = stationBand.querySelector('.station-toggle');
  toggle.hidden = false;
  toggle.addEventListener('click', () => {
    const paused = stationBand.toggleAttribute('data-paused');
    toggle.setAttribute('aria-pressed', String(paused));
    toggle.firstElementChild.textContent = paused ? '▶' : 'Ⅱ';
  });
}
