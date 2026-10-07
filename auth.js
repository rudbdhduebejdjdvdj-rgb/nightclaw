const sb = window.ncSupabase;
const form = document.getElementById("loginForm");
const message = document.getElementById("authMessage");
const isSignup = location.hash === "#signup";

function showMessage(text, error = false) {
  if (!message) return;
  message.textContent = text;
  message.style.color = error ? "#ff8d8d" : "";
}

async function authenticate() {
  if (!sb) return showMessage("No se ha podido cargar el sistema de autenticación.", true);

  const email = form.querySelector('input[type="email"]').value.trim();
  const password = form.querySelector('input[type="password"]').value;
  if (!email || !password) return;

  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;

  if (isSignup) {
    button.textContent = "Creando cuenta…";
    const { error } = await sb.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: location.origin + "/login.html" }
    });
    if (error) {
      showMessage(error.message, true);
    } else {
      showMessage("Cuenta creada. Revisa tu correo para confirmar la cuenta.");
    }
    button.disabled = false;
    button.textContent = "Crear cuenta ↗";
  } else {
    button.textContent = "Entrando…";
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) {
      showMessage(error.message, true);
      button.disabled = false;
      button.textContent = "Iniciar sesión ↗";
      return;
    }
    window.NightClawAnalytics?.track("login");
    location.href = "index.html";
  }
}

form?.addEventListener("submit", event => {
  event.preventDefault();
  authenticate();
});

document.querySelectorAll(".oauth").forEach(button => {
  button.addEventListener("click", async () => {
    if (!sb) return showMessage("No se ha podido cargar Supabase.", true);
    const provider = button.dataset.provider;
    showMessage(`Conectando con ${provider}…`);
    const { error } = await sb.auth.signInWithOAuth({
      provider,
      options: { redirectTo: location.origin + "/login.html" }
    });
    if (error) showMessage(error.message, true);
  });
});

document.querySelector(".forgot")?.addEventListener("click", async event => {
  event.preventDefault();
  if (!sb) return;

  const email = form.querySelector('input[type="email"]').value.trim();
  if (!email) return showMessage("Escribe tu email primero.", true);

  const { error } = await sb.auth.resetPasswordForEmail(email, {
    redirectTo: location.origin + "/login.html"
  });

  if (error) showMessage(error.message, true);
  else showMessage("Te hemos enviado un enlace para restablecer la contraseña.");
});

if (isSignup) {
  document.querySelector(".auth-card h1")?.replaceChildren(
    Object.assign(document.createElement("span"), { innerHTML: "Crea tu<br><em>cuenta.</em>" })
  );
  const description = document.querySelector(".auth-muted");
  if (description) description.textContent = "Únete a NightClaw.";
  const button = form?.querySelector('button[type="submit"]');
  if (button) button.textContent = "Crear cuenta ↗";
}