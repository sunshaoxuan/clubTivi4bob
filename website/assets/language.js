document.querySelector('.language-form select')?.addEventListener('change', event => {
  event.currentTarget.form.requestSubmit();
});
