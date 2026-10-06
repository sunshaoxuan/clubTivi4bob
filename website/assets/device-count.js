(() => {
  const target = document.getElementById("installed-devices");
  if (!target) return;
  let pending = false;
  async function refresh() {
    if (pending || document.hidden) return;
    pending = true;
    try {
      const response = await fetch("/api/v1/devices/count", {
        cache: "no-store", signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error("Count unavailable");
      const { count } = await response.json();
      target.textContent = Number.isSafeInteger(count) && count >= 0 ? ` (${count})` : "";
    } catch (_) {
      target.textContent = "";
    } finally {
      pending = false;
    }
  }
  refresh();
  setInterval(refresh, 30000);
  document.addEventListener("visibilitychange", refresh);
  window.addEventListener("online", refresh);
})();
