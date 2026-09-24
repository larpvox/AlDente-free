# Notes for Claude

- Never add a `Claude-Session:` line to commit messages or PR descriptions.
- Bump `VERSION` in any commit that changes the app. The in-app updater only
  offers an update when the `VERSION` on GitHub is higher than the installed
  one.
- `BatteryScope.zip` is rebuilt by `.github/workflows/zip.yml` on every push to
  the default branch. Running `./make.sh zip` locally before committing is still fine; the
  output is reproducible, so CI won't re-commit an identical zip.
