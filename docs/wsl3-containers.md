# WSL 3 native containers: migration guidance

*Status: proposal. This is guidance for whoever picks the work up next, not an
API contract. It deliberately avoids versions, flag names, sizes and
performance numbers: those belong to the machine and the runtime build in
front of you, and they will have moved by the time you read this.*

Today the Windows path runs the stack through Docker inside a WSL
distribution. WSL 3 ships a native container runtime (the `wslc` tooling) that
Windows drives directly. An exploratory pass found the existing image runs
there with its GPU, installation checks and model-preparation paths intact.
This note records the shape of a migration, the deltas that actually matter,
and the gates it has to pass — so the next attempt spends its time on the
differences rather than re-opening the same questions.

[← back to the main README](../README.md)

The current path is documented in [docker.md](docker.md); the Windows
reproduction notes are in [wsl2-4090.md](wsl2-4090.md).

## Where we are

- One immutable Linux image is the deployable unit. The Dockerfile, entrypoint,
  model preparation, launchers, patches and verification all live inside it.
- Compose is the only orchestration layer: profiles select single-user or batch,
  a one-shot service prepares the model, and the server service owns ports,
  health, restart and named volumes.
- The WSL host carries container-engine plumbing of its own — a daemon, the
  NVIDIA container runtime and its device specification — because that is what
  the current path needs.
- Model state lives in the distribution's filesystem; the compile/cache state
  lives in a named volume.
- The docs describe the Windows path as Docker-in-WSL and say there is no
  native-Windows alternative. That statement is what this plan would retire.

## Where this could go

- The same image, run by the Windows-managed container runtime, with Windows
  owning start/stop, storage, published ports, logs and health.
- Model data on Windows-visible storage (a normal Windows directory or a
  runtime-managed volume), so backups and cleanup use Windows tools.
- A small repo-local shim that expresses the Compose behaviours the stack
  relies on. It should stay small enough to read in one sitting; if it starts
  growing into an orchestrator, that is a signal to stop.
- Docker and Compose remain the canonical path for Linux hosts and CI. This is
  an additional runtime target, not a replacement for the image pipeline.

## What does not change

The migration is mostly a change of host, not a change of stack:

- the image, its entrypoint, `docker/prepare.sh`, `verify.sh`, the mode
  launchers and every environment knob;
- the patch series, the KVarN/FA2/pth-flash-attn builds and the CI image gate;
- the model-preparation steps and their idempotence;
- the WSL-in-the-guest workarounds. Pinned memory, the allocator setting and
  the GPU-utilisation fallback are properties of the paravirtual GPU, not of
  the container engine, so they still apply under a different runtime.

## Deltas that matter

| Concern | Current shape | What to design for |
|---|---|---|
| Orchestration | Compose profiles, a dependent one-shot service, health and restart policy | Explicit container lifecycle in the shim: prepare-then-serve, named modes, health check, restart intent, and a `down` that means "gone", not "maybe back after the session restarts" |
| Configuration | Compose reads `.env`, expands variables and normalises quoting | The runtime's environment handoff is thinner. Parse `.env` once in the shim and pass resolved values; do not assume Compose's expansion or quote handling |
| Model storage | Bind mount from the distribution's filesystem | The native runtime may only accept Windows-visible paths or its own volumes. Choose per data class: models (large, backed up from Windows), cache (ephemeral, runtime volume) |
| Compute | Device reservation at the engine level | GPU exposure may be all-or-nothing. On a multi-GPU box, selection has to happen inside the container; record that as a limitation rather than pretending it is isolation |
| Shared memory | Host IPC namespace | Host IPC may not be available. Size the shared-memory mount explicitly; the launchers already warn when an offload tier will not fit |
| Lifecycle | `unless-stopped` survives a daemon restart but respects a manual stop | Restart primitives are usually coarser. Decide what "stopped" means and encode it in the shim, or a stopped service returns after a reboot |
| Autostart | The container engine starts with the distribution | The native runtime is user-session oriented. A logon task or an explicit start is part of the design, especially on a headless box |
| Health, logs, exec, verify | Compose/engine commands | Same intent, different CLI. Keep the checks and their meanings; change only the transport |
| Image build | Local Docker build or the prebuilt CI image | Prefer the CI image. Local builds should stay a fallback and must not become a second source of truth |

## Migration phases

**0. Freeze a baseline.** Record the image digest in use, the effective
environment, the model layout, the health endpoint, a quality run and a
throughput run in both modes, and the exact commands that restore the current
service. This baseline is what every later gate is compared against.

**1. Prove the runtime without the model.** Pull the same image, run a GPU
compute smoke test, and run the install-only verification. No model, no
serving. The exit criterion is image identity plus a clean verification pass.

**2. Build the shim.** Cover only the operations the repo already exposes:
up/down in each mode, logs, status, verify, shell, prepare. Preserve container
names, ports, health semantics and the `.current-profile` idea unless there is
a reason not to. Write the shim so it can run from Windows and, if useful, from
the distribution for development.

**3. Move state.** Put the model directory where the runtime can see it,
confirm the preparation step considers it complete rather than re-downloading,
and create the cache volume. Prove a cold start does not need the old
distribution filesystem.

**4. Run in parallel.** Keep the Docker path available. Run the new path for a
soak period, compare health, quality and throughput against the baseline, and
exercise restart, session teardown and reboot. One GPU means the two paths
cannot serve at the same time; schedule the comparisons rather than running
them concurrently.

**5. Cut over.** Make the new path the documented default only after the gates
below pass. Leave the Compose file in place for Linux and CI.

**6. Clean up, deliberately.** Remove the host container daemon, the NVIDIA
container runtime and its device specification, and any host setup that
existed only to support them. Keep the rollback path until the new path has
survived at least one unattended restart.

## Validation gates

Do not cut over on "it started once". The minimum set:

- the image is the same digest CI publishes, not a locally drifted rebuild;
- install verification inside the runtime passes (patches, KVarN, optional
  attention libraries);
- GPU compute works from the image, not just the host;
- a cold start with an empty cache reaches a healthy endpoint;
- the quality battery passes on the served model;
- single-user and batch throughput are within an agreed budget of the Docker
  baseline — a runtime tax has to be measured, not assumed away;
- stop, restart, session teardown and reboot all leave the service in the
  intended state, including "stopped stays stopped";
- logs, exec, verify and prepare behave like their Compose counterparts;
- the rollback has been rehearsed, not just written down;
- no API key appears in process arguments, logs or the repository.

## Re-verify, do not inherit

The exploratory pass is a feasibility signal, not a specification. Before
implementing, confirm against the runtime build actually installed:

- that the native container feature is present, enabled and GPU-capable on
  this Windows build;
- that the prebuilt image pulls and that GPU compute works inside it;
- which filesystem sources the runtime accepts for bind mounts, and whether
  the distribution's paths are among them;
- whether named volumes persist across session teardown and reboot;
- how restart, health and autostart actually behave, rather than how the help
  text reads;
- whether host IPC is available or only an explicit shared-memory size;
- whether GPU selection exists at the runtime level or only inside the
  container;
- the real cost of model reads and preparation writes on the chosen storage.

Record the answers in the PR that implements the shim. A future reader should
be able to see which assumptions were tested and which were inherited.

## Open questions

- **End-to-end serving was not measured in the exploratory pass.** The image,
  GPU and verification paths were exercised; a full model load and a
  throughput comparison are still outstanding.
- **Multi-GPU isolation.** If the runtime exposes every card, the second-engine
  layout becomes convention rather than enforcement. Is that acceptable?
- **Windows-visible model storage.** Read throughput, write behaviour during
  preparation, and file ownership after a root-run preparation all need a
  deliberate answer.
- **Headless operation.** A user-session runtime may need a scheduled task or a
  service wrapper before the first login.
- **Runtime maturity.** The feature is new. Decide whether to pin a Windows/WSL
  build, and how to detect a breaking change before a reboot does it for you.
- **Upstream or fork.** Is a Windows-native path something the project wants to
  document publicly, or a fork-local workflow? That decision changes where the
  shim and docs live.

## Decision rule

Adopt the new runtime only if the gates pass and the shim stays small. The
migration is worth doing when it removes host plumbing and gives Windows a
cleaner lifecycle without a quality or throughput regression. If it merely
moves the same orchestration behind a different CLI, keep Docker and revisit
when the runtime has matured.

## Evidence from the exploratory pass

One single-GPU WSL 3 host was used in November 2026. The prebuilt image
pulled and ran; the GPU was visible to CUDA; the install-only verification
passed; the launcher resolved its configuration; health checks, named volumes,
Windows-path bind mounts and the filesystem operations used by model
preparation behaved. End-to-end serving was not run because the card was busy.
Treat all of that as "the shape is viable", not as numbers or flags to copy.
