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
