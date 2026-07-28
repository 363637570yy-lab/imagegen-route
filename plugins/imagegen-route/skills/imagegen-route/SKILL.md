---
name: imagegen-route
description: "Route Codex's bundled image-generation CLI through the active custom provider in config.toml while sourcing OPENAI_API_KEY only from the local Codex auth store, validating the route, preserving argument boundaries, and redacting sensitive output. Use when the user explicitly invokes $imagegen-route, explicitly requests the custom CLI/API/model path, or requests path-only project or batch image delivery through their configured provider. Do not use for ordinary built-in image generation."
---

# ImageGen Route

Use the bundled PowerShell wrapper to run Codex's installed image-generation CLI through the user's selected custom provider. Keep credentials and provider configuration local to the user's machine.

## Requirements

- Run on Windows with PowerShell 7 or newer and Python 3.11 or newer.
- Require an installed Codex `imagegen` system skill containing `scripts/image_gen.py`.
- Require the user's own `config.toml` and `auth.json` under their resolved `CODEX_HOME`.
- Treat this skill as an explicit custom-route workflow. Leave ordinary image requests on the built-in `image_gen` path.

## Security Rules

- Invoke only `scripts/invoke_codex_imagegen.ps1` from this skill. Never call the bundled Python CLI directly and never create an ad-hoc SDK runner.
- Never ask the user to paste a credential into a prompt, command, file, log, or chat message.
- Never print, copy, commit, or modify `auth.json`, `config.toml`, `.env`, bearer tokens, API keys, authorization headers, or authenticated proxy URLs.
- Never persist `OPENAI_API_KEY` or `OPENAI_BASE_URL` in the parent process, user environment, or machine environment.
- Do not silently switch provider, endpoint, credential source, model, or API path.
- Refuse the public OpenAI endpoint and the `openai` or `default` provider names. This workflow requires an explicitly selected custom provider.
- Preserve every forwarded argument as a distinct process argument. Do not rebuild the command as one interpolated shell string.

## Workflow

1. Resolve the absolute directory containing this `SKILL.md` and set the wrapper path to `scripts/invoke_codex_imagegen.ps1` beneath it.
2. Run the route preflight before the first CLI operation in the task:

   ```powershell
   pwsh -NoProfile -File "<skill-root>\scripts\invoke_codex_imagegen.ps1" --check-route
   ```

3. Continue only when preflight exits with code `0`. On failure, report the wrapper's redacted error and stop. Do not retry against another provider or credential source.
4. Choose one supported command: `generate`, `edit`, or `generate-batch`.
5. Run a `--dry-run` first when the selected command supports it. A dry run validates arguments and output paths without making an image API request.
6. Run the live command only after the dry-run output matches the request and destination.
7. Validate outputs locally by decoding them and recording path, format, dimensions, byte size, and SHA256. Do not render images inline unless the user explicitly requests visual inspection.

## Command Patterns

Generate one image:

```powershell
pwsh -NoProfile -File "<wrapper>" generate `
  --prompt "<prompt>" `
  --size 1024x1024 `
  --quality medium `
  --out "output/imagegen/<name>.png"
```

Edit one or more images:

```powershell
pwsh -NoProfile -File "<wrapper>" edit `
  --image "<source.png>" `
  --prompt "<edit instructions and invariants>" `
  --out "output/imagegen/<name>-edited.png"
```

For multiple edit inputs, repeat `--image` in meaningful order and identify each image's role by index in the prompt.

Run a JSONL batch:

```powershell
pwsh -NoProfile -File "<wrapper>" generate-batch `
  --input "tmp/imagegen/prompts.jsonl" `
  --out-dir "output/imagegen/batch" `
  --concurrency 5
```

Use `tmp/imagegen/` for scratch inputs and `output/imagegen/` for final files. Do not overwrite existing outputs unless the user explicitly requests replacement; otherwise choose a versioned sibling name.

## Model And Media Rules

- Keep the installed CLI's default model unless the user explicitly selects another model.
- Never silently downgrade from `gpt-image-2` to `gpt-image-1.5`.
- Do not use `--background transparent` with `gpt-image-2`.
- Use `gpt-image-1.5 --background transparent --output-format png` only after the user explicitly requests or confirms true model-native transparency.
- Never downscale or re-encode a source image that will be passed to the model. A reduced copy is review-only and must never become a model reference.
- Preserve source order, masks, and edit invariants exactly. Do not promise pixel-perfect mask boundaries.
- Treat HTTP `413 Payload Too Large` as terminal for that request. Do not retry the same payload or silently reduce reference images; write a checkpoint and report the failure.

## Failure Handling

- Missing route, missing auth key, invalid HTTPS endpoint, changed config snapshot, missing bundled CLI, or unavailable Python: stop and return the wrapper's actionable redacted error.
- Existing destination: choose a new path unless `--force` was explicitly requested.
- Unsupported command or option: inspect the installed CLI's `--help`; do not invent flags.
- Child-process failure: preserve the nonzero exit code and report only the wrapper-sanitized output.
