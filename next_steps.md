# Next Steps — parked designs

## 1. Tune My Voice (mlx-tune drift killer) — top priority when resumed

The point: a voice that stays *your voice* across every clip of a long
narration. Reference-audio cloning drifts; fine-tuning bakes the voice
into the weights so each take is consistent.

**Research findings (2026-09-02):**
- [mlx-tune](https://github.com/ARahim3/mlx-tune) (Apache-2.0, unsloth-mlx
  successor, PyPI v0.6.0) fine-tunes Qwen3-TTS on Apple Silicon via LoRA
  (r=16, alpha=16, attention+MLP targets, 28-layer talker).
- Official example: https://github.com/ARahim3/mlx-tune/blob/main/examples/20_qwen3_tts_finetuning.py
  — dataset of paired `audio` + `text` at 24 kHz; demo trains on 10 samples;
  saves adapters, and `save_pretrained_merged` produces a full model dir
  (merged_16bit dequantizes + fuses). The merged dir is what our Swift
  runtime can load (mlx-audio-swift loads model directories, not adapters).
- Hardware: 16 GB+ recommended; the M4 Max / 36 GB target machine is
  comfortable. Expect ~20–60 min per voice for a few hundred steps.
- Training base should be `Qwen3-TTS-12Hz-1.7B-Base` (our cloning
  checkpoint). Resolve empirically: 8bit base + merged_16bit, or bf16 base.

**Design (v1):**
1. **Guided recording** — ~25 short phoneme-rich prompts shown one at a
   time; record/re-record each. Transcripts are known by construction (the
   user reads displayed text), so no ASR errors and no alignment work.
   Pairs stored under `~/Library/vos2026/voice-tuning/`.
   Phase 2: drop-in voice memos auto-transcribed with the local ASR stack
   (Qwen3ASR / Parakeet already in mlx-audio-swift).
2. **Training sidecar** — managed uv venv under `~/Library/vos2026/tuner/`
   with `mlx-tune[audio]` (installed once on first use; also needs ffmpeg).
   The app writes the dataset + a generated training script, runs it as a
   subprocess, streams stdout for progress, supports cancel. Output: merged
   model under `~/Library/vos2026/tuned-voices/<Name>/`.
3. **Loading** — TTSService gains local-directory model loading; the tuned
   voice appears in the voice picker like any preset. No reference audio at
   generation time — the voice is in the weights.
4. Everything stays local.

**First step when resumed:** sidecar proof-of-concept — train a tiny LoRA
on a handful of app-generated samples and load the merged result back into
the Swift runtime end-to-end. That de-risks the two unknowns (training
base compatibility, merged-dir layout) before any UI is built.

**Engineering unknowns:** whether mlx-tune accepts the 8bit Base directly
or needs bf16; exact merged directory layout vs what Qwen3TTSModel expects;
whether the speech tokenizer/codec files need copying into the merged dir.

## 2. Chatterbox A/B (parked)

- Chatterbox-Turbo (MIT, 350M) rated best zero-shot cloning in blind tests;
  mlx-community quants exist for Python mlx-audio, not for the Swift port.
- Plan: sidecar Python mlx-audio CLI, generate the same lines with the
  reference sample on both 1.7B-Base and Chatterbox-Turbo-4bit, blind
  compare. If Chatterbox clearly wins for the target voice: port to Swift
  or shell out permanently.
- Revisit after Tune My Voice — a fine-tune may make the comparison moot.

## 3. Watchlist

- CosyVoice 3.0 / MOSS-TTS v1.5 if MLX ports land.
- Qwen3-TTS 25 Hz checkpoints when released.
- `delete project` scripting verb (the clip manager covers clips; projects
  still accumulate — see the Smoke-project cleanup dance).
