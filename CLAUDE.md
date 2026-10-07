# Rules

## No sensitive data in the repository

This repository is public (github.com/stonewell/lite-xl). Never write any of
the following into tracked files, test fixtures, docs, commit messages or PR
descriptions:

- real host names, IP addresses or PuTTY session names of private machines
- real user names, employee/account ids, or home directories (`/home/<real-user>`)
- employer or customer names, internal URLs, ticket ids
- credentials, tokens, private keys, host key fingerprints of real hosts
- personal local paths that identify a user beyond the generic tool layout

Use placeholders instead: `remote-box`, `build-server`, `user`, `/home/user`,
`user@example.com`, `no-such-host.invalid`, `127.0.0.1`.

Tests and scripts that need a real host must read it from an environment
variable (e.g. `${LXS_SERVER:-...}`) with a placeholder default, never hard-code it.

Before committing, check the staged diff for anything that looks like a real
host, user or path, and replace it. If sensitive data has already been
committed, stop and tell the user: a follow-up commit does not remove it from
history, which needs a rewrite and force push.
