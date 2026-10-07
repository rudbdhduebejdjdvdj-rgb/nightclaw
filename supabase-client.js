(function () {
  const config = window.NIGHTCLAW_SUPABASE;

  if (!config || !window.supabase) {
    console.error("NightClaw: Supabase no está disponible.");
    return;
  }

  window.ncSupabase = window.supabase.createClient(config.url, config.key, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
})();