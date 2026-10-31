import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseSession, sessionRows, parseLlamaLog, isDivergence, joinRows, report } from './cache-report.mjs';

const session = readFileSync(new URL('./fixtures/cache-session.jsonl', import.meta.url), 'utf8');
const log = readFileSync(new URL('./fixtures/cache-llama.log', import.meta.url), 'utf8');

test('parseSession reads assistant usage and skips junk lines', () => {
 const u = parseSession(session);
 assert.equal(u.length, 3);
 assert.deepEqual([u[1].uncached, u[1].cached], [40, 1588]);
});

test('sessionRows computes hit rate and tokens lost versus the previous prompt', () => {
 const rows = sessionRows(parseSession(session));
 assert.equal(rows[0].lostTokens, 0);
 assert.equal(rows[1].lostTokens, 4); // previous prompt 1592, cached 1588
 assert.equal(rows[2].lostTokens, 1628 - 700);
 assert.ok(Math.abs(rows[1].hitRate - 1588 / 1628) < 1e-9);
});

test('parseLlamaLog extracts selection, timing and release per request', () => {
 const r = parseLlamaLog(log);
 assert.equal(r.length, 3);
 assert.equal(r[0].select, 'lru');
 assert.equal(r[0].task, 0);
 assert.equal(r[0].promptTokens, 1592);
 assert.ok(Math.abs(r[0].prefillSeconds - 23.96043) < 1e-6);
 assert.equal(r[1].simBest, 0.955);
 assert.equal(r[1].keep, 1);
 assert.equal(r[2].keep, 0.669);
 assert.equal(r[2].nTokensAfter, 1600);
});

test('isDivergence flags discarded cache but not the cold first request', () => {
 const r = parseLlamaLog(log);
 assert.equal(isDivergence(r[0], 0), false);
 assert.equal(isDivergence(r[1], 1), false);
 assert.equal(isDivergence(r[2], 2), true);
});

test('joinRows aligns from the end when the log has older requests', () => {
 const rows = sessionRows(parseSession(session)).slice(1);
 const j = joinRows(rows, parseLlamaLog(log));
 assert.equal(j[0].log.task, 181);
 assert.equal(j[1].log.divergence, true);
});

test('report prints a table with totals, with and without the log', () => {
 const withLog = report(session, log).split('\n');
 assert.equal(withLog.length, 5);
 assert.match(withLog.at(-1), /^total\t2532\t2288\t/);
 assert.ok(withLog.at(-1).endsWith('\t1'));
 assert.equal(report(session, null).split('\n')[0], '#\tuncached\tcached\thit%\tlost');
});
