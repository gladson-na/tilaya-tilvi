# Tilda
- backend/  Python API: fallback chain of speech engines + greeting detection (tests included)
- app/      Flutter app for Android and Windows (one codebase)
- .github/workflows/build.yml  builds the Android APK and the Windows app in the cloud
- .coderabbit.yaml  settings for the CodeRabbit reviewer
No keys in code. Put keys in environment variables (SARVAM_API_KEY).

## Run it in one command
    docker compose up
Open http://localhost:8000. No keys are needed to start: the page shows a "key not set" note until you add `SARVAM_API_KEY` or `GROQ_API_KEY` (copy `.env.example` to `.env`). Set `TILDA_FAKE=1` for sample answers with no key at all.
