const backTop = document.querySelector('.back-top');
const heroArt = document.querySelector('.hero-visual, .download-hero-featured img');
const main = document.querySelector('main');
const scenes = [...main.querySelectorAll('[data-scroll-scene]')];
const header = document.querySelector('.site-header');
const footer = document.querySelector('footer');
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const tracks = scenes.map((scene, index) => {
  const track = document.createElement('div');
  track.className = 'scroll-scene-track';
  track.toggleAttribute('data-scene-next', index < scenes.length - 1);
  if (scene.id) {
    track.id = scene.id;
    scene.removeAttribute('id');
  }
  scene.before(track);
  track.append(scene);
  return track;
});
let scrollFrame = 0;
let measure = true;
let travel = 1;

function updateScroll() {
  scrollFrame = 0;
  const offset = Math.max(0, window.scrollY);
  const enabled = !motion.matches && CSS.supports('position', 'sticky');

  if (measure) {
    measure = false;
    if (enabled) {
      const headerHeight = header.offsetHeight;
      const available = Math.max(1, window.innerHeight - headerHeight);
      travel = Math.max(1, Math.round(available * .72));
      const heights = scenes.map(scene => scene.offsetHeight);
      main.style.setProperty('--scene-header', `${headerHeight}px`);
      main.style.setProperty('--scene-travel', `${travel}px`);
      const last = tracks.length - 1;
      tracks[last].style.setProperty('--scene-tail', `${Math.max(0, available - heights[last] - footer.offsetHeight)}px`);
      heights.forEach((height, index) => {
        tracks[index].style.setProperty('--scene-hold', `${Math.min(height, available)}px`);
        scenes[index].style.setProperty('--scene-top', `${Math.min(headerHeight, window.innerHeight - height)}px`);
      });
    }
    main.toggleAttribute('data-layered-scroll', enabled);
  }

  const headerHeight = header.offsetHeight;
  const gaps = enabled ? tracks.map(track => track.getBoundingClientRect().top - headerHeight) : [];
  const progress = gaps.map((gap, index) => index === 0 ? 1 : Math.min(1, Math.max(0, 1 - gap / travel)));

  backTop.hidden = offset < 520;
  if (heroArt) heroArt.style.transform = enabled ? `translateY(${Math.min(26, offset * .075)}px)` : '';
  progress.forEach((enter, index) => {
    const leave = progress[index + 1] ?? 0;
    const opacity = Math.min(enter, 1 - leave);
    const lift = enter > 0 && enter < 1 ? -gaps[index] : 0;
    scenes[index].style.setProperty('--scene-opacity', opacity.toFixed(3));
    scenes[index].style.setProperty('--scene-lift', `${lift}px`);
    scenes[index].toggleAttribute('data-scene-behind', opacity < .5);
  });
}

function scheduleScroll() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScroll);
}
function scheduleMeasure() {
  measure = true;
  scheduleScroll();
}
window.addEventListener('scroll', scheduleScroll, { passive: true });
window.addEventListener('resize', scheduleMeasure);
window.addEventListener('pageshow', scheduleMeasure);
motion.addEventListener('change', scheduleMeasure);
if ('ResizeObserver' in window) {
  const observer = new ResizeObserver(scheduleMeasure);
  observer.observe(header);
  observer.observe(footer);
  for (const scene of scenes) observer.observe(scene);
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
