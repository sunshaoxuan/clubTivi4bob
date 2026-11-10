const backTop = document.querySelector('.back-top');
const heroArt = document.querySelector('.hero-visual, .download-hero-featured img');
const scenes = [...document.querySelectorAll('[data-scroll-scene]')];
const header = document.querySelector('.site-header');
const motion = matchMedia('(prefers-reduced-motion: reduce)');
let scrollFrame = 0;

function sceneOpacity(scene, viewport, headerHeight, entryLimit, exitLimit) {
  const { top, bottom } = scene.getBoundingClientRect();
  const distance = (viewport - headerHeight) * .90;
  const enter = Math.max(entryLimit, (viewport - top) / distance);
  const leave = Math.max(exitLimit, (bottom - headerHeight) / distance);
  const progress = Math.max(0, Math.min(1, enter, leave));
  return (.24 + .76 * progress ** 1.6).toFixed(3);
}

function updateScroll() {
  scrollFrame = 0;
  const offset = Math.max(0, window.scrollY);
  const viewport = window.innerHeight;
  const headerHeight = header.offsetHeight;
  const remaining = document.documentElement.scrollHeight - viewport - offset;
  // Keep the first and last screens readable when the page reaches either end.
  const entryLimit = 1 - remaining / viewport;
  const exitLimit = 1 - offset / viewport;
  const opacities = motion.matches ? [] : scenes.map(scene =>
    sceneOpacity(scene, viewport, headerHeight, entryLimit, exitLimit));

  backTop.hidden = offset < 520;
  if (heroArt) heroArt.style.transform = motion.matches ? '' : `translateY(${Math.min(26, offset * .075)}px)`;
  opacities.forEach((opacity, index) => scenes[index].style.setProperty('--scene-opacity', opacity));
}

function scheduleScroll() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScroll);
}
window.addEventListener('scroll', scheduleScroll, { passive: true });
window.addEventListener('resize', scheduleScroll);
window.addEventListener('pageshow', scheduleScroll);
motion.addEventListener('change', scheduleScroll);
if ('ResizeObserver' in window) {
  new ResizeObserver(scheduleScroll).observe(document.querySelector('main'));
}
updateScroll();

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
