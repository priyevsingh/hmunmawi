// Minimal DER / X.509 reader: just what App Store JWS certificate chains need.
// Reads structure only; signatures are checked with WebCrypto in verify.mjs.

export class DerError extends Error {}

const OID_NAMES = {
  "1.2.840.10045.4.3.2": { hash: "SHA-256" }, // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": { hash: "SHA-384" },
  "1.2.840.10045.4.3.4": { hash: "SHA-512" },
};
const CURVES = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};
const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";

function tlv(buf, off) {
  if (off + 2 > buf.length) throw new DerError("truncated DER");
  const tag = buf[off];
  let len = buf[off + 1];
  let hdr = 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4 || off + 2 + n > buf.length) throw new DerError("bad DER length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[off + 2 + i];
    hdr += n;
  }
  const end = off + hdr + len;
  if (end > buf.length) throw new DerError("DER length exceeds buffer");
  return { tag, start: off, body: off + hdr, end };
}

function children(buf, node) {
  const out = [];
  let off = node.body;
  while (off < node.end) {
    const c = tlv(buf, off);
    out.push(c);
    off = c.end;
  }
  if (off !== node.end) throw new DerError("bad DER nesting");
  return out;
}

function expect(node, tag, what) {
  if (node.tag !== tag) throw new DerError(`expected ${what}`);
  return node;
}

function decodeOid(buf, node) {
  expect(node, 0x06, "OID");
  const parts = [];
  let v = 0;
  for (let i = node.body; i < node.end; i++) {
    v = v * 128 + (buf[i] & 0x7f);
    if (!(buf[i] & 0x80)) {
      if (parts.length === 0) {
        const first = v < 40 ? 0 : v < 80 ? 1 : 2;
        parts.push(first, v - first * 40);
      } else parts.push(v);
      v = 0;
    }
  }
  return parts.join(".");
}

function decodeTime(buf, node) {
  const s = String.fromCharCode(...buf.subarray(node.body, node.end));
  let m;
  if (node.tag === 0x17) m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  else if (node.tag === 0x18) m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  else throw new DerError("expected time");
  if (!m) throw new DerError("bad time");
  let year = +m[1];
  if (node.tag === 0x17) year += year >= 50 ? 1900 : 2000;
  return Date.UTC(year, +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
}

export function parseCertificate(der) {
  if (!(der instanceof Uint8Array)) throw new DerError("certificate must be bytes");
  const cert = expect(tlv(der, 0), 0x30, "Certificate");
  if (cert.end !== der.length) throw new DerError("trailing bytes after certificate");
  const [tbs, sigAlg, sigBits] = children(der, cert);
  expect(tbs, 0x30, "TBSCertificate");
  expect(sigAlg, 0x30, "signatureAlgorithm");
  expect(sigBits, 0x03, "signature");
  const sigAlgOid = decodeOid(der, children(der, sigAlg)[0]);

  const f = children(der, tbs);
  let i = 0;
  if (f[i].tag === 0xa0) i++; // version
  expect(f[i++], 0x02, "serial");
  const tbsSigAlg = expect(f[i++], 0x30, "tbs signature algorithm");
  if (decodeOid(der, children(der, tbsSigAlg)[0]) !== sigAlgOid) throw new DerError("signature algorithm mismatch");
  const issuer = expect(f[i++], 0x30, "issuer");
  const validity = children(der, expect(f[i++], 0x30, "validity"));
  const subject = expect(f[i++], 0x30, "subject");
  const spki = expect(f[i++], 0x30, "subjectPublicKeyInfo");

  const spkiParts = children(der, spki);
  const algParts = children(der, expect(spkiParts[0], 0x30, "key algorithm"));
  const keyOid = decodeOid(der, algParts[0]);
  const curveOid = algParts[1] ? decodeOid(der, algParts[1]) : null;

  const extensions = new Map();
  for (; i < f.length; i++) {
    if (f[i].tag !== 0xa3) continue;
    const seq = expect(children(der, f[i])[0], 0x30, "extensions");
    for (const ext of children(der, seq)) {
      const parts = children(der, expect(ext, 0x30, "extension"));
      const oid = decodeOid(der, parts[0]);
      let k = 1;
      let critical = false;
      if (parts[k].tag === 0x01) critical = der[parts[k++].body] !== 0;
      const value = expect(parts[k], 0x04, "extension value");
      extensions.set(oid, { critical, value: der.subarray(value.body, value.end) });
    }
  }

  let isCA = false;
  const bc = extensions.get(OID_BASIC_CONSTRAINTS);
  if (bc) {
    const seq = expect(tlv(bc.value, 0), 0x30, "basicConstraints");
    const first = children(bc.value, seq)[0];
    isCA = !!first && first.tag === 0x01 && bc.value[first.body] !== 0;
  }

  return {
    der,
    tbs: der.subarray(tbs.start, tbs.end),
    sigAlgOid,
    hash: OID_NAMES[sigAlgOid]?.hash ?? null,
    signature: der.subarray(sigBits.body + 1, sigBits.end), // skip unused-bits byte
    issuer: der.subarray(issuer.start, issuer.end),
    subject: der.subarray(subject.start, subject.end),
    notBefore: decodeTime(der, validity[0]),
    notAfter: decodeTime(der, validity[1]),
    spki: der.subarray(spki.start, spki.end),
    keyIsEC: keyOid === OID_EC_PUBLIC_KEY,
    curve: curveOid ? CURVES[curveOid] ?? null : null,
    extensions,
    isCA,
  };
}

/** DER ECDSA-Sig-Value -> fixed-width r||s, which is what WebCrypto verifies. */
export function ecdsaDerToRaw(sig, size) {
  const seq = expect(tlv(sig, 0), 0x30, "ECDSA signature");
  if (seq.end !== sig.length) throw new DerError("trailing bytes after signature");
  const [r, s] = children(sig, seq);
  const out = new Uint8Array(size * 2);
  for (const [node, at] of [[expect(r, 0x02, "r"), 0], [expect(s, 0x02, "s"), size]]) {
    let v = sig.subarray(node.body, node.end);
    while (v.length > 0 && v[0] === 0) v = v.subarray(1);
    if (v.length === 0 || v.length > size) throw new DerError("bad ECDSA integer");
    out.set(v, at + size - v.length);
  }
  return out;
}

export function pemToDer(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return b64ToBytes(b64);
}

export function b64ToBytes(b64) {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) throw new DerError("bad base64");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
