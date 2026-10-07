(function () {
  const sb = window.ncSupabase;
  if (!sb) return;

  async function track(eventName, metadata = {}) {
    try {
      const { data: { user } } = await sb.auth.getUser();
      await sb.from("analytics_events").insert({
        user_id: user?.id || null,
        event_name: eventName,
        page: location.pathname,
        metadata
      });
    } catch (error) {
      console.debug("NightClaw Analytics:", error);
    }
  }

  window.NightClawAnalytics = { track };

  track("page_view", { referrer: document.referrer || null });
})();