// Full verification of App Store Server Notification JWS values (per Apple's docs):
//   x5c = [leaf, intermediate, root]; root must be Apple Root CA - G3; every link's
//   signature, validity window and Apple marker OID is checked; then the ES256 JWS
//   signature is verified with the leaf key.
import { APPLE_ROOT_CA_G3_PEM, APPLE_ROOT_CA_G3_SHA256 } from "./root.mjs";
import { b64ToBytes, ecdsaDerToRaw, parseCertificate, pemToDer } from "./x509.mjs";

export const OID_LEAF = "1.2.840.113635.100.6.11.1"; // Mac App Store Receipt Signing
export const OID_INTERMEDIATE = "1.2.840.113635.100.6.2.1"; // Apple WWDR intermediate

/** status 400 = not a well-formed JWS; 401 = well-formed but not trusted. */
export class VerifyError extends Error {
  constructor(message, status = 401) {
    super(message);
    this.status = status;
  }
}

const enc = new TextEncoder();
const dec = new TextDecoder();

const b64uToBytes = (s) => {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new VerifyError("bad base64url", 400);
  return b64ToBytes(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
};

const sameBytes = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...d].map((x) => x.toString(16).padStart(2, "0")).join("");
}

let pinnedRoot;
export function appleRootDer() {
  return (pinnedRoot ??= pemToDer(APPLE_ROOT_CA_G3_PEM));
}

async function importKey(cert, usage = ["verify"]) {
  if (!cert.keyIsEC || !cert.curve) throw new VerifyError("unsupported certificate key");
  return crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: cert.curve.name }, false, usage);
}

async function certSignedBy(child, issuer) {
  if (!child.hash || !issuer.curve) return false;
  const key = await importKey(issuer);
  const raw = ecdsaDerToRaw(child.signature, issuer.curve.size);
  return crypto.subtle.verify({ name: "ECDSA", hash: child.hash }, key, raw, child.tbs);
}

/**
 * Verify an x5c chain. Returns the leaf certificate.
 * opts.now: epoch ms (default Date.now()); opts.rootDer: override the pinned root (tests only).
 */
export async function verifyChain(x5c, opts = {}) {
  const now = opts.now ?? Date.now();
  if (!Array.isArray(x5c) || x5c.length !== 3 || x5c.some((c) => typeof c !== "string")) {
    throw new VerifyError("x5c must hold leaf, intermediate and root", 400);
  }
  let leaf, inter, root;
  try {
    [leaf, inter, root] = x5c.map((c) => parseCertificate(b64ToBytes(c)));
  } catch (e) {
    throw new VerifyError(`bad certificate: ${e.message}`, 400);
  }

  const pinned = opts.rootDer ?? appleRootDer();
  if (!opts.rootDer && (await sha256Hex(pinned)) !== APPLE_ROOT_CA_G3_SHA256) {
    throw new VerifyError("embedded Apple root does not match its fingerprint", 500);
  }
  if (!sameBytes(root.der, pinned)) throw new VerifyError("root is not Apple Root CA - G3");

  for (const c of [leaf, inter, root]) {
    if (now < c.notBefore || now > c.notAfter) throw new VerifyError("certificate outside validity period");
  }
  if (!sameBytes(leaf.issuer, inter.subject) || !sameBytes(inter.issuer, root.subject)) {
    throw new VerifyError("certificate names do not chain");
  }
  if (!inter.isCA || !root.isCA) throw new VerifyError("issuer is not a CA");
  if (!leaf.extensions.has(OID_LEAF)) throw new VerifyError("leaf lacks Apple receipt-signing OID");
  if (!inter.extensions.has(OID_INTERMEDIATE)) throw new VerifyError("intermediate lacks Apple WWDR OID");

  if (!(await certSignedBy(leaf, inter))) throw new VerifyError("leaf signature invalid");
  if (!(await certSignedBy(inter, root))) throw new VerifyError("intermediate signature invalid");
  if (!(await certSignedBy(root, root))) throw new VerifyError("root signature invalid");
  return leaf;
}

/** Verify a compact JWS and return its decoded payload object. */
export async function verifyJws(token, opts = {}) {
  if (typeof token !== "string") throw new VerifyError("JWS must be a string", 400);
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((p) => p === "")) throw new VerifyError("not a compact JWS", 400);
  let header, payload;
  try {
    header = JSON.parse(dec.decode(b64uToBytes(parts[0])));
    payload = JSON.parse(dec.decode(b64uToBytes(parts[1])));
  } catch (e) {
    if (e instanceof VerifyError) throw e;
    throw new VerifyError("JWS header or payload is not JSON", 400);
  }
  if (!header || typeof header !== "object" || !payload || typeof payload !== "object") {
    throw new VerifyError("JWS header or payload is not an object", 400);
  }
  if (header.alg !== "ES256") throw new VerifyError("alg must be ES256");

  const leaf = await verifyChain(header.x5c, opts);
  if (leaf.curve?.name !== "P-256") throw new VerifyError("leaf key is not P-256");
  const sig = b64uToBytes(parts[2]);
  if (sig.length !== 64) throw new VerifyError("bad ES256 signature length");
  const key = await importKey(leaf);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, enc.encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new VerifyError("JWS signature invalid");
  return payload;
}
