# =============================================================================
# runscript - run a long command in a detached `screen` session, with
#             pre-flight validation and reliable Pushover notifications.
#
# Requirements:
#   - `screen` installed
#   - $PUSHOVER_API_KEY, $PUSHOVER_USER_KEY exported in the environment
#   - $LOGS_DIRECTORY exported (trailing slash optional)
#
# Usage:
#   runscript python train.py --epochs 50 --lr 0.001
#   runscript bash long_job.sh arg1 arg2
# =============================================================================
runscript() {
    # ---------- Parse runscript-level flags ---------------------------------
    # These must come BEFORE the command. Flags after the command are
    # treated as part of your command's own arguments.
    local attach=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --attach|-a)
                attach=1
                shift
                ;;
            --test|-t)
                # Self-test: run a trivial command through the whole pipeline.
                shift
                local test_args=()
                [[ $attach -eq 1 ]] && test_args=(--attach)
                test_args+=(bash -c 'echo "runscript self-test"; echo "host: $(hostname)"; echo "date: $(date)"; sleep 2; echo "all good"')
                echo "Running runscript self-test..."
                runscript "${test_args[@]}"
                return $?
                ;;
            --help|-h)
                cat <<'HELP'
Usage: runscript [--attach|-a] <command> [args...]
       runscript [--attach|-a] --test
       runscript --help

Options (must come BEFORE the command):
  --attach, -a    Attach to the screen session immediately (Ctrl-a d to detach)
  --test,   -t    Run a 2-second self-test through the full pipeline
  --help,   -h    Show this help

Examples:
  runscript python train.py --epochs 50
  runscript --attach python -u train.py --epochs 50
  runscript bash long_job.sh /data/raw /data/processed
  runscript --test
HELP
                return 0
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        echo "Usage: runscript [--attach] <command> [args...]" >&2
        echo "       runscript --test          # smoke-test the whole pipeline" >&2
        echo "       runscript --help" >&2
        return 1
    fi

    # ---------- Identify a script name (used for log + session name) ----------
    local script_name="" script_path=""
    local arg
    for arg in "$@"; do
        if [[ "$arg" != -* ]] && [[ -f "$arg" ]]; then
            script_path="$arg"
            script_name="$(basename "$arg")"
            break
        fi
    done
    [[ -z "$script_name" ]] && script_name="$(basename "${1}")"
    [[ -z "$script_name" ]] && script_name="command"

    # =========================================================================
    # (3) PRE-FLIGHT VALIDATION  -- catch typos before launching anything
    # =========================================================================
    echo "Validating command..."

    # 3a. Required env vars
    if [[ -z "$PUSHOVER_API_KEY" || -z "$PUSHOVER_USER_KEY" ]]; then
        echo "ERROR: PUSHOVER_API_KEY and PUSHOVER_USER_KEY must be set" >&2
        return 1
    fi
    if [[ -z "$LOGS_DIRECTORY" ]]; then
        echo "WARN:  LOGS_DIRECTORY not set, defaulting to /tmp/" >&2
        LOGS_DIRECTORY="/tmp/"
    fi
    LOGS_DIRECTORY="${LOGS_DIRECTORY%/}/"
    if [[ ! -d "$LOGS_DIRECTORY" ]]; then
        echo "ERROR: LOGS_DIRECTORY does not exist: $LOGS_DIRECTORY" >&2
        return 1
    fi

    # 3b. screen must be installed
    if ! command -v screen &>/dev/null; then
        echo "ERROR: 'screen' is not installed" >&2
        return 1
    fi

    # 3c. The first token must be an executable on $PATH (or an explicit path)
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: command not found: $1" >&2
        return 1
    fi

    # 3d. Shell-parse the whole command line (catches mis-quoted args, etc.)
    local quoted_cmd
    quoted_cmd="$(printf '%q ' "$@")"
    if ! bash -n -c "$quoted_cmd" 2>/dev/null; then
        echo "ERROR: shell parse error in command" >&2
        bash -n -c "$quoted_cmd"
        return 1
    fi

    # 3e. Syntax-check the actual script file when we recognise the type
    if [[ -n "$script_path" ]]; then
        local syn_err
        case "$script_path" in
            *.sh|*.bash)
                if ! syn_err="$(bash -n "$script_path" 2>&1)"; then
                    echo "ERROR: bash syntax error in $script_path" >&2
                    echo "$syn_err" >&2
                    return 1
                fi
                ;;
            *.py)
                local py_bin="python3"
                command -v python3 &>/dev/null || py_bin="python"
                if ! syn_err="$($py_bin -m py_compile "$script_path" 2>&1)"; then
                    echo "ERROR: python syntax error in $script_path" >&2
                    echo "$syn_err" >&2
                    return 1
                fi
                ;;
        esac
    fi

    echo "Validation OK."

    # =========================================================================
    # SETUP - log file, session name, wrapper script
    # =========================================================================
    local timestamp session_name log_file wrapper_script
    timestamp="$(date +%Y%m%d%H%M%S)"
    session_name="$(echo "${script_name%.*}_${timestamp}" | tr -c '[:alnum:]_-' '_')"
    log_file="${LOGS_DIRECTORY}${script_name}_${timestamp}.log"
    wrapper_script="$(mktemp -t runscript.XXXXXX)"

    # =========================================================================
    # (2) WRAPPER SCRIPT - always sends a notification, even on failure,
    # (4) and includes a rich, useful message.
    # =========================================================================
    # NOTE on quoting:
    #   $foo   -> expanded NOW (when writing the file)
    #   \$foo  -> stays literal, evaluated when the wrapper runs
    cat > "$wrapper_script" <<WRAPPER_EOF
#!/usr/bin/env bash
# Auto-generated by runscript. Safe to delete.

LOG_FILE=$(printf '%q' "$log_file")
SESSION_NAME=$(printf '%q' "$session_name")
SCRIPT_NAME=$(printf '%q' "$script_name")
CMD_DISPLAY=$(printf '%q' "$*")
WRAPPER_SELF=$(printf '%q' "$wrapper_script")

PUSHOVER_API_KEY=$(printf '%q' "$PUSHOVER_API_KEY")
PUSHOVER_USER_KEY=$(printf '%q' "$PUSHOVER_USER_KEY")

START_TS=\$(date +%s)
START_HUMAN=\$(date '+%Y-%m-%d %H:%M:%S')

# --- Run the user's command, streaming output to BOTH the screen and log ---
# tee duplicates output so reattaching with \`screen -r\` shows live progress.
# PIPESTATUS[0] preserves the user-command's real exit code across the pipe.
set -o pipefail
{
    echo "================================================"
    echo "runscript wrapper"
    echo "Command : \$CMD_DISPLAY"
    echo "Started : \$START_HUMAN"
    echo "Session : \$SESSION_NAME"
    echo "Log     : \$LOG_FILE"
    echo "================================================"
    echo
    $quoted_cmd
} 2>&1 | tee "\$LOG_FILE"
EXIT_CODE=\${PIPESTATUS[0]}
set +o pipefail

END_TS=\$(date +%s)
DUR=\$(( END_TS - START_TS ))
if   (( DUR < 60 ));   then DUR_STR="\${DUR}s"
elif (( DUR < 3600 )); then DUR_STR="\$(( DUR / 60 ))m \$(( DUR % 60 ))s"
else                        DUR_STR="\$(( DUR / 3600 ))h \$(( DUR % 3600 / 60 ))m"
fi

# --- Build a notification message --------------------------------------------
if [[ \$EXIT_CODE -eq 0 ]]; then
    TITLE="OK: \$SCRIPT_NAME finished"
    PRIORITY=0
    MESSAGE="Command: \$CMD_DISPLAY
Duration: \$DUR_STR
Exit code: 0
Session: \$SESSION_NAME
Log: \$LOG_FILE"
else
    TITLE="FAIL: \$SCRIPT_NAME (exit \$EXIT_CODE)"
    PRIORITY=1
    ERR_TAIL=\$(tail -n 15 "\$LOG_FILE" 2>/dev/null | head -c 800)
    MESSAGE="Command: \$CMD_DISPLAY
Duration: \$DUR_STR
Exit code: \$EXIT_CODE
Session: \$SESSION_NAME

--- last log lines ---
\$ERR_TAIL

Log: \$LOG_FILE"
fi

# --- Print + append summary footer to both screen and log -------------------
{
    echo
    echo "================================================"
    echo "Finished : \$(date '+%Y-%m-%d %H:%M:%S')"
    echo "Duration : \$DUR_STR"
    echo "Exit code: \$EXIT_CODE"
    echo "================================================"
} 2>&1 | tee -a "\$LOG_FILE"

# --- Send notification with retries ------------------------------------------
NOTIF_OK=0
for attempt in 1 2 3 4 5; do
    if curl -sS --max-time 15 \\
            --form-string "token=\$PUSHOVER_API_KEY" \\
            --form-string "user=\$PUSHOVER_USER_KEY" \\
            --form-string "title=\$TITLE" \\
            --form-string "priority=\$PRIORITY" \\
            --form-string "message=\$MESSAGE" \\
            https://api.pushover.net/1/messages.json >> "\$LOG_FILE" 2>&1
    then
        NOTIF_OK=1
        break
    fi
    sleep \$(( attempt * 3 ))
done
if [[ \$NOTIF_OK -eq 0 ]]; then
    echo "WARN: Pushover notification failed after retries" >> "\$LOG_FILE"
fi

rm -f "\$WRAPPER_SELF"
WRAPPER_EOF

    chmod +x "$wrapper_script"

    # =========================================================================
    # (1) LAUNCH IN A `screen` SESSION (detached or attached)
    # =========================================================================
    if [[ $attach -eq 1 ]]; then
        # Foreground/attached: control returns when the session ends or the
        # user detaches with Ctrl-a d.
        cat <<INFO

Launching attached in screen session: $session_name
   Detach (keep running):  Ctrl-a d
   Kill the command:       Ctrl-c (will trigger a FAIL notification)
   Log file:               $log_file

INFO
        screen -S "$session_name" bash "$wrapper_script"
        local screen_rc=$?

        # When `screen` returns, the session has either ended (command
        # finished or was killed) or the user detached.
        if screen -list 2>/dev/null | grep -qE "[0-9]+\.${session_name}\b"; then
            cat <<INFO

Detached. Session is still running in the background.
   Reattach:    screen -r $session_name
   List all:    screen -ls
   Kill:        screen -X -S $session_name quit
   Log file:    $log_file

INFO
        else
            cat <<INFO

Session ended. Notification sent (check your phone).
   Log file:    $log_file

INFO
        fi
        return $screen_rc
    else
        # Detached: launch and return immediately.
        if ! screen -dmS "$session_name" bash "$wrapper_script"; then
            echo "ERROR: failed to start screen session" >&2
            rm -f "$wrapper_script"
            return 1
        fi

        sleep 0.2
        if ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${session_name}\b"; then
            echo "WARN: screen session may not have started; check 'screen -ls'" >&2
        fi

        cat <<INFO

Launched in screen session: $session_name
   Log file:    $log_file
   Reattach:    screen -r $session_name
   List all:    screen -ls
   Detach:      Ctrl-a d   (inside the session)
   Kill:        screen -X -S $session_name quit

INFO
    fi
}
