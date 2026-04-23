# MoE Benchmark for llama.cpp

> ⚠️ **Work in Progress** — this project is actively under development and may change without notice.

This project automates finding optimal **Mixture-of-Experts (MoE)** configurations for llama.cpp models and runs performance benchmarks — all with a single command.

## 🎯 Goal

For MoE models, the `--n-cpu-moe` parameter controls how many experts are executed on the CPU. The right value depends on the GPU, model, and quantization. This project:

1. **Finds** the best `--n-cpu-moe` value for each **ubatch** size (`-ub`, physical maximum batch size)
2. **Benchmarks** the found configuration with `llama-bench` across various prompt processing lengths

## 📂 Project Structure

```
benchmarking/
├── run_moe_benchmark.sh      # Main script — orchestrates the entire workflow
├── find_moe.sh               # Step 1 — Finds optimal MoE values
├── benchmark_workload        # Step 2 — Runs llama-bench
└── README.md
```

### Dependencies

- **llama.cpp** (`llama-server` and `llama-bench` must be in PATH)
- **hyperfine** (benchmarking tool)
- **CUDA-capable GPU** (nvidia-smi accessible)
- Bash 4+

## ⚡ Quick Start

```bash
bash run_moe_benchmark.sh <model-path> [min-context]
```

### Example

```bash
# Default parameters (CTX=128000, CTV=f16, CTK=f16)
bash run_moe_benchmark.sh bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q4_XS

# With custom context and quantization
bash run_moe_benchmark.sh my-model:Q5_K_M -ctx 8192 -ctv q5_k_m -ctk q5_k_m
```

### Full Parameters

| Parameter | Description | Default |
|---|---|---|
| `<model-path>` | HF model path, e.g. `bartowski/Qwen3.6-35B:Q4_XS` | *Required* |
| `[min-context]` | Minimum context length the model should support | `128000` |
| `-ctx <ctx>` | Minimum context length (alternative syntax) | `128000` |
| `-ctv <quant>` | KV cache quantization | `f16` |
| `-ctk <quant>` | Token quantization | `f16` |
| `--debug` | Verbose logging | off |

## 🔍 Detailed Guide

### Step 1: Find Optimal MoE Values (`find_moe.sh`)

This script systematically tests different `--n-cpu-moe` values (50 down to 0) for each **ubatch** size (`-ub`, physical maximum batch size) and determines the threshold where context size drops below the minimum.

**Tested `-ub` values:** 4096, 3072, 2048, 1024, 512

**How it works:**
1. For each `-ub` size, tests `--n-cpu-moe` from 50 downward
2. Each test starts `llama-server` briefly and reads `n_seq_max` / `n_ctx` from the log
3. Once `n_ctx` drops below the minimum, the previous value is the best
4. Results are written to `"<model-name>_results.txt"`

**Result format:**
```
-ub=4096  --n-cpu-moe=32  n_ctx=100000
-ub=2048  --n-cpu-moe=48  n_ctx=100000
```

### Step 2: Run Benchmark (`benchmark_workload`)

Using the found MoE values, `llama-bench` is run via `hyperfine` across various prompt processing lengths.

**Tested PP values:** 96000, 64000, 32000, 16000, 8000, 4000, 2000, 1000, 500  
(Filtering to values ≤ the requested context length)

**Ubatch Value to Model Identifier Mapping:**

| `--ub*-moe` Flag | `-ub` Value | Model Identifier |
|---|---|---|
| `--ub0.5-moe` | 512 | ub512_moe |
| `--ub1-moe` | 1024 | ub1024_moe |
| `--ub2-moe` | 2048 | ub2048_moe |
| `--ub3-moe` | 3072 | ub3072_moe |
| `--ub4-moe` | 4096 | ub4096_moe |

### Automated Workflow (`run_moe_benchmark.sh`)

The main script combines both steps:

1. Calls `find_moe.sh` and saves the results
2. Parses the result file and extracts optimal MoE values
3. Starts `benchmark_workload` with all found values (both `-b` and `-ub` set to the same ubatch size)
4. Prints a summary

## 📊 Output

After the run completes, two result files are created:

| File | Format | Content |
|---|---|---|
| `<model>_results.txt` | Text | Found optimal MoE values per UB size |
| `<model>_benchmark_results.md` | Markdown | Hyperfine benchmark results with timing data |
| `<model>_benchmark_results.md-token-generation-results` | Text/Raw | Token generation results |

## 🧪 Debugging

```bash
# Full run with debug logging
bash run_moe_benchmark.sh bartowski/Qwen3.6-35B:Q4_XS --debug

# Run step 1 manually
bash find_moe.sh bartowski/Qwen3.6-35B:Q4_XS 8192 --debug
```

## ⚠️ Notes

- **GPU Memory:** The script requires a CUDA GPU. Insufficient VRAM means some UB values may yield no valid MoE value.
- **Clean Shutdown:** `find_moe.sh` registers trap handlers that cleanly kill all started `llama-server` processes on abort.
- **Model Path:** The format `<provider>/<model>:<quant>` is used to generate output filenames.
