(() => {
  const sb = window.ncSupabase;
  const form = document.getElementById("loginForm");
  const message = document.getElementById("authMessage");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const isSignup = new URLSearchParams(location.hash.replace(/^#/, "")).has("signup") || location.hash === "#signup";

  function showMessage(text, error = false) {
    if (!message) return;
    message.textContent = text;
    message.style.color = error ? "#ff8d8d" : "";
  }

  function validEmail(value) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  }

  async function authenticate(event) {
    event?.preventDefault();
    if (!sb) return showMessage("No se ha podido cargar el sistema de autenticación.", true);

    const email = emailInput?.value.trim() || "";
    const password = passwordInput?.value || "";

    if (!validEmail(email)) {
      showMessage("Escribe un email válido, por ejemplo tu@email.com.", true);
      emailInput?.focus();
      return;
    }
    if (password.length < 6) {
      showMessage("La contraseña debe tener al menos 6 caracteres.", true);
      passwordInput?.focus();
      return;
    }

    const button = form?.querySelector('button[type="submit"]');
    if (button) {
      button.disabled = true;
      button.textContent = isSignup ? "Creando cuenta…" : "Entrando…";
    }

    try {
      if (isSignup) {
        const { data, error } = await sb.auth.signUp({
          email,
          password,
          options: { emailRedirectTo: location.origin + "/login.html" }
        });
        if (error) throw error;
        if (data?.session) {
          showMessage("Cuenta creada. Entrando…");
          location.href = "index.html";
        } else {
          showMessage("Cuenta creada. Revisa tu correo para confirmar la cuenta.");
        }
      } else {
        const { error } = await sb.auth.signInWithPassword({ email, password });
        if (error) throw error;
        window.NightClawAnalytics?.track("login");
        location.href = "index.html";
      }
    } catch (error) {
      console.error("NightClaw Auth:", error);
      showMessage(error?.message || "No se ha podido completar la operación.", true);
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = isSignup ? "Crear cuenta ↗" : "Iniciar sesión ↗";
      }
    }
  }

  form?.addEventListener("submit", authenticate);

  document.querySelector(".forgot")?.addEventListener("click", async event => {
    event.preventDefault();
    if (!sb) return showMessage("No se ha podido cargar Supabase.", true);
    const email = emailInput?.value.trim() || "";
    if (!validEmail(email)) return showMessage("Escribe tu email primero.", true);

    const { error } = await sb.auth.resetPasswordForEmail(email, {
      redirectTo: location.origin + "/login.html"
    });
    if (error) showMessage(error.message, true);
    else showMessage("Te hemos enviado un enlace para restablecer la contraseña.");
  });

  if (isSignup) {
    const heading = document.querySelector(".auth-card h1");
    if (heading) heading.innerHTML = "Crea tu<br><em>cuenta.</em>";
    const description = document.querySelector(".auth-muted");
    if (description) description.textContent = "Únete a NightClaw.";
    const button = form?.querySelector('button[type="submit"]');
    if (button) button.textContent = "Crear cuenta ↗";
  }
})();