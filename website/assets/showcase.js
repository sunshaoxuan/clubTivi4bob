const backTop = document.querySelector('.back-top');
function updateBackTop() {
  backTop.hidden = window.scrollY < 520;
}
window.addEventListener('scroll', updateBackTop, { passive: true });
updateBackTop();

if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      observer.unobserve(entry.target);
      entry.target.animate(
        [{ opacity: 0.55, transform: 'translateY(18px)' }, { opacity: 1, transform: 'none' }],
        { duration: 430, easing: 'cubic-bezier(.22,.65,.25,1)' },
      );
    }
  }, { threshold: 0.12 });
  document.querySelectorAll('[data-reveal]').forEach(node => observer.observe(node));
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
