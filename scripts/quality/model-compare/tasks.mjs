// Agentic tasks of the comparison: prompt, mock data (mail, web) and an automatic first-pass rubric. The automatic
// grade is a first pass; every answer is also read by hand (README.md: "Grading").
import { join } from 'node:path';

const P = (home, p) => join(home, p);
/** Amount in German or English notation (865,30 / 865.30 / 1.200,00 / 1,200.00; whole euros also as "95 €"). */
const amount = (text, euros, cents) => {
 const t = text.replace(/(\d)[.,\u202f ](?=\d{3}(?!\d))/g, '$1');
 return new RegExp(`(?<![\\d])${euros}[.,]${cents}`).test(t)
  || (cents === '00' && new RegExp(`(?<![\\d.,])${euros}(?![.,]?\\d)\\s?(€|EUR|Euro)`).test(t))
  || (cents.endsWith('0') && new RegExp(`(?<![\\d])${euros}[.,]${cents[0]}(?!\\d)`).test(t));
};
const has = (text, ...words) => words.every(w => text.toLowerCase().includes(w.toLowerCase()));
const any = (text, ...words) => words.some(w => text.toLowerCase().includes(w.toLowerCase()));
const grade = (ok, partial) => ok ? 'yes' : partial ? 'partial' : 'no';

const INVOICES = [
 ['Documents/Rechnungen/scan_0412.pdf', '142', '80', 'Elektro'],
 ['Downloads/invoice_7731.pdf', '95', '00', 'Zahnarzt'],
 ['Downloads/handwerker.pdf', '310', '00', 'Maler'],
 ['Documents/Haushalt/kaufbeleg.pdf', '249', '00', 'Möbel'],
 ['Library/Mobile Documents/com~apple~CloudDocs/Belege/r-2024-11.pdf', '68', '50', 'Fahrrad'],
];
function invoices(r, text) {
 const found = INVOICES.filter(([, e, c]) => amount(text, e, c));
 const sourced = INVOICES.filter(([p, , , vendor]) => text.includes(p.split('/').at(-1)) || text.includes(vendor));
 const sum = amount(text, '865', '30');
 const decoy = amount(text, '1200', '00') || amount(text, '89', '00');
 return { grade: grade(sum && found.length === 5 && sourced.length === 5 && !decoy, found.length >= 3 || sum),
  notes: { amountsFound: found.length, sourced: sourced.length, sumCorrect: sum, decoyAmount: decoy } };
}

const LETTER = 'Downloads/Brief_Hausverwaltung.pdf';
function summary(r, text) {
 const deadline = /20\.\s?11\.(\s?2026)?|20 November|November 20/i.test(text);
 const form = any(text, 'Rückmeldebogen', 'Rückmelde', 'form', 'reply sheet', 'response sheet');
 const windows = any(text, 'Fenster', 'window');
 const day = /13\.\s?0?1\.(\s?2027)?|13 January|January 13/i.test(text);
 const read = r.tools.some(t => t.name === 'mcp__pippa__read_document' && String(t.args?.path ?? '').endsWith(LETTER));
 return { grade: grade(read && deadline && form && windows, read && (deadline || form) && windows),
  notes: { read, deadline, form, windows, day, rent: /38[.,]50/.test(text) } };
}

const INSURANCE = [
 ['Documents/Versicherungen/hausrat_police.pdf', ['Hausrat', 'household contents']],
 ['Documents/Versicherungen/phv.pdf', ['Haftpflicht', 'liability']],
 ['Downloads/kfz_beitrag_2026.pdf', ['Kfz', 'Auto', 'car']],
 ['Desktop/scan_kk.pdf', ['Krankenkasse', 'Krankenversicherung', 'BKK', 'health']],
 ['Library/Mobile Documents/com~apple~CloudDocs/Versicherung/zzv.pdf', ['Zahnzusatz', 'Zahnplus', 'dental']],
 ['Library/CloudStorage/TestDrive/rs_2025.pdf', ['Rechtsschutz', 'legal']],
];
function insurance(r, text) {
 const hits = INSURANCE.filter(([p, words]) => text.includes(p.split('/').at(-1)) || any(text, ...words));
 const falseHits = ['garantie_waschmaschine.pdf', 'abrechnung_hv.pdf', 'Garantie', 'Nebenkostenabrechnung'].filter(w => text.includes(w));
 return { grade: grade(hits.length >= 5 && !falseHits.length, hits.length >= 3), notes: { hits: hits.length, falseHits } };
}

export const WEB = {
 ausweis: [
  { site: 'buergerservice.example', title: 'Personalausweis beantragen', url: 'https://www.buergerservice.example/personalausweis-beantragen', asOf: '2026-09-01',
   text: 'Den Personalausweis beantragen Sie persönlich bei der Personalausweisbehörde Ihres Wohnorts, meist im Bürgeramt. Mitbringen: Ihren bisherigen Ausweis oder Reisepass, ein aktuelles biometrisches Passfoto und gegebenenfalls die Geburtsurkunde. Die Gebühr beträgt 37,00 Euro für Antragstellende ab 24 Jahren und 22,80 Euro für Antragstellende unter 24 Jahren. Die Herstellung dauert in der Regel drei bis vier Wochen. Viele Bürgerämter vergeben Termine online.' },
  { site: 'stadt-musterstadt.example', title: 'Bürgeramt Musterstadt: Personalausweis', url: 'https://www.stadt-musterstadt.example/buergeramt/personalausweis', asOf: '2026-08-15',
   text: 'Termin vereinbaren Sie online oder telefonisch unter 01234 5678. Gebühren: 37,00 Euro (ab 24 Jahren), 22,80 Euro (unter 24 Jahren). Das Passfoto können Sie auch direkt im Bürgeramt digital erstellen lassen (6,00 Euro). Abholung persönlich mit dem alten Ausweis.' },
 ],
 kuendigung: [
  { site: 'verbraucherinfo.example', title: 'Hausratversicherung kündigen: So geht es', url: 'https://www.verbraucherinfo.example/hausratversicherung-kuendigen', asOf: '2026-07-20',
   text: 'Die ordentliche Kündigungsfrist beträgt meist drei Monate zum Ende des Versicherungsjahres; maßgeblich ist Ihr Vertrag. Kündigen Sie in Textform, also per Brief oder E-Mail. Nennen Sie Ihren Namen, Ihre Adresse und die Versicherungsnummer und kündigen Sie „zum nächstmöglichen Zeitpunkt“. Bitten Sie um eine schriftliche Bestätigung. Ein Sonderkündigungsrecht haben Sie nach einer Beitragserhöhung (innerhalb eines Monats nach der Mitteilung) oder nach einem Schadensfall (innerhalb eines Monats nach der Regulierung).' },
 ],
};

const MAIL = {
 subject: 'Ablesung Wasserzähler', from: 'Hausverwaltung Beispiel GmbH <service@hausverwaltung-beispiel.example>', date: 'Mi., 7. Okt. 2026, 09:14',
 body: 'Sehr geehrte Frau Beispiel,\n\nfür die Nebenkostenabrechnung 2026 benötigen wir Ihren aktuellen Zählerstand des Wasserzählers (Zähler-Nr. 4471) in Ihrer Wohnung. Bitte teilen Sie uns den Stand bis zum 31.10.2026 per Antwort auf diese Mail mit.\n\nMit freundlichen Grüßen\nIhre Hausverwaltung Beispiel GmbH',
};

// Like PiShownContext.englishNote: Pippa adds it after an English question (PIPPA_EN_NOTE=0 measures without it).
const EN_NOTE = process.env.PIPPA_EN_NOTE === '0' ? '' : '\n\nAnswer in English.';
// Like PiShownContext.germanNote after a German question (PIPPA_DE_NOTE=0 measures without it); added in taskPrompt.
const DE_NOTE = process.env.PIPPA_DE_NOTE === '0' ? '' : '\n\nAntworte auf Deutsch, mit du.';
/** The message Pippa sends for a task: German tasks get the German note, English ones carry theirs in the prompt. */
export const taskPrompt = (task, home, shown) => task.prompt(home, shown) + (task.lang === 'de' ? DE_NOTE : '');

export function shownPrompt(home, rel, shown, question, german = true) {
 const path = P(home, rel), name = rel.split('/').at(-1);
 const info = shown[path];
 const pages = german ? `${info.pages} Seite${info.pages === 1 ? '' : 'n'}` : `${info.pages} page${info.pages === 1 ? '' : 's'}`;
 return [german ? '[Gezeigt – Pippa hat das nicht gelesen; lies selbst, was du für die Antwort brauchst]' : '[Shown – Pippa has not read this; read what you need for the answer yourself]',
  german ? 'Neu gezeigt:' : 'Newly shown:',
  `1. PDF „${name}“, ${pages}, ${info.size} – ${path} – ${german ? 'lesen mit' : 'read with'} mcp__pippa__read_document`, '', question].join('\n');
}

export const TASKS = [
 { id: 'multi-rechnungen', lang: 'de', prompt: () => 'Such alle Rechnungen aus 2024 und sag mir, was ich insgesamt bezahlt habe.', check: invoices },
 { id: 'vergleich', lang: 'de', prompt: () => 'Vergleich meinen Mietvertrag mit der Nebenkostenabrechnung 2024: passt die Vorauszahlung?',
  check(r, text) {
   const readLease = r.tools.some(t => /mv_scan\.pdf$/.test(String(t.args?.path ?? '')));
   const readBill = r.tools.some(t => /abrechnung_hv\.pdf$/.test(String(t.args?.path ?? '')));
   const monthly = /250[.,]00|250 ?(€|EUR|Euro)/.test(text) || (/180/.test(text) && /\b70\b/.test(text));
   const yearly = /3\.?000/.test(text);
   const back = /270[.,]?(00)?/.test(text);
   const ok = readLease && readBill && monthly && yearly && back;
   return { grade: grade(ok, (readLease || readBill) && (monthly || back)), notes: { readLease, readBill, monthly, yearly, nachzahlung: back } };
  } },
 { id: 'zusammenfassen', lang: 'de', prompt: (home, shown) => shownPrompt(home, LETTER, shown, 'Fass mir diesen Brief kurz zusammen und sag, was ich tun muss.'), check: summary },
 { id: 'ordner-ueberblick', lang: 'de', prompt: () => 'Was liegt alles zum Thema Versicherung bei mir? Kurzer Überblick.', check: insurance },
 { id: 'web-recherche', lang: 'de', web: 'ausweis', prompt: () => 'Was kostet ein neuer Personalausweis und wie beantrage ich ihn?',
  check(r, text) {
   const searched = r.mcp.some(c => c.name === 'web_search');
   const fee = /37[.,]00|37 ?(€|Euro|EUR)/.test(text);
   const young = /22[.,]80/.test(text);
   const how = any(text, 'Bürgeramt', 'persönlich', 'Personalausweisbehörde');
   const source = any(text, 'buergerservice.example', 'stadt-musterstadt.example');
   return { grade: grade(searched && fee && how && source, searched && (fee || how)), notes: { approvalCard: searched, fee, under24: young, how, source } };
  } },
 { id: 'web-plus-datei', lang: 'de', web: 'kuendigung', prompt: () => 'Meine Hausratversicherung: ist die Kündigungsfrist noch drin? Schau auch nach, wie man kündigt.',
  check(r, text) {
   const readPolicy = r.tools.some(t => /hausrat_police\.pdf$/.test(String(t.args?.path ?? '')));
   const searched = r.mcp.some(c => c.name === 'web_search');
   const deadline = /31\.\s?0?8\./.test(text) || /drei Monate|3 Monate/i.test(text) && /30\.\s?11\./.test(text);
   const how = any(text, 'Textform', 'schriftlich', 'E-Mail', 'Brief');
   const number = text.includes('HR-4471-0815') || any(text, 'Versicherungsnummer');
   // Pippa's prompt has no date; whether the answer says the 31.08.2026 deadline has passed is noted, not required.
   const missed = /(nicht mehr|vorbei|verpasst|abgelaufen|zu spät|2027)/i.test(text);
   return { grade: grade(readPolicy && searched && deadline && how, readPolicy && deadline), notes: { readPolicy, approvalCard: searched, deadline, how, number, saysMissedOr2027: missed } };
  } },
 { id: 'mail-antwort', lang: 'de', mail: MAIL, prompt: () => 'Antworte auf die ausgewählte Mail: Der Zählerstand ist 1.234,5 Kubikmeter, heute abgelesen. Kurz und freundlich, als Entwurf.',
  check(r, text) {
   const drafts = r.mcp.filter(c => c.name === 'mail_draft');
   const body = String(drafts[0]?.args?.body ?? '');
   const reading = /1\.?234,5/.test(body);
   const replyTo = drafts[0]?.args?.reply_to === 'selected';
   const claimsSent = /(habe|hab|wurde|ist) (sie |die Mail |die Antwort )?(verschickt|gesendet|abgeschickt)/i.test(text) && !/nicht (verschickt|gesendet|abgeschickt)/i.test(text);
   return { grade: grade(drafts.length === 1 && reading && replyTo && !claimsSent, drafts.length >= 1 && reading), notes: { drafts: drafts.length, reading, replyTo, claimsSent, body } };
  } },
 { id: 'termin', lang: 'de', prompt: (home, shown) => shownPrompt(home, 'Downloads/Buergeramt_Abholung.pdf', shown, 'Trag mir die Frist aus diesem Brief als Erinnerung ein.'),
  check(r) {
   const entries = r.mcp.filter(c => ['reminder_add', 'calendar_add'].includes(c.name));
   const right = entries.length === 1 && /^2026-11-27$/.test(String(entries[0].args?.date ?? ''));
   const anyRight = entries.some(e => /^2026-11-27$/.test(String(e.args?.date ?? '')));
   return { grade: grade(right, anyRight), notes: { entries: entries.map(e => ({ tool: e.name, date: e.args?.date, title: e.args?.title })) } };
  } },
 { id: 'en-multi', lang: 'en', prompt: () => 'Find all my invoices from 2024 and tell me how much I paid in total.' + EN_NOTE, check: invoices },
 { id: 'en-summary', lang: 'en', prompt: (home, shown) => shownPrompt(home, LETTER, shown, 'Summarize this letter briefly and tell me what I need to do.' + EN_NOTE, false), check: summary },
];
