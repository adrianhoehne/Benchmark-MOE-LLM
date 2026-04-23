#!/bin/bash
# -----------------------------------------------------------
# run_moe_benchmark.sh
# 1) find_moe.sh  →  finde optimale --n-cpu-moe Werte pro UB
# 2) benchmark_workload  →  benchmarke mit den gefundenen Werten
# -----------------------------------------------------------
set -euo pipefail

MODEL=""
CTX="98304"
DEBUG=0
CTV="q8_0"
CTK="q8_0"
while [ $# -gt 0 ]; do
    case "$1" in
        --debug) DEBUG=1; shift ;;
        -ctx) CTX="${2:-98304}"; shift 2 ;;
        -ctv) CTV="${2:-q8_0}"; shift 2 ;;
        -ctk) CTK="${2:-q8_0}"; shift 2 ;;
        *)
            if [ -z "$MODEL" ]; then
                MODEL="$1"
            elif [ "$CTX" = "98304" ]; then
                CTX="$1"
            fi
            shift ;;
    esac
done

if [ -z "$MODEL" ]; then
    echo "Usage: $0 <model-hf-path> [-ctx <context>] [-ctv <quant>] [-ctk <quant>] [--debug]"
    echo ""
    echo "  model-hf-path   z.B. bartowski/Qwen_Qwen3.6-35B-A3B-GGUF:Q4_XS"
    echo "  -ctx <ctx>      optional: minimaler Kontext den das Modell haben soll (default: 98304)"
    echo "  -ctv <quant>    optional: KV-Quant (default: q8_0)"
    echo "  -ctk <quant>    optional: Token-Quant (default: q8_0)"
    echo "  --debug         optional: verbose logging"
    exit 1
fi
RESULTS_FILE=$(basename "$MODEL" | cut -d: -f1)_results.txt

echo "=============================================="
echo "  Step 1: find_moe — optimale Werte suchen"
echo "=============================================="
echo "  MODEL     = $MODEL"
echo "  CTX       = $CTX"
echo "  DEBUG     = $DEBUG"
echo "  CTV       = $CTV"
echo "  CTK       = $CTK"
bash "$(dirname "$0")/find_moe.sh" "$MODEL" "$CTX" -ctv "$CTV" -ctk "$CTK" $([ "$DEBUG" -eq 1 ] && echo "--debug" || true)

if [ ! -f "$RESULTS_FILE" ]; then
    echo "ERROR: $RESULTS_FILE wurde nicht erstellt."
    exit 1
fi

echo ""
echo "=============================================="
echo "  Ergebnis von find_moe:"
echo "=============================================="
cat "$RESULTS_FILE"
echo ""

# ---------- Parse the results file ----------
declare -A UB_MOE

while IFS= read -r line; do
    # Expected format: -ub=VALUE  --n-cpu-moe=MOE  n_ctx=NCTX
    if [[ "$line" =~ ^-ub=([0-9]+) ]]; then
        ub="${BASH_REMATCH[1]}"
        if [[ "$line" =~ --n-cpu-moe=([0-9]+) ]]; then
            moe="${BASH_REMATCH[1]}"
            UB_MOE[$ub]=$moe
            echo "  ✓ -ub $ub → --n-cpu-moe=$moe"
        fi
    fi
done < "$RESULTS_FILE"

# ---------- Get evaluated UB values ----------
# find_moe tests: 4096, 3072, 2048, 1024, 512
# benchmark_workload needs: 4096, 3072, 2048, 1024, 512
get_moe() {
    local ub=$1
    if [[ -n "${UB_MOE[$ub]+x}" ]]; then
        echo "${UB_MOE[$ub]}"
    else
        echo ""
    fi
}

UB4096=$(get_moe 4096)
UB3072=$(get_moe 3072)
UB2048=$(get_moe 2048)
UB1024=$(get_moe 1024)
UB512=$(get_moe 512)

echo ""
echo "  Gefundene MoE-Werte:"
for ub in 4096 3072 2048 1024 512; do
    val=""
    case $ub in
        4096) val="$UB4096" ;;
        3072) val="$UB3072" ;;
        2048) val="$UB2048" ;;
        1024) val="$UB1024" ;;
        512)  val="$UB512" ;;
    esac
    if [[ -n "$val" ]]; then
        echo "    ✓ -ub=$ub → --n-cpu-moe=$val"
    else
        echo "    ⏭ -ub=$ub → (nicht gefunden)"
    fi
done

# Prüfen ob mindestens ein Wert gefunden wurde
if [[ -z "$UB4096" && -z "$UB3072" && -z "$UB2048" && -z "$UB1024" && -z "$UB512" ]]; then
    echo ""
    echo "ERROR: Keine UB-Werte haben Ergebnisse. Abbruch."
    cat "$RESULTS_FILE"
    exit 1
fi

echo ""
echo "=============================================="
echo "  Step 2: benchmark_workload"
echo "=============================================="

BASE_NAME=$(basename "$MODEL" | cut -d: -f1)
BENCHMARK_FILE="${BASE_NAME}_benchmark_results.md"

bash "$(dirname "$0")/benchmark_workload" \
    "$BENCHMARK_FILE" \
    "$MODEL" \
    $([ -n "$UB4096" ] && echo "--ub4--moe $UB4096" || true) \
    $([ -n "$UB3072" ] && echo "--ub3--moe $UB3072" || true) \
    $([ -n "$UB2048" ] && echo "--ub2--moe $UB2048" || true) \
    $([ -n "$UB1024" ] && echo "--ub1--moe $UB1024" || true) \
    $([ -n "$UB512" ] && echo "--ub0.5--moe $UB512" || true) \
    "$CTV" \
    "$CTK" \
    "$CTX"

echo ""
echo "=============================================="
echo "  Fertig!"
echo "  Markdown-Ergebnis: $BENCHMARK_FILE"
echo "  Token-Results:     ${BASE_NAME}_benchmark_results.md-token-generation-results"
echo "=============================================="
