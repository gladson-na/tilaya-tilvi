# Tilda
- backend/  Python API: fallback chain of speech engines + greeting detection (tests included)
- app/      Flutter app for Android and Windows (one codebase)
- .github/workflows/build.yml  builds the Android APK and the Windows app in the cloud
- .coderabbit.yaml  settings for the CodeRabbit reviewer
No keys in code. Put keys in environment variables (SARVAM_API_KEY).

## Run it in one command
    docker compose up
Open http://localhost:8000. No keys are needed to start: the page shows a "key not set" note until you add `SARVAM_API_KEY` or `GROQ_API_KEY` (copy `.env.example` to `.env`). Set `TILDA_FAKE=1` for sample answers with no key at all.

## Build timeline

The first commit in this repo is dated 15 Nov 2026. Everything below is visible in the commit history.

**Before Round 2 opened (15 to 26 Nov 2026)**
- 15 Nov: project started. Voice dictation in Indian languages, free hosting setup (Dockerfile and Render blueprint).
- 16 Nov: Translator (speak in one language, hear it in another). Floating bubble that dictates over any app.
- 18 Nov: Talk agent (spoken answers, automatic turn-taking).
- 25 to 26 Nov: live word-by-word typing, the redesigned app (Talk, Notes, Translate with animations), complaints and suggestions delivered by Telegram.

**After Round 2 opened (27 Nov 2026, 00:00 IST onward)**
- Docker one-command start with no keys, tested in the build.
- Talk noise fix (ignores fan and room noise).
- Capture: live in-app camera reads text in a photo, translates it and speaks it. Offline reading for Hindi and English.
- Notes and Capture photos saved on the phone, with a Saved list. Summary retry.
- Call-words: choose how you call Tilda (Hey, Ae, Oye, O, Arre, Suno, Ok), practise, and Tilda learns your accent.
- Live web answers in Talk.
- New smooth 2D orb. Screen fills the camera hole.
- Automatic tests that install and open the app on Android 7, 8, 10, 13 and 14.
