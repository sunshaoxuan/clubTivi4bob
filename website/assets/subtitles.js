(() => {
  const demo = document.querySelector('[data-subtitle-demo]');
  const copyNode = document.getElementById('subtitle-demo-copy');
  if (!demo || !copyNode) return;
  const copy = JSON.parse(copyNode.textContent);
  const controls = [...demo.querySelectorAll('[data-subtitle-mode]')];
  for (const control of controls) {
    control.addEventListener('click', () => {
      const mode = Number(control.dataset.subtitleMode);
      for (const button of controls) button.setAttribute('aria-pressed', String(button === control));
      demo.querySelector('.subtitle-demo-screen').dataset.state = ['programme', 'advert', 'return'][mode];
      demo.querySelector('.subtitle-demo-caption').hidden = mode === 1;
      demo.querySelector('[data-subtitle-status]').textContent = copy.statuses[mode];
      demo.querySelector('[data-subtitle-description]').textContent = copy.descriptions[mode];
    });
  }
})();
