#!/bin/bash

DEBUG=0
MODEL=""
MIN_CTX="128000"
CTV="f16"
CTK="f16"

# Array zum Tracken aller llama-server PIDs
declare -a SERVER_PIDS

# Cleanup-Funktion: tötet alle gestarteten llama-server Prozesse
kill_all_servers() {
    if [ ${#SERVER_PIDS[@]} -gt 0 ]; then
        echo ""
        echo "[CLEANUP] Töte ${#SERVER_PIDS[@]} verbleibende llama-server Prozess(e)..."
        for pid in "${SERVER_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Killing PID $pid"
                kill -TERM "$pid" 2>/dev/null
            fi
        done
        # Kurz warten auf sauberen Exit
        sleep 2
        for pid in "${SERVER_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Force-killing PID $pid"
                kill -9 "$pid" 2>/dev/null
            fi
        done
        wait 2>/dev/null
        echo "[CLEANUP] Done."
    fi
}

# Trap für sauberen Exit (auch bei Ctrl+C / Signal)
trap kill_all_servers EXIT INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) DEBUG=1; shift ;;
        -ctx) MIN_CTX="${2:-128000}"; shift 2 ;;
        -ctv) CTV="${2:-f16}"; shift 2 ;;
        -ctk) CTK="${2:-f16}"; shift 2 ;;
        *)
            if [ -z "$MODEL" ]; then
                MODEL="$1"
            elif [ "$MIN_CTX" = "128000" ]; then
                MIN_CTX="$1"
            fi
            shift ;;
    esac
done

if [ -z "$MODEL" ]; then
    echo "Usage: $0 <model-hf-path> [min_ctx] [--debug]"
    echo "  min_ctx  minimum n_ctx value (default: 128000)"
    echo "  --debug  verbose logging"
    exit 1
fi

echo "Using Model: $MODEL"
echo "Using MIN_CTX: $MIN_CTX"
echo "Using CTV: $CTV"
echo "Using CTK: $CTK"
echo "Using DEBUG: $DEBUG"

# Batch / update batch values to test
UB_VALUES=(4096 3072 2048 1024 512)

# Extract model name from pattern <anbieter>/<modelname>:<quant>
MODEL_NAME=$(basename "$MODEL" | cut -d: -f1)
RESULTS_FILE="${MODEL_NAME}_results.txt"

echo "# Results for: $MODEL" > "$RESULTS_FILE"
echo "# Generated: $(date)" >> "$RESULTS_FILE"
echo "# MIN_CTX: $MIN_CTX" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

for ub in "${UB_VALUES[@]}"; do
    echo "=========================================="
    echo "Testing -ub $ub"
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] MODEL=$MODEL"
        echo "[DEBUG] MODEL_NAME=$MODEL_NAME"
        echo "[DEBUG] which llama-server: $(which llama-server 2>&1)"
        echo "[DEBUG] Available GPUs: $(nvidia-smi -L 2>&1)"
        echo "[DEBUG] Free GPU memory: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader 2>&1 | head -3)"
    fi
    echo "=========================================="

    # Track only the previous run
    BEST_MOE=""
    BEST_N_CTX=""

    for moe in $(seq 50 -1 0); do
        LOGFILE=$(mktemp)
        if [ "$DEBUG" -eq 1 ]; then
            echo "[DEBUG] Using Logfile: $LOGFILE"
        fi
	
        llama-server -hf "$MODEL" -ctv $CTV -ctk $CTK -dev CUDA0 --parallel 1 --no-mmproj-offload -kvo -ub $ub -b $ub --n-cpu-moe $moe > "$LOGFILE" 2>&1 &
        SERVER_PID=$!
        SERVER_PIDS+=("$SERVER_PID")

        # Poll log for n_seq_max line, kill as soon as found (max ~20s)
        FOUND=0
        for i in $(seq 1 600); do
            if ! kill -0 "$SERVER_PID" 2>/dev/null; then
                echo "  [DEBUG] Server PID $SERVER_PID exited unexpectedly"
                if [ "$DEBUG" -eq 1 ]; then
                    echo "  --- SERVER LOG ---"
                    cat "$LOGFILE"
                    echo "  --- END LOG ---"
                fi
                break
            fi
            if grep -q "n_seq_max" "$LOGFILE" 2>/dev/null; then
                FOUND=1
                break
            fi
            sleep 0.2
        done

        # Server immer stoppen und aus PID-Array entfernen
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "  Stopping llama-server PID $SERVER_PID"
            kill -TERM "$SERVER_PID" 2>/dev/null
            # Max 5s warten, sonst forcieren
            for w in $(seq 1 25); do
                if ! kill -0 "$SERVER_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.2
            done
            if kill -0 "$SERVER_PID" 2>/dev/null; then
                echo "  Force-killing PID $SERVER_PID (SIGKILL)"
                kill -9 "$SERVER_PID" 2>/dev/null
            fi
        fi
        wait "$SERVER_PID" 2>/dev/null

        # PID aus Tracking-Array entfernen (durch Neuaufbau)
        SERVER_PIDS=(${SERVER_PIDS[@]/"$SERVER_PID"})

        if [ "$FOUND" -eq 0 ]; then
            if [ -f "$LOGFILE" ]; then
                echo "  moe=$moe -> no n_ctx output (server may have failed)"
                echo "  [DEBUG] Server took >20s without n_seq_max output"
                if [ "$DEBUG" -eq 1 ]; then
                    echo "  --- SERVER LOG ---"
                    cat "$LOGFILE"
                    echo "  --- END LOG ---"
                fi
            else
                echo "  moe=$moe -> no n_ctx output (server may have crashed immediately)"
                echo "  [DEBUG] No log file found"
                if [ "$DEBUG" -eq 1 ]; then
                    echo "  --- Check: is llama-server in PATH? ---"
                    which llama-server 2>&1 || echo "llama-server not found in PATH"
                fi
            fi
            rm -f "$LOGFILE"
            continue
        fi

        N_CTX=$(grep -A1 "n_seq_max" "$LOGFILE" | grep "n_ctx" | sed 's/.*n_ctx *= *\([0-9]*\).*/\1/' | head -1)
        rm -f "$LOGFILE"

        if [ -z "$N_CTX" ]; then
            continue
        fi

        if [ "$N_CTX" -lt "$MIN_CTX" ]; then
            echo "  moe=$moe -> n_ctx=$N_CTX (below min)"
            if [ -n "$BEST_MOE" ]; then
                echo "  -> Best value for -ub $ub: --n-cpu-moe=$BEST_MOE (n_ctx=$BEST_N_CTX >= $MIN_CTX)"
                echo "-ub=$ub  --n-cpu-moe=$BEST_MOE  n_ctx=$BEST_N_CTX" >> "$RESULTS_FILE"
                echo "" >> "$RESULTS_FILE"
            else
                echo "  -> moe=50 already below min, no valid value found (VRAM zu klein?)"
            fi
            break
        else
            echo "  moe=$moe -> n_ctx=$N_CTX (>= min, trying lower)"
            BEST_MOE=$moe
            BEST_N_CTX=$N_CTX
        fi
    done

    # Edge case: all moe values 50..0 kept n_ctx >= MIN_CTX (loop finished without going below min)
    if [ "$moe" -eq 0 ] && [ "$N_CTX" -ge "$MIN_CTX" ] 2>/dev/null; then
        echo "  -> All moe values down to 0 kept n_ctx >= min. (alles im VRAM)"
        echo "-ub=$ub  --n-cpu-moe=0  n_ctx=$N_CTX" >> "$RESULTS_FILE"
        echo "" >> "$RESULTS_FILE"
    fi

    echo ""
done
