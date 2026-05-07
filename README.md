# atelier

A small workshop of scripts and utilities I've found genuinely useful in
day-to-day work. Nothing fancy — just things that solved a real annoyance and
turned out to be worth sharing.

Each tool lives in its own subdirectory with a short README explaining what it
does, how to install it, and how to use it.

## Contents

| Tool                              | What it does                                                                        |
| --------------------------------- | ----------------------------------------------------------------------------------- |
| [`runscript`](./runscript/)       | Run a long command in a detached `screen` session and get a phone notification when it finishes (or fails). Includes pre-flight syntax checks so typos don't waste hours. |

## Philosophy

- Every tool should be **drop-in**: a single file you can `source`, copy, or
  run. No build steps, no package managers.
- Every tool should **fail loudly and helpfully**: catch problems early,
  surface real error messages.
- Every tool should be **documented for someone who isn't me**: assume the
  reader has never seen it before.

## Contributing

Issues and PRs welcome. If something here is broken on your setup, please open
an issue with the OS, shell version, and the exact command you ran.

## License

[MIT](./LICENSE)
