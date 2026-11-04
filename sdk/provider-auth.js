// Provider credentials for libfx agents: the host's own key for a custom
// provider. The engine sends the provider's requests without credentials; this
// module adds them at the fetch edge, from the host's `credentials` callback.
// Credentials never enter the engine or a session's saved records, and are
// masked in the body of a failed response.
//
// A provider spec supplies what differs: which requests it authorizes, how its
// credentials are checked, and which headers carry them.

const maxTokenBytes = 64 * 1024;
const maxErrorBodyBytes = 64 * 1024;
const encoder = new TextEncoder();

/** A non-empty, bounded credential field, or undefined when optional and absent. */
export function tokenString(value, name, required, label) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} credentials ${name} must be a non-empty string`);
  }
  if (encoder.encode(value).length > maxTokenBytes) {
    throw new RangeError(`${label} credentials ${name} exceeds ${maxTokenBytes} bytes`);
  }
  return value;
}

/**
 * A failed response whose body cannot repeat the credentials its request
 * carried. Some servers quote the bearer token back in an error, and the
 * engine shows and saves error details, so this edge, the only code that knows
 * the token, masks it the way fx masks error details from its own providers.
 * JSON is normalized first, so an escaped copy cannot survive.
 */
async function withoutCredentials(response, credentials) {
  if (response.status < 400) return response;
  const raw = await boundedText(response, maxErrorBodyBytes);
  let body = raw ?? "Provider error details exceeded the local limit";
  if (raw !== null && /^\s*[[{"]/.test(raw)) {
    try {
      body = JSON.stringify(JSON.parse(raw));
    } catch {
      body = "Provider error details could not be decoded";
    }
  }
  for (const secret of [credentials.accessToken, credentials.refreshToken]) {
    if (!secret) continue;
    for (const form of new Set([secret, JSON.stringify(secret).slice(1, -1)])) body = body.split(form).join("*".repeat(form.length));
  }
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  headers.delete("content-encoding");
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}

/** The body as text, or null once it exceeds `limit` bytes. */
async function boundedText(response, limit) {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return text + decoder.decode();
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
}

/**
 * The fetch edge for a provider's requests. `credentials({ provider, sessionId })`
 * supplies the credentials.
 *
 * Each spec: `{ provider, matches(endpoint), sessionId(headers), normalize(value),
 * authorize(headers, endpoint, credentials) }`.
 */
export function createProviderAuthorizer(specs, { credentials }) {
  if (typeof credentials !== "function") throw new TypeError("a provider needs a credentials() function");
  return {
    /** The spec that authorizes requests to `endpoint` (origin and path), if any. */
    specFor: (endpoint) => specs.find((spec) => spec.matches(endpoint)),
    /** Sends one request with credentials. */
    async fetch(spec, endpoint, hostFetch, input, init = {}) {
      const sessionId = spec.sessionId(new Headers(init.headers)) || undefined;
      const used = spec.normalize(await credentials({ provider: spec.provider, sessionId }));
      const headers = new Headers(init.headers);
      spec.authorize(headers, endpoint, used);
      return withoutCredentials(await hostFetch(input, { ...init, headers }), used);
    },
  };
}
