#!/usr/bin/env python3
"""Summarize recorded end-to-end runs after manual evidence review."""
import csv
import json
import pathlib
import re
import statistics
import sys

root = pathlib.Path(sys.argv[1])
rows = [x for p in sorted((root / 'raw').glob('agentic-?-r?.json')) for x in json.loads(p.read_text())]
grades = json.loads((root / 'grades.json').read_text())
labels = {'L': 'K2 / oMLX low', 'M': 'K2 / oMLX medium', 'Q': 'Qwen / llama.cpp thinking'}

def key(x):
    return f"{x['variant']}-r{x['round']}-{x['task']}"

def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 3) if values else None

def fmt(x):
    return '—' if x is None else f'{x:.1f}'

missing = [key(x) for x in rows if key(x) not in grades]
if missing:
    raise SystemExit(f'Manual grades missing: {missing}')
if len(rows) != 90 and '--partial' not in sys.argv:
    raise SystemExit(f'Expected 90 runs, got {len(rows)}')

summary = {}
for arm in labels:
    runs = [r for r in rows if r['variant'] == arm]
    if not runs:
        continue
    successful = [r for r in runs if grades[key(r)]['grade'] == 'yes']
    requests = [q for r in runs for q in r['modelRequests']]
    summary[arm] = {
        'label': labels[arm], 'runs': len(runs),
        'grades': {g: sum(grades[key(r)]['grade'] == g for r in runs) for g in ['yes', 'partial', 'no']},
        'unsupported': sum(grades[key(r)]['unsupported'] for r in runs),
        'medianTotalSeconds': median(r['totalSeconds'] for r in runs),
        'medianSuccessfulTotalSeconds': median(r['totalSeconds'] for r in successful),
        'medianFirstAnswerTextSeconds': median(r['firstWordSeconds'] for r in runs),
        'medianFirstTokenSeconds': median(r['firstTokenSeconds'] for r in runs),
        'totalSuiteSeconds': round(sum(r['totalSeconds'] for r in runs), 3),
        'minTotalSeconds': min(r['totalSeconds'] for r in runs),
        'maxTotalSeconds': max(r['totalSeconds'] for r in runs),
        'medianToolCalls': median(r['toolCalls'] for r in runs),
        'zeroToolRuns': sum(not r['toolCalls'] for r in runs),
        'unrequestedFileMutationRuns': sum(any(t['name'] in ['write', 'edit', 'move_files', 'move_to_trash'] for t in r['tools']) for r in runs),
        'timeouts': sum(r['aborted'] == 'timeout' for r in runs),
        'httpErrors': sum(len(r['httpErrors']) for r in runs),
        'providerErrors': sum(len(r['errors']) for r in runs),
        'lengthStops': sum(s == 'length' for r in runs for s in r['stopReasons']),
        'outputTokens': sum(q.get('usage', {}).get('completion_tokens', 0) for q in requests),
        'promptTokens': sum(q.get('usage', {}).get('prompt_tokens', 0) for q in requests),
        'cachedPromptTokens': sum(q.get('usage', {}).get('prompt_tokens_details', {}).get('cached_tokens', 0) for q in requests),
        'perTask': {},
    }
    if arm == 'Q':
        decode = [tuple(map(float, match)) for p in (root / 'raw').glob('server-q-r*.log')
                  for match in re.findall(r'\|\s+eval time =\s+([\d.]+) ms /\s+(\d+) tokens', p.read_text())]
        seconds = sum(ms / 1000 for ms, _ in decode)
        tokens = sum(n for _, n in decode)
    else:
        usage = [q['usage'] for q in requests if q.get('usage', {}).get('generation_duration', 0) > 0]
        seconds = sum(u['generation_duration'] for u in usage)
        tokens = sum(u['completion_tokens'] for u in usage)
    summary[arm]['reportedGenerationTokensPerSecond'] = round(tokens / seconds, 2) if seconds else None
    summary[arm]['generationTimingSource'] = 'llama.cpp server log' if arm == 'Q' else 'oMLX streamed usage'
    for task in dict.fromkeys(r['task'] for r in runs):
        rr = [r for r in runs if r['task'] == task]
        summary[arm]['perTask'][task] = {'medianSeconds': median(r['totalSeconds'] for r in rr),
            'grades': [grades[key(r)]['grade'] for r in rr], 'seconds': [r['totalSeconds'] for r in rr]}

(root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
with (root / 'runs.csv').open('w') as f:
    fields = ['variant', 'round', 'task', 'grade', 'unsupported', 'totalSeconds', 'firstWordSeconds', 'firstTokenSeconds', 'toolCalls', 'aborted', 'reviewNote']
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    for r in rows:
        g = grades[key(r)]
        writer.writerow({**{k: r.get(k) for k in fields if k in r}, 'grade': g['grade'], 'unsupported': g['unsupported'], 'reviewNote': g['note']})

arms = list(summary)
lines = ['# Recorded results', '', '| Metric | ' + ' | '.join(labels[a] for a in arms) + ' |', '|---|' + '---:|' * len(arms)]
metrics = [
    ('Fully correct / partial / failed', lambda s: '/'.join(str(s['grades'][k]) for k in ['yes', 'partial', 'no'])),
    ('Runs with factual errors', lambda s: str(s['unsupported'])),
    ('Median total time, all attempts (s)', lambda s: fmt(s['medianTotalSeconds'])),
    ('Median total time, successful attempts only (s)', lambda s: fmt(s['medianSuccessfulTotalSeconds'])),
    ('Median first answer-text token (s)', lambda s: fmt(s['medianFirstAnswerTextSeconds'])),
    ('Reported generation speed (tokens/s)', lambda s: fmt(s['reportedGenerationTokensPerSecond'])),
    ('Total time for all attempts (min)', lambda s: fmt(s['totalSuiteSeconds'] / 60)),
    ('Runs without a tool call', lambda s: str(s['zeroToolRuns'])),
    ('Runs with unrequested file-mutation attempts', lambda s: str(s['unrequestedFileMutationRuns'])),
    ('Timeouts / HTTP errors / provider errors', lambda s: f"{s['timeouts']}/{s['httpErrors']}/{s['providerErrors']}"),
    ('Output-limit stops', lambda s: str(s['lengthStops'])),
]
for name, value in metrics:
    lines.append('| ' + name + ' | ' + ' | '.join(value(summary[a]) for a in arms) + ' |')
lines += ['', 'All-attempt medians include early failures. Successful-only medians cover different task mixes and are not a matched speed comparison. Generation speed is total reported generated tokens divided by total reported generation time; engine timing definitions and model tokenizers differ, and unfinished requests without final usage are excluded for oMLX.', '',
    '| Task | ' + ' | '.join(labels[a] for a in arms) + ' |', '|---|' + '---|' * len(arms)]
symbols = {'yes': '✓', 'partial': '~', 'no': '✗'}
for task in dict.fromkeys(r['task'] for r in rows):
    values = []
    for arm in arms:
        t = summary[arm]['perTask'].get(task)
        values.append('—' if not t else f"{fmt(t['medianSeconds'])} s; " + ' '.join(symbols[g] for g in t['grades']))
    lines.append('| ' + task + ' | ' + ' | '.join(values) + ' |')
lines += ['', 'Times are medians of the repeats. Symbols show manual quality grades in round order: ✓ complete, ~ partial, ✗ failed.', '']
(root / 'summary.md').write_text('\n'.join(lines))
print(json.dumps(summary, indent=2))
