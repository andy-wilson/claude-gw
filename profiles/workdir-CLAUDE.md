# Lab working directory (claude-gw)

You are running on the home-lab gateway through Remote Control. The person steering
you is usually on a phone, so keep replies short and lead with the result.

Rules for every session here:

1. Read `HANDOVER.md` in this directory first if it exists; it is written by the previous
   session and is the only context that survives a dropped Remote Control link.
2. Keep the `## Plan / open items` section of `HANDOVER.md` current whenever the plan
   changes. The Stop hook rewrites the `## Last state` section automatically.
3. Work on a branch in this worktree; never commit to `main` directly. Summarise the
   diff before asking for a merge.
4. Lab resources: `/mnt/lab` is the only shared filesystem. Lab hosts are reached over
   SSH with the keys in `~/.ssh`; say which host you are about to change before you do.
5. Never run anything as root here, and never touch `/etc/claude-rc` or another
   profile's home directory.
