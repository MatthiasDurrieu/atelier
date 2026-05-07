# runscript

Launch a long-running command in a detached [`screen`](https://www.gnu.org/software/screen/)
session and get a [Pushover](https://pushover.net) notification on your phone
when it finishes — successfully *or* not.

Designed for the kind of script you kick off in the morning and don't want to
babysit: ML training runs, large data processing, batch jobs, anything that
takes longer than a coffee break.

## Why?

You've probably written something like this before:

```bash
nohup python train.py --epochs 100 > train.log 2>&1 &
```

…and then come back two hours later only to find it crashed in the first
minute because you misspelled `--epochs` as `--epcohs`. Or it finished
successfully but you didn't notice for another three hours because you got
distracted. `runscript` fixes both ends of that:

1. **Pre-flight validation** rejects the command before launch if the
   executable is missing, the script has a syntax error, or the command line
   doesn't parse.
2. **Always-on notifications** ping your phone with the result, including the
   exit code, duration, and last lines of the log if it failed.
3. **Detached `screen` session** means you can reattach, watch live output,
   then detach again — no lost stdout, no orphaned processes.

## Features

- Pre-flight checks before launch:
  - first token is on `$PATH`
  - command line parses (`bash -n`)
  - `.sh` / `.bash` files pass `bash -n`
  - `.py` files pass `python -m py_compile`
  - required env vars (`PUSHOVER_*`, `LOGS_DIRECTORY`) are set
- Runs the command in a detached `screen` session named after the script and
  timestamp — easy to find with `screen -ls`.
- Captures full stdout/stderr to a timestamped log file with a header
  (command, start time) and footer (duration, exit code).
- Sends a Pushover notification on completion with:
  - **Success**: command, duration, exit code, log path
  - **Failure**: same plus the last 15 lines of the log, sent at high priority
- Retries the notification up to 5 times with backoff; logs a warning if all
  retries fail.
- Self-test mode (`runscript --test`) exercises the full pipeline end-to-end.

## Requirements

- `bash` 4+ (works in `zsh` too)
- [`screen`](https://www.gnu.org/software/screen/)
- `curl`
- A free [Pushover](https://pushover.net) account with the mobile app installed

## Install

1. Clone the repo (or just grab the file):

   ```bash
   git clone https://github.com/<you>/atelier.git ~/atelier
   ```

2. Source the script from your shell rc file:

   ```bash
   echo 'source ~/atelier/runscript/runscript.sh' >> ~/.bashrc
   # or ~/.zshrc
   ```

3. Set the required environment variables (also in your rc file):

   ```bash
   export PUSHOVER_API_KEY="your-app-token"
   export PUSHOVER_USER_KEY="your-user-key"
   export LOGS_DIRECTORY="$HOME/logs/runscript/"   # must already exist
   ```

4. Reload your shell and verify with the self-test:

   ```bash
   source ~/.bashrc
   runscript --test
   ```

   If your phone buzzes within ~3 seconds, you're done.

## Usage

```bash
runscript <command> [args...]
```

### Examples

```bash
# Python training run
runscript python train.py --epochs 50 --lr 0.001

# Long bash script with arguments
runscript bash process_data.sh /data/raw /data/processed

# One-liner
runscript bash -c 'for f in *.csv; do gzip "$f"; done'

# Self-test
runscript --test
```

### What gets printed

```
Validating command...
Validation OK.

Launched in screen session: train_20260507130412
   Log file:    /home/me/logs/runscript/train.py_20260507130412.log
   Reattach:    screen -r train_20260507130412
   List all:    screen -ls
   Detach:      Ctrl-a d   (inside the session)
   Kill:        screen -X -S train_20260507130412 quit
```

### Working with the screen session

```bash
screen -ls                                   # list all sessions
screen -r train_20260507130412               # reattach (Ctrl-a d to detach)
screen -X -S train_20260507130412 quit       # kill the session
tail -f $LOGS_DIRECTORY/train.py_*.log       # follow log without attaching
```

## What the notification looks like

**Success**

> **OK: train.py finished**
> Command: python train.py --epochs 50 --lr 0.001
> Duration: 2h 14m
> Exit code: 0
> Session: train_20260507130412
> Log: /home/me/logs/runscript/train.py_20260507130412.log

**Failure** (high priority, bypasses Pushover quiet hours)

> **FAIL: train.py (exit 1)**
> Command: python train.py --epochs 50 --lr 0.001
> Duration: 12s
> Exit code: 1
> Session: train_20260507130412
>
> --- last log lines ---
> Traceback (most recent call last):
>   File "train.py", line 42, in <module>
>     model = build_model(cfg.archhitecture)
> AttributeError: 'Config' object has no attribute 'archhitecture'
>
> Log: /home/me/logs/runscript/train.py_20260507130412.log

## Limitations & known caveats

- The wrapper script embeds the command at write time, so the command runs in
  a fresh `screen` session with the *current* environment but not your full
  interactive shell setup (aliases, functions). If you rely on a shell
  function, wrap it in a `.sh` file or use `bash -c`.
- If `screen` itself dies (rare) or the wrapper is killed with `SIGKILL`, no
  notification is sent. The log is still written.
- Notifications go to a single Pushover user/app pair. Multi-user routing is
  not supported.

## License

[MIT](../LICENSE)
