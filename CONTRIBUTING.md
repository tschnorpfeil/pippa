# Contributing

Thanks for helping. Pippa is for people who never open Terminal, so every change is judged by one question: does it make Pippa easier or safer for them?

- **Open an issue first** for anything larger than a fix, so we can agree on the approach before you write code.
- **Prefer Pi packages, skills and extensions over own code.** A capability Pi can get from a maintained package or a skill should come from there; Pippa's own code is for the macOS side and the interface. What Pippa does keep goes into code with a check, not into prompts.
- **Every UI text exists in English and German.** English is the development language; add the German translation in the matching `de.lproj` table.
- **Run the checks before you send a pull request:**

  ```sh
  swift run --package-path app PippaChecks
  python3 scripts/check-strings.py
  node --experimental-strip-types --test runtime/pippa-tools/*.test.mjs
  ```

  If you touched packaging, also run `scripts/build-app.sh && scripts/verify-app.sh`.
- **No real personal data** in fixtures, logs or screenshots. Test files are made up (`scripts/create-usability-fixtures.py`).

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
