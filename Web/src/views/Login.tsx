import { useState, type FormEvent } from "react";
import { login } from "../api/client";
import type { MeResponse } from "../api/types";
import { t } from "../i18n";

export function Login({ onSignedIn }: { onSignedIn: (user: MeResponse) => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setFailed(false);
    try {
      onSignedIn(await login(email, password));
    } catch {
      setFailed(true);
      setBusy(false);
    }
  }

  return (
    <div className="login">
      <div className="login-card">
        <h1>{t("appName")}</h1>
        <p className="lead">{t("loginLead")}</p>
        <form onSubmit={(e) => void submit(e)}>
          <label>
            {t("email")}
            <input
              type="email"
              autoComplete="username"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </label>
          <label>
            {t("password")}
            <input
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </label>
          {failed && (
            <p role="alert" className="error">
              {t("loginFailed")}
            </p>
          )}
          <button type="submit" className="primary" disabled={busy}>
            {t("signIn")}
          </button>
        </form>
      </div>
    </div>
  );
}
