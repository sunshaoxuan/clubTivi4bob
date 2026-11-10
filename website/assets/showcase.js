const backTop = document.querySelector('.back-top');
const heroArt = document.querySelector('.hero-visual, .download-hero-featured img');
const main = document.querySelector('main');
const scenes = [...main.querySelectorAll('[data-scroll-scene]')];
const header = document.querySelector('.site-header');
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const tracks = scenes.map(scene => {
  const track = document.createElement('div');
  track.className = 'scroll-scene-track';
  if (scene.id) {
    track.id = scene.id;
    scene.removeAttribute('id');
  }
  scene.before(track);
  track.append(scene);
  return track;
});
let scrollFrame = 0;
const pendingCounters = new Set(main.querySelectorAll('[data-count-to]'));
const counting = new Map();
const numberFormat = new Intl.NumberFormat('en-US');
const countDuration = 2500;
let counterFrame = 0;

function showCount(counter, number) {
  counter.textContent = numberFormat.format(number);
}

if (!motion.matches) {
  for (const counter of pendingCounters) showCount(counter, 0);
}

function tickCounters(now) {
  counterFrame = 0;
  for (const [counter, start] of counting) {
    const progress = Math.max(0, Math.min(1, (now - start) / countDuration));
    const eased = progress * progress * (3 - 2 * progress);
    showCount(counter, Math.round(Number(counter.dataset.countTo) * eased));
    if (progress === 1) counting.delete(counter);
  }
  if (counting.size) counterFrame = requestAnimationFrame(tickCounters);
}

function revealCounters(visibleScene, headerHeight) {
  if (motion.matches) {
    for (const counter of [...pendingCounters, ...counting.keys()]) {
      showCount(counter, Number(counter.dataset.countTo));
    }
    pendingCounters.clear();
    counting.clear();
    return;
  }
  if (!visibleScene || !pendingCounters.size) return;
  const start = performance.now();
  for (const counter of pendingCounters) {
    const { top, bottom, height } = counter.getBoundingClientRect();
    const visible = Math.min(window.innerHeight, bottom) - Math.max(headerHeight, top);
    if (height <= 0 || visible < height * .55) continue;
    pendingCounters.delete(counter);
    counting.set(counter, start);
  }
  if (counting.size && !counterFrame) counterFrame = requestAnimationFrame(tickCounters);
}


function clamp(progress) {
  return Math.min(1, Math.max(0, progress));
}

function sceneTransition(track, index, viewport, headerHeight, remaining) {
  const { top, bottom } = track.getBoundingClientRect();
  const available = Math.max(1, viewport - headerHeight);
  const entering = clamp((viewport - top) / (available * .56));
  const leaving = clamp((bottom - headerHeight) / (available * .30));
  const nearEnd = clamp(1 - remaining / (available * .56));
  const shown = index === 0 ? 1 : Math.max(entering, nearEnd);
  // The next section lifts across the seam briefly. Both sections keep scrolling.
  const lift = index === 0 ? 0 : -Math.min(112, available * .14) * Math.sin(Math.PI * entering) * (1 - nearEnd);
  return { opacity: Math.min(.4 + .6 * shown, leaving), lift };
}

function updateScroll() {
  scrollFrame = 0;
  const offset = Math.max(0, window.scrollY);
  const enabled = !motion.matches;
  const viewport = window.innerHeight;
  const headerHeight = header.offsetHeight;
  const remaining = document.documentElement.scrollHeight - viewport - offset;
  const transitions = enabled ? tracks.map((track, index) =>
    sceneTransition(track, index, viewport, headerHeight, remaining)) : [];

  main.toggleAttribute('data-layered-scroll', enabled);
  main.style.setProperty('--scene-header', `${headerHeight}px`);
  backTop.hidden = offset < 520;
  if (heroArt) heroArt.style.transform = enabled ? `translateY(${Math.min(26, offset * .075)}px)` : '';
  transitions.forEach(({ opacity, lift }, index) => {
    scenes[index].style.setProperty('--scene-opacity', opacity.toFixed(3));
    scenes[index].style.setProperty('--scene-lift', `${lift.toFixed(1)}px`);
    scenes[index].toggleAttribute('data-scene-behind', opacity < .2);
  });
  revealCounters(!enabled || (transitions[0]?.opacity ?? 0) > .5, headerHeight);
}

function scheduleScroll() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScroll);
}
window.addEventListener('scroll', scheduleScroll, { passive: true });
window.addEventListener('resize', scheduleScroll);
window.addEventListener('pageshow', scheduleScroll);
motion.addEventListener('change', scheduleScroll);
if ('ResizeObserver' in window) {
  const observer = new ResizeObserver(scheduleScroll);
  observer.observe(header);
  observer.observe(main);
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
