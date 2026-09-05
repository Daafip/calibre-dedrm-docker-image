# libgourou Adobe ID / ByteBooks Migration Plan

Latest upstream impact: the libgourou change is documentation-only, not an API/CLI change. This repository still calls `adept_activate -u ... -p ...`, and that flow should remain valid — but for **new activations** the credentials are now a **ByteBooks account**, not an Adobe ID.

## What this means for this repository

- **No immediate pipeline rewrite is needed.**
  - `ha-addon/run.sh` still uses the right libgourou commands.
  - The build does not appear to depend on any changed libgourou API.
- **The user-facing contract is now misleading.**
  - `ha-addon/config.yaml` still exposes `adobe_email` / `adobe_password`.
  - `ha-addon/run.sh` logs “Activating device with Adobe ID”.
  - `README.md`, `ha-addon/README.md`, `CHANGELOG.md`, and `NOTES.md` all tell users to use Adobe ID.
- **Existing activations likely continue to work.**
  - The break is mainly for first-time activation or after `/data/adept/` is reset.

## Recommended execution plan

1. **Update the docs first**
   - Replace “Adobe ID” guidance with “ByteBooks account for new activations”.
   - Explicitly say existing persisted activations in `/data/adept/` should continue to work.
   - Add a short migration note: users who reset activation or set up a fresh instance must use ByteBooks credentials.

2. **Fix runtime messaging**
   - Change startup logs and warnings in `ha-addon/run.sh` so they no longer instruct users to enter Adobe ID credentials.
   - Make failure messages point users toward ByteBooks for new activations.

3. **Decide how to handle config naming**
   - Best low-risk option: keep `adobe_email` / `adobe_password` for backward compatibility, but document them as “ByteBooks email/password for new activations”.
   - Better UX option: add neutral aliases such as `activation_email` / `activation_password` or `bytebooks_email` / `bytebooks_password`, while still accepting the old names.
   - Avoid a hard rename without a compatibility path, because that will break existing Home Assistant add-on configs.

4. **Update Home Assistant add-on schema and help text**
   - In `ha-addon/config.yaml`, revise comments and descriptions to reflect ByteBooks.
   - If aliases are added, update parsing in `ha-addon/run.sh` to prefer new fields and fall back to old ones.

5. **Add troubleshooting guidance**
   - Document the new likely failure mode: users entering old Adobe ID credentials on a fresh activation.
   - Explain that deleting `/data/adept/` forces a fresh activation and therefore now requires ByteBooks credentials.

6. **Pin libgourou**
   - `ha-addon-base/Dockerfile` currently clones libgourou from HEAD.
   - Pin to a known tag or commit, at minimum the version that includes this warning, so future upstream auth changes do not silently alter builds.

7. **Regression-check local flows**
   - Validate first-run activation messaging.
   - Validate existing activated state still skips activation.
   - If config aliases are added, verify both old and new option names work.

## Summary

This looks like a **docs, UX, and backward-compatibility update**, not a libgourou integration rewrite.
