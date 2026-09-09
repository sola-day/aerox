# Load baselines (VERIFICATION §10.1)

Each row is `bench/baseline.sh` on the dev box (AWS, 4 vCPU, Postgres 18 in
Docker, Traefik in front, TLS terminated by Traefik), 32 connections for 15 s.
A release that regresses a p99 by more than 25 % against the last row fails the
checklist. The mix-run dev server is measured here; a release build is somewhat
faster (no code reloader) and is re-measured when the first release is cut.

| Commit | Endpoint | req/s | p50 | p99 | Notes |
|---|---|---|---|---|---|
| (filled by the first run of `bench/baseline.sh` after M10; see below) | | | | | |
