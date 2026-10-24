# Recorded results

| Metric | K2 / oMLX low | K2 / oMLX medium | Qwen / llama.cpp thinking |
|---|---:|---:|---:|
| Fully correct / partial / failed | 3/11/16 | 7/16/7 | 14/9/7 |
| Runs with factual errors | 16 | 18 | 12 |
| Median total time, all attempts (s) | 16.1 | 48.0 | 26.3 |
| Median total time, successful attempts only (s) | 14.3 | 44.8 | 21.8 |
| Median first answer-text token (s) | 3.2 | 4.5 | 15.6 |
| Reported generation speed (tokens/s) | 20.9 | 20.8 | 20.4 |
| Total time for all attempts (min) | 14.9 | 33.0 | 17.0 |
| Runs without a tool call | 7 | 1 | 0 |
| Runs with unrequested file-mutation attempts | 2 | 0 | 0 |
| Timeouts / HTTP errors / provider errors | 1/0/0 | 0/0/0 | 0/0/0 |
| Output-limit stops | 0 | 0 | 0 |

All-attempt medians include early failures. Successful-only medians cover different task mixes and are not a matched speed comparison. Generation speed is total reported generated tokens divided by total reported generation time; engine timing definitions and model tokenizers differ, and unfinished requests without final usage are excluded for oMLX.

| Task | K2 / oMLX low | K2 / oMLX medium | Qwen / llama.cpp thinking |
|---|---|---|---|
| multi-rechnungen | 48.3 s; ✗ ✗ ✗ | 137.5 s; ✗ ✗ ✗ | 50.7 s; ✗ ✗ ✗ |
| vergleich | 96.3 s; ✗ ✗ ~ | 67.4 s; ✓ ✓ ✓ | 37.9 s; ✓ ✓ ✓ |
| zusammenfassen | 16.5 s; ✓ ~ ~ | 32.4 s; ~ ~ ~ | 26.7 s; ✓ ~ ~ |
| ordner-ueberblick | 55.4 s; ✗ ~ ✗ | 93.1 s; ✓ ~ ~ | 11.8 s; ~ ✓ ✓ |
| web-recherche | 10.0 s; ✗ ✗ ✗ | 53.4 s; ✗ ~ ✗ | 19.8 s; ✓ ✓ ✓ |
| web-plus-datei | 16.1 s; ✗ ~ ~ | 70.6 s; ~ ~ ~ | 20.8 s; ~ ~ ~ |
| mail-antwort | 11.9 s; ✗ ~ ~ | 41.9 s; ~ ~ ~ | 27.0 s; ✓ ✗ ~ |
| termin | 10.9 s; ✓ ✓ ✗ | 27.2 s; ✓ ✗ ✓ | 23.6 s; ✓ ✓ ✓ |
| en-multi | 38.7 s; ✗ ✗ ✗ | 102.4 s; ✗ ✓ ~ | 82.0 s; ✗ ✗ ✗ |
| en-summary | 15.8 s; ~ ~ ~ | 29.6 s; ~ ~ ~ | 26.1 s; ~ ✓ ~ |

Times are medians of the repeats. Symbols show manual quality grades in round order: ✓ complete, ~ partial, ✗ failed.
