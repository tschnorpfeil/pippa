import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { parseSwapUsedMiB, parsePressure, parseFootprintMiB, summarizeSamples, evaluateGate, renderReport, reportFileName, turnScript, parseArgs } from './memory-gate.mjs';

test('parseSwapUsedMiB reads sysctl vm.swapusage output', () => {
 assert.equal(parseSwapUsedMiB('total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)'), 512.25);
 assert.equal(parseSwapUsedMiB('total = 4.00G  used = 1.50G  free = 2.50G  (encrypted)'), 1536);
 assert.equal(parseSwapUsedMiB('garbage'), null);
});

test('parsePressure reads the bare level', () => {
 assert.equal(parsePressure('1\n'), 1);
 assert.equal(parsePressure('4'), 4);
 assert.equal(parsePressure(''), null);
});

test('parseFootprintMiB reads footprint output', () => {
 assert.equal(parseFootprintMiB('Footprint: 5.5 GB (16384 bytes per page)'), 5632);
 assert.equal(parseFootprintMiB('Footprint: 800 MB'), 800);
 assert.equal(parseFootprintMiB('nothing'), null);
});

const ok = [
 { footprintMiB: 6000, swapUsedMiB: 100, pressure: 1 },
 { footprintMiB: 7000, swapUsedMiB: 300, pressure: 2 },
 { footprintMiB: 6500, swapUsedMiB: 200, pressure: 1 },
];

test('summarizeSamples takes peak, swap growth at the peak and maximum pressure', () => {
 const s = summarizeSamples(ok);
 assert.equal(s.peakFootprintMiB, 7000);
 assert.equal(s.swapGrowthMiB, 200);
 assert.equal(s.swapEndMiB, 200);
 assert.equal(s.maxPressure, 2);
});

test('gate passes at the swap limit and fails above it', () => {
 assert.equal(evaluateGate(summarizeSamples(ok)).pass, true); // growth 200 <= 256
 const edge = summarizeSamples([{ footprintMiB: 1, swapUsedMiB: 0, pressure: 1 }, { footprintMiB: 1, swapUsedMiB: 256, pressure: 1 }]);
 assert.equal(evaluateGate(edge).pass, true);
 const over = summarizeSamples([{ footprintMiB: 1, swapUsedMiB: 0, pressure: 1 }, { footprintMiB: 1, swapUsedMiB: 257, pressure: 1 }]);
 assert.equal(evaluateGate(over).pass, false);
});

test('gate fails on critical pressure and on missing measurements', () => {
 const crit = summarizeSamples([...ok, { footprintMiB: 1, swapUsedMiB: 100, pressure: 4 }]);
 assert.equal(evaluateGate(crit).pass, false);
 assert.equal(evaluateGate(summarizeSamples([{ footprintMiB: null, swapUsedMiB: null, pressure: null }])).pass, false);
});

test('renderReport states result, numbers and turns', () => {
 const summary = summarizeSamples(ok);
 const md = renderReport({ version: '0.3.18', date: '2026-10-31', host: 'Mac16,1', summary, gate: evaluateGate(summary), turns: [{ label: 'file read', seconds: 12.34, settled: true }] });
 assert.match(md, /^# Pippa 0\.3\.18 release candidate: memory gate/);
 assert.match(md, /\*\*Result: PASS\*\*/);
 assert.match(md, /Peak llama-server footprint \| 7000 MiB/);
 assert.match(md, /Maximum pressure level \| 2 \(warning\)/);
 assert.match(md, /\| 1 \| file read \| 12\.3 \| yes \|/);
 assert.equal(reportFileName('0.3.18', '2026-10-31'), 'release-candidate-0.3.18-2026-10-31.md');
});

test('turn script has five turns with one file read and one search', () => {
 const t = turnScript('/x');
 assert.equal(t.length, 5);
 assert.equal(t.filter(x => x.label === 'file read').length, 1);
 assert.equal(t.filter(x => x.label === 'search').length, 1);
});

test('parseArgs defaults to no run', () => {
 assert.equal(parseArgs([]).run, false);
 assert.deepEqual([parseArgs(['--run', '--version', '1.2.3']).run, parseArgs(['--run', '--version', '1.2.3']).version], [true, '1.2.3']);
 assert.throws(() => parseArgs(['--bogus']));
});

test('without --run the CLI only warns and does nothing', () => {
 const out = execFileSync(process.execPath, [new URL('./memory-gate.mjs', import.meta.url).pathname], { encoding: 'utf8' });
 assert.match(out, /dedicated test Mac/);
 assert.match(out, /Nothing was done/);
});
