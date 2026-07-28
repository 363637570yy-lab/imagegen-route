# ImageGen Route

`imagegen-route` is a Codex plugin for explicitly routing the bundled image-generation CLI through the custom provider selected in the user's local Codex configuration.

It validates the route, reads the image API key only from the local Codex auth store, injects the endpoint and key only into the child process, and redacts credentials and large Base64 payloads from child output.

## What It Does

```text
$imagegen-route
  -> route preflight
  -> local config.toml: selected provider + HTTPS base_url
  -> local auth.json: OPENAI_API_KEY
  -> child-only OPENAI_BASE_URL and OPENAI_API_KEY
  -> bundled imagegen/scripts/image_gen.py
```

The plugin does not contain credentials, provider URLs, generated images, or a copy of the bundled Python image-generation CLI.

## Requirements

- Windows
- Codex with the built-in `imagegen` skill installed
- PowerShell 7 or newer (`pwsh`)
- Python 3.11 or newer
- An explicitly selected custom provider in the user's own Codex configuration
- The user's own image API credential in the normal Codex auth store

This route intentionally rejects `api.openai.com` and provider names `openai` or `default`. Use ordinary Codex image generation for the built-in public route.

## Install

Clone or download this repository, then register its repo-local marketplace:

```powershell
codex plugin marketplace add "C:\path\to\imagegen-route"
codex plugin add imagegen-route@imagegen-route-lab
```

Start a new Codex task after installation so the new plugin is loaded. Invoke it explicitly:

```text
Use $imagegen-route to validate my configured image provider.
```

The skill is explicit-only and does not replace the built-in `imagegen` skill.

## Local Provider Setup

Keep provider and credential setup outside this repository. The wrapper reads:

- `model_provider` from the user's `config.toml`
- `base_url` and optional `wire_api` from the selected `model_providers.<name>` table
- `OPENAI_API_KEY` only from the user's local `auth.json`

A provider table has this general shape; use the values supplied by the provider:

```toml
model_provider = "custom"

[model_providers.custom]
name = "Custom provider"
base_url = "https://provider.example/v1"
wire_api = "responses"
```

Do not commit `config.toml`, `auth.json`, `.env`, bearer tokens, API keys, or authenticated proxy URLs. The wrapper deliberately ignores inline bearer-token fields and does not persist credentials in user or machine environment variables.

## Route Preflight

To test the checked-out wrapper directly:

```powershell
pwsh -NoProfile -File ".\plugins\imagegen-route\skills\imagegen-route\scripts\invoke_codex_imagegen.ps1" --check-route
```

Success prints only the selected provider name and confirms that the endpoint is HTTPS. It does not print the endpoint or credential.

## Dry Run

Validate CLI arguments and output paths without calling the image API:

```powershell
pwsh -NoProfile -File ".\plugins\imagegen-route\skills\imagegen-route\scripts\invoke_codex_imagegen.ps1" generate `
  --prompt "Test image" `
  --size 1024x1024 `
  --out "output/imagegen/test.png" `
  --dry-run
```

Supported forwarded commands are `generate`, `edit`, and `generate-batch`. Run `--check-route` before the first operation in each task.

## Security Boundaries

- No automatic fallback to another provider, endpoint, credential source, or image model
- No direct invocation or modification of the bundled `image_gen.py`
- No persistent credential environment variables
- No credential, authorization-header, or large Base64 output in diagnostics
- No source-image downscaling or re-encoding before model submission
- No retry of the same payload after HTTP 413

## Repository Layout

```text
.agents/plugins/marketplace.json
plugins/imagegen-route/.codex-plugin/plugin.json
plugins/imagegen-route/skills/imagegen-route/SKILL.md
plugins/imagegen-route/skills/imagegen-route/agents/openai.yaml
plugins/imagegen-route/skills/imagegen-route/scripts/invoke_codex_imagegen.ps1
```
