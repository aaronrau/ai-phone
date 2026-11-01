# Android AI Receptionist repository instructions

## On-device only

The app must work with no internet or server connection. Never add the
INTERNET permission to the main or release manifest (the Flutter debug
manifest keeps it only for tooling), and never add remote inference, telemetry
or a network dependency to the call, SMS or agent paths. Downloads happen only
on the computer, in `tool/` scripts, at build or provisioning time.

## Privacy and pre-push gate

Before every commit and push, inspect the staged diff and new files for
personal information. Never commit a real name, phone number, email address,
contact list, calendar item, transcript, recording, screenshot, device serial,
home-directory path or private configuration. Use generic values such as
`+15555550100`, `Sam`, `<android-serial>` and `developer@example.invalid`.

- Commit only `config/receptionist.example.json`; the live configuration stays
  in app-private storage.
- Personal test values (phone numbers, Vapi IDs, call reports, screenshots)
  live outside the repo (e.g. `~/.cache/android-ai-receptionist/state/`) or in
  the ignored `private/` folder; tools read them from there.
- Model weights, native libraries and APKs never enter Git.
- Use the commit identity `Work Bench Contributors <noreply@workbench.invalid>`.

At minimum run:

```sh
git status --short
git diff --cached --check
git grep -I -n -E '(/home/[^/[:space:]]+|/Users/[^/[:space:]]+)'
git grep -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
git grep -I -n -E '\+?[0-9][0-9 ()-]{8,}[0-9]'
```

Review every match; only generic or public values may remain.

## Android build numbering

Increment the build suffix in `pubspec.yaml` before every invocation that
produces an APK or app bundle, including validation rebuilds and retries, and
commit the incremented value. After installing, verify the phone reports the
expected `versionCode`.

## Behaviour contracts

- Blocked callers are rejected before ringing. Texts are answered (and
  notified) only for known contacts; short codes never get replies and SMS
  replies are rate limited per number.
- The contact book is private, app-local data; keep its prompt context limited
  to the caller being served and never put it in logs, exports or Git.
- The model's output is always grammar-constrained JSON
  (`{"say": ..., "tool": ...}`); keep `buildGrammar` and the tool argument
  lists in sync, and cover new tools in `test/receptionist_test.dart`.
- Calendar items reveal their title/notes only when `share_details` is true;
  phone-calendar events are busy-only.
- Never log transcript or message text in release builds (`kDebugMode` only).
- Use calendar-date construction (`DateTime(y, m, d + n)`), never
  `Duration(days: n)`, for day arithmetic; the latter breaks across DST.
- A live call owns the language model; texts wait until the call ends.

## Call audio

- The working call path is the shell-user helper (`ShellCallAudio`) plus the
  shell-only `CallAudioProvider`. Keep the provider protected by `DUMP` and the
  `Binder.getCallingUid()` check; never expose call audio to other apps.
- Uplink audio must be 8/16/32/48 kHz (the HAL `in_call_music` profile);
  Pocket renders 24 kHz, so the helper upsamples to 48 kHz.
- Never silence an allowed call unless the receptionist can actually converse
  (helper connected); otherwise let it ring.
- Restart the helper after every app reinstall: it runs code from the APK path.

## Physical validation

Before accepting audio or call changes, run speaker mode on a real phone (the
Test tab or the debug `speaker_start` command) and, for call changes, a real
incoming call (`tool/vapi_test_call.py` places one and returns the caller-side
transcript). Never commit API keys, Vapi IDs or phone numbers; keep them in
`.env` or private files outside the repository. Report STT, LLM and TTS timings separately, and keep failures
in the report alongside passes.
