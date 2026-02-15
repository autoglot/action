# Autoglot GitHub Action

Automatically translate your Xcode String Catalogs (`.xcstrings`) and web localization files (JSON, YAML) and create a PR with the results.

## How It Works

```
YOUR REPO                                    AUTOGLOT
─────────────────────────────────────────    ────────────────────────────────────

1. Push translation file changes
        │
        ▼
2. GitHub Action runs ─────────────────────▶ 3. Receives files & queues translation
   (this workflow)                                      │
        │                                               ▼
        ▼                                    4. Translates your strings
3. Action exits                                 (typically minutes)
   (no CI cost)                                         │
                                                        ▼
                                             5. Creates PR or commits to branch
                                                (using GitHub App or PAT)
                                                        │
                                                        ▼
                                             6. You review & merge
```

**Key points:**
- This workflow **triggers** the translation (you need to add it to your repo)
- The GitHub App **creates the PR** (install it, or provide a PAT)
- Translation happens **asynchronously** on our servers (no CI minutes wasted)

## Setup

### Step 1: Get an API Key

1. Sign up at [autoglot.app](https://autoglot.app)
2. Go to [Dashboard → API Keys](https://autoglot.app/dashboard/api-keys)
3. Create a key and add it to your repo secrets as `AUTOGLOT_API_KEY`

### Step 2: Enable PR Creation

**Option A: Install GitHub App (Recommended)**

1. Go to [Dashboard → GitHub](https://autoglot.app/dashboard/github)
2. Click "Install GitHub App"
3. Select your repository
4. Done! No tokens to manage.

**Option B: Use a Personal Access Token**

1. [Create a Fine-Grained PAT](https://github.com/settings/tokens?type=beta) with:
   - Repository access: your repo
   - Permissions: `Contents: write`, `Pull requests: write`
2. Add it to your repo secrets as `AUTOGLOT_PAT`
3. Add `github-token: ${{ secrets.AUTOGLOT_PAT }}` to your workflow

### Step 3: Add the Workflow

Create `.github/workflows/translate.yml` in your repo:

```yaml
name: Translate

on:
  push:
    branches: [main]
    paths:
      - '**/*.xcstrings'
  workflow_dispatch:  # Allows manual trigger

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: autoglot/action@v2
        with:
          api-key: ${{ secrets.AUTOGLOT_API_KEY }}
          languages: "de,fr,ja,es,zh-Hans"
          # github-token: ${{ secrets.AUTOGLOT_PAT }}  # Only if not using GitHub App
```

That's it! Push a change to any `.xcstrings` file and a PR will appear within minutes.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | - | Your Autoglot API key |
| `languages` | Yes | - | Comma-separated target languages (e.g., `de,fr,ja`) |
| `github-token` | No | - | PAT for PR creation. Not needed if GitHub App is installed |
| `paths` | No | `""` | Paths to search for translation files. Finds all `.xcstrings` if empty |
| `output-mode` | No | `create-pr` | `create-pr` creates a new PR, `commit-to-branch` commits to existing PR branch |
| `head-branch` | No | PR branch | Branch to commit to (auto-detected in PR context) |
| `branch-name` | No | `autoglot/translations` | Branch name for new PRs |
| `base-branch` | No | `main` | Base branch for the PR |
| `commit-message` | No | `chore(i18n): update translations` | Commit message |
| `pull-request-title` | No | `chore(i18n): update translations` | PR title |

## Outputs

| Output | Description |
|--------|-------------|
| `job-id` | Job ID for tracking progress |

## Supported File Formats

| Format | Extension | Notes |
|--------|-----------|-------|
| Xcode String Catalog | `.xcstrings` | Native iOS/macOS localization |
| JSON | `.json` | Web apps (i18next, etc.) |
| YAML | `.yml`, `.yaml` | Rails i18n, etc. |
| PO/POT | `.po`, `.pot` | GNU gettext |

For web formats, autoglot automatically finds source language files (`en.json`, `en.yml`) and generates translations for each target language.

## Supported Languages

| Code | Language | Code | Language |
|------|----------|------|----------|
| `de` | German | `ja` | Japanese |
| `fr` | French | `ko` | Korean |
| `es` | Spanish | `zh-Hans` | Simplified Chinese |
| `it` | Italian | `zh-Hant` | Traditional Chinese |
| `pt` | Portuguese | `ar` | Arabic |
| `pt-BR` | Brazilian Portuguese | `he` | Hebrew |
| `nl` | Dutch | `hi` | Hindi |
| `pl` | Polish | `th` | Thai |
| `ru` | Russian | `vi` | Vietnamese |
| `uk` | Ukrainian | `id` | Indonesian |
| `tr` | Turkish | `ms` | Malay |
| `sv` | Swedish | `cs` | Czech |
| `da` | Danish | `hu` | Hungarian |
| `fi` | Finnish | `ro` | Romanian |
| `nb` | Norwegian | `sk` | Slovak |
| `el` | Greek | `bg` | Bulgarian |

## Examples

### iOS: Translate on Push to Main

```yaml
name: Translate

on:
  push:
    branches: [main]
    paths:
      - '**/*.xcstrings'

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: autoglot/action@v2
        with:
          api-key: ${{ secrets.AUTOGLOT_API_KEY }}
          languages: "de,fr,ja"
```

### Web: Translate JSON on PR

Translate web localization files and commit directly to the PR branch:

```yaml
name: Translate Web

on:
  pull_request:
    paths:
      - "src/locales/**"

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: autoglot/action@v2
        with:
          api-key: ${{ secrets.AUTOGLOT_API_KEY }}
          paths: "src/locales"
          languages: "de,fr,es,ja"
          output-mode: commit-to-branch
          commit-message: "chore(i18n): update translations"
```

### Weekly Translation Sync

```yaml
name: Weekly Translation Sync

on:
  schedule:
    - cron: '0 9 * * 1'  # Every Monday at 9 AM UTC
  workflow_dispatch:

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: autoglot/action@v2
        with:
          api-key: ${{ secrets.AUTOGLOT_API_KEY }}
          languages: "de,fr,es,ja,ko,zh-Hans"
```

### Custom Branch and PR Settings

```yaml
- uses: autoglot/action@v2
  with:
    api-key: ${{ secrets.AUTOGLOT_API_KEY }}
    languages: "de,fr,ja"
    branch-name: "i18n/translations"
    base-branch: "develop"
    commit-message: "feat(i18n): add translations"
    pull-request-title: "Add German, French, and Japanese translations"
```

## FAQ

### How long does translation take?

Typically minutes. The action submits the job and exits immediately - no CI minutes wasted waiting.

### Will it overwrite my existing translations?

No. Autoglot only translates strings that don't have translations yet. Existing translations are preserved.

### Why can't I use GITHUB_TOKEN?

The default `GITHUB_TOKEN` only works within the GitHub Actions runner. Since Autoglot creates PRs asynchronously from our servers (after the action completes), we need either:
- The Autoglot GitHub App (recommended)
- A Personal Access Token

### What if the job fails?

Check the job status at [autoglot.app/dashboard/activity](https://autoglot.app/dashboard/activity). Failed jobs include error messages.

### Can I trigger translation manually?

Yes! Add `workflow_dispatch` to your workflow triggers, then use the "Run workflow" button in GitHub Actions.

## Links

- [Autoglot Dashboard](https://autoglot.app/dashboard)
- [Get API Key](https://autoglot.app/dashboard/api-keys)
- [Install GitHub App](https://autoglot.app/dashboard/github)
- [Report Issues](https://github.com/autoglot/action/issues)
