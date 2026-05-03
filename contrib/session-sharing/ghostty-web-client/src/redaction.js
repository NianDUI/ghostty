// Token redaction helpers for the browser web client.
//
// Goal: catch the obvious "we logged a URL or an Authorization header with the
// raw token" mistake on every error surface (console, DOM textContent, status
// strings). This is best-effort string scrubbing, not a cryptographic
// guarantee — the actual mitigation is "don't construct strings with secrets
// in them" but we still want a backstop because errors thrown by browser APIs
// can include URLs we did not assemble ourselves.
//
// What gets redacted:
//   - Authorization headers of the form "Bearer <opaque>"
//   - Query parameters named token, client_token, agent_token
//
// Anything else is passed through unchanged so non-sensitive payloads stay
// readable in the console.

const TOKEN_QUERY_KEYS = ["token", "client_token", "agent_token"];

export function redactSensitiveText(value) {
  if (typeof value !== "string") return value;
  let result = value.replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]");
  for (const key of TOKEN_QUERY_KEYS) {
    const pattern = new RegExp(`([?&]${key}=)[^&\\s]+`, "gi");
    result = result.replace(pattern, "$1[REDACTED]");
  }
  return result;
}

export function redactErrorMessage(error) {
  if (error == null) return "";
  let text;
  if (typeof error === "string") {
    text = error;
  } else if (typeof error === "object" && typeof error.message === "string") {
    text = error.message;
  } else {
    try {
      text = String(error);
    } catch {
      return "";
    }
  }
  return redactSensitiveText(text);
}
