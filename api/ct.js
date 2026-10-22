/* ppedv Calltracking — eine Funktion für alles (?a=...).
   Speicher: privater Vercel-Blob-Store.
     tage/<JJJJ-MM-TT>/<nebenstelle>.json  Anrufe einer Person an einem Tag (+ Live-Status)
     nebenstellen.json                     wer schon einmal gemeldet hat
     zugang.json                           scrypt-Hash des Team-Codes
   Der Team-Code verlässt den Server nie — gespeichert wird nur der Hash. */
import { put, get } from "@vercel/blob";
import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";

/* Feste Zuordnung Nebenstelle → Name. Neue Mitarbeiter erscheinen auch ohne Eintrag
   (als „Nebenstelle NN“), sobald ihr PC das erste Mal meldet. */
const TEAM = {
  "30": "Mario",
  "16": "Jasmin",
  "64": "Katharina"
};
const RUFNUMMER = n => `+49 8677 9889-${n}`;

const istTag = v => typeof v === "string" && /^\d{4}-\d\d-\d\d$/.test(v);
const istExt = v => typeof v === "string" && /^\d{2,6}$/.test(v);
const istTs = v => v == null || v === "" || (typeof v === "string" && /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/.test(v));
const ZUGANG = "zugang.json", NST = "nebenstellen.json";
const tagPfad = (tag, ext) => `tage/${tag}/${ext}.json`;

const hashen = (pw, salt) => scryptSync(String(pw), salt, 64).toString("base64");
function stimmt(pw, z) {
  if (!z || !z.salt || !z.hash) return false;
  const a = Buffer.from(hashen(pw, z.salt), "base64"), b = Buffer.from(String(z.hash), "base64");
  return a.length === b.length && timingSafeEqual(a, b);
}

async function lesen(p) {
  /* useCache:false — sonst liefert der CDN-Cache bis zu 60 s lang den alten Stand */
  try {
    const r = await get(p, { access: "private", useCache: false });
    if (!r || r.statusCode !== 200 || !r.stream) return null;
    const leser = r.stream.getReader(), dec = new TextDecoder();
    let txt = "";
    for (;;) { const { done, value } = await leser.read(); if (done) break; txt += dec.decode(value, { stream: true }); }
    return JSON.parse(txt + dec.decode());
  } catch { return null; }
}
const schreiben = (p, daten) => put(p, JSON.stringify(daten), {
  access: "private", allowOverwrite: true, contentType: "application/json", cacheControlMaxAge: 0
});

async function body(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") { try { return JSON.parse(req.body); } catch { return {}; } }
  return {};
}
const antwort = (res, status, daten) => { res.setHeader("Cache-Control", "no-store"); res.status(status).json(daten); };
const warten = ms => new Promise(r => setTimeout(r, ms));

/* Ein Anruf, wie ihn der Agent aus dem Linkus-Log liest — nur bekannte Felder übernehmen */
function anruf(c) {
  if (!c || typeof c !== "object" || !istTs(c.start) || !c.start) return null;
  const ts = v => (istTs(v) && v) ? v : null;
  return {
    start: c.start, number: String(c.number || "").replace(/[^\d+*#]/g, "").slice(0, 24),
    dir: c.dir === "in" ? "in" : "out", ring: ts(c.ring), answer: ts(c.answer), end: ts(c.end),
    code: Number.isFinite(+c.code) ? Math.trunc(+c.code) : 0,
    state: Number.isFinite(+c.state) ? Math.trunc(+c.state) : 0, sipErr: !!c.sipErr
  };
}

/* Datumsliste von..bis (höchstens 62 Tage) */
function tage(von, bis) {
  const out = [], d = new Date(von + "T12:00:00Z"), e = new Date(bis + "T12:00:00Z");
  while (d <= e && out.length < 62) { out.push(d.toISOString().slice(0, 10)); d.setUTCDate(d.getUTCDate() + 1); }
  return out;
}

async function parallel(aufgaben, n = 12) {
  const erg = new Array(aufgaben.length); let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, aufgaben.length) }, async () => {
    while (i < aufgaben.length) { const k = i++; erg[k] = await aufgaben[k](); }
  }));
  return erg;
}

export default async function handler(req, res) {
  const a = String(req.query.a || "");
  const b = req.method === "POST" ? await body(req) : {};
  const code = String(req.headers["x-team-code"] || b.code || "");

  try {
    const zugang = await lesen(ZUGANG);

    /* Ersteinrichtung: der erste legt den Team-Code fest */
    if (a === "status") return antwort(res, 200, { ok: true, eingerichtet: !!zugang });
    if (a === "einrichten") {
      if (zugang) return antwort(res, 409, { ok: false, error: "schon eingerichtet" });
      if (code.length < 6) return antwort(res, 400, { ok: false, error: "Team-Code: mindestens 6 Zeichen" });
      const salt = randomBytes(16).toString("base64");
      await schreiben(ZUGANG, { salt, hash: hashen(code, salt), seit: new Date().toISOString() });
      return antwort(res, 200, { ok: true });
    }

    if (!zugang) return antwort(res, 503, { ok: false, error: "noch nicht eingerichtet" });
    if (!stimmt(code, zugang)) { await warten(600); return antwort(res, 401, { ok: false, error: "Team-Code falsch" }); }

    if (a === "pruefen") return antwort(res, 200, { ok: true });

    /* Team-Code ändern (alter Code nötig) */
    if (a === "code") {
      const neu = String(b.neu || "");
      if (neu.length < 6) return antwort(res, 400, { ok: false, error: "Team-Code: mindestens 6 Zeichen" });
      const salt = randomBytes(16).toString("base64");
      await schreiben(ZUGANG, { salt, hash: hashen(neu, salt), seit: new Date().toISOString() });
      return antwort(res, 200, { ok: true });
    }

    /* Agent meldet Anrufe: { ext, agent, days: { "JJJJ-MM-TT": [anrufe] }, live, reg, heute } */
    if (a === "sync") {
      if (req.method !== "POST") return antwort(res, 405, { ok: false });
      const ext = String(b.ext || "");
      if (!istExt(ext)) return antwort(res, 400, { ok: false, error: "Nebenstelle fehlt" });
      const days = b.days && typeof b.days === "object" ? b.days : {};
      const keys = Object.keys(days).filter(istTag).slice(0, 62);
      const heute = istTag(b.heute) ? b.heute : null;
      const jetzt = new Date().toISOString();
      const live = (Array.isArray(b.live) ? b.live : []).slice(0, 5).map(x => ({
        number: String((x && x.number) || "").replace(/[^\d+*#]/g, "").slice(0, 24),
        dir: x && x.dir === "in" ? "in" : "out", start: istTs(x && x.start) ? x.start : null,
        answer: istTs(x && x.answer) ? x.answer || null : null, ring: istTs(x && x.ring) ? x.ring || null : null
      }));
      const reg = b.reg && typeof b.reg === "object" ? { status: +b.reg.status || 0, ts: istTs(b.reg.ts) ? b.reg.ts : null } : null;
      const agent = String(b.agent || "").slice(0, 20);
      /* „heute“ bekommt immer den Live-Status mit, auch ohne neue Anrufe (Lebenszeichen) */
      if (heute && !keys.includes(heute)) {
        const alt = await lesen(tagPfad(heute, ext));
        days[heute] = alt && Array.isArray(alt.calls) ? alt.calls : [];
        keys.push(heute);
      }
      await parallel(keys.map(tag => () => {
        const calls = (Array.isArray(days[tag]) ? days[tag] : []).slice(0, 3000).map(anruf).filter(c => c && c.start.startsWith(tag));
        const satz = { ext, calls, updatedAt: jetzt, agent };
        if (tag === heute) Object.assign(satz, { seen: jetzt, live, reg });
        return schreiben(tagPfad(tag, ext), satz);
      }), 6);
      /* Verzeichnis der Nebenstellen nur schreiben, wenn eine neue dazukommt */
      const nst = (await lesen(NST)) || {};
      if (!nst[ext]) { nst[ext] = { seit: jetzt }; await schreiben(NST, nst); }
      return antwort(res, 200, { ok: true, tage: keys.length, name: TEAM[ext] || null });
    }

    /* Dashboard: Anrufe aller Personen im Zeitraum */
    if (a === "daten") {
      const von = String(req.query.von || ""), bis = String(req.query.bis || von);
      if (!istTag(von) || !istTag(bis) || bis < von) return antwort(res, 400, { ok: false, error: "Zeitraum" });
      const nst = (await lesen(NST)) || {};
      const exts = [...new Set([...Object.keys(TEAM), ...Object.keys(nst)])].filter(istExt);
      const liste = tage(von, bis);
      const jobs = [];
      liste.forEach(tag => exts.forEach(ext => jobs.push(async () => ({ tag, ext, d: await lesen(tagPfad(tag, ext)) }))));
      const erg = await parallel(jobs, 16);
      const out = {};
      erg.forEach(({ tag, ext, d }) => { if (d) (out[tag] = out[tag] || {})[ext] = d; });
      const team = exts.map(ext => ({ ext, name: TEAM[ext] || `Nebenstelle ${ext}`, nummer: RUFNUMMER(ext), bekannt: !!nst[ext] }));
      return antwort(res, 200, { ok: true, now: new Date().toISOString(), team, tage: out });
    }

    return antwort(res, 400, { ok: false, error: "unbekannte Aktion" });
  } catch (e) {
    console.error("ct", a, e && e.message);
    return antwort(res, 500, { ok: false, error: "Serverfehler" });
  }
}
