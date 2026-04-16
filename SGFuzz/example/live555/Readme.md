## An example for Live555

### Build

If you already have `honggfuzz/` placed in this directory, build the target with:

```shell
cd /home/ckt/Documents/000_2026_test_dev/SGFuzz/example/live555
conda activate sgfuzz_env
./build_local.sh
```

This generates the fuzzing binary at:

```shell
/home/ckt/Documents/000_2026_test_dev/SGFuzz/example/live555/live555-sgfuzz/testProgs/testOnDemandRTSPServer
```

### Precheck

Before starting fuzzing, verify the environment and required files:

```shell
cd /home/ckt/Documents/000_2026_test_dev/SGFuzz/example/live555
conda activate sgfuzz_env
./precheck_live555.sh
```

### Run

Start fuzzing with the one-step launcher:

```shell
cd /home/ckt/Documents/000_2026_test_dev/SGFuzz/example/live555
conda activate sgfuzz_env
./run_live555_fuzz.sh
```

Defaults used by the launcher:

- Corpus: `./in-rtsp`
- Artifacts: `./artifacts`
- Dictionary: `./rtsp.dict`
- TCP port: `8554`

You can also run multiple independent rounds, each with an auto-selected free port:

```shell
./run_live555_fuzz.sh --runs 5 --parallelism 2 --timeout 60 --rss-limit-mb 8192
```

`--timeout` accepts either a bare number or an explicit unit suffix. A bare number is treated as **minutes**, so `--timeout 15` means 15 minutes, not 15 seconds. If you want seconds, write the unit explicitly, for example `--timeout 15s`.

`--rss-limit-mb` passes an explicit `-rss_limit_mb` to libFuzzer. Use `8192` for the original 8 GiB behavior, raise it (for example to `12288`) for longer stable runs, or set `0` only if you intentionally want to disable libFuzzer's RSS cap.

This means: run 5 total rounds, but keep at most 2 rounds active at the same time.

If you really want all 5 rounds to run at once, use:

```shell
./run_live555_fuzz.sh --runs 5 --parallelism 5 --timeout 60 --rss-limit-mb 8192
```

Or set the starting port for auto-selection:

```shell
./run_live555_fuzz.sh --runs 5 --parallelism 2 --port-start 8554 --timeout 60 --rss-limit-mb 8192
```

Each round writes its own log to `./artifacts/results-live555_<Mon-DD_HH-MM-SS>/<Mon-DD_HH-MM-SS>_runXX_portYYYY/run.log` and artifacts to `./artifacts/results-live555_<Mon-DD_HH-MM-SS>/<Mon-DD_HH-MM-SS>_runXX_portYYYY/artifacts/`.

If the target binary was built with LLVM profile instrumentation, each round also leaves raw profile files under `./artifacts/results-live555_<Mon-DD_HH-MM-SS>/<Mon-DD_HH-MM-SS>_runXX_portYYYY/artifacts/llvm-profraw/` and best-effort postprocess outputs under `./artifacts/results-live555_<Mon-DD_HH-MM-SS>/<Mon-DD_HH-MM-SS>_runXX_portYYYY/artifacts/llvm-cov/`:

- `merged.profdata` from `llvm-profdata merge -sparse`
- `export.json` from `llvm-cov export`
- `status.txt` describing whether the postprocess ran, skipped, or failed

The launcher now creates the top-level `results-live555_<Mon-DD_HH-MM-SS>`-style folder before fuzzing starts, stores each round directory inside it during execution, and then generates a matching `.tar.gz` archive for every round when fuzzing finishes. `summary.csv` is also written into the same top-level folder.

By default, Live555 runs are serialized to avoid TCP-ready stalls caused by multiple instances sharing the same network namespace. If you really need parallel rounds, set `LIVE555_ALLOW_PARALLEL=1` and make sure each run is isolated in its own container or network namespace.

For coverage-normalized experiments, `run_live555_parallel_docker.sh` now prefers the `live555-sgfuzz-profraw` image automatically when it is available, because that image contains the LLVM profile-instrumented target and the `llvm-profdata` / `llvm-cov` tools needed for `l_abs` / `b_abs` export.

The fuzz launcher also prefers libFuzzer's own `-max_total_time` for bounded runs and only uses the shell `timeout` command as a watchdog, which improves the chance that `.profraw` files flush cleanly before postprocessing.

### Parallel isolation mode

The strict way to keep concurrency is: one round = one container = one network namespace.
In this mode, every worker can reuse the same RTSP port number because the namespaces are isolated; for this Live555 target, keep `HFND_TCP_PORT=8554` for all workers and do not manually offset it to `8555`, `8556`, and so on.

Example:

```shell
mkdir -p ./artifacts/worker1 ./artifacts/worker2

docker run --rm -d --network none --name live555-worker1 \
  -e HFND_TCP_PORT=8554 \
  -e LIVE555_ALLOW_PARALLEL=1 \
  -v "$PWD":/work -w /work live555:latest \
  bash -lc './run_live555_fuzz.sh ./in-rtsp ./artifacts/worker1 --runs 1 --parallelism 1 --timeout 15 --rss-limit-mb 8192'

docker run --rm -d --network none --name live555-worker2 \
  -e HFND_TCP_PORT=8554 \
  -e LIVE555_ALLOW_PARALLEL=1 \
  -v "$PWD":/work -w /work live555:latest \
  bash -lc './run_live555_fuzz.sh ./in-rtsp ./artifacts/worker2 --runs 1 --parallelism 1 --timeout 15 --rss-limit-mb 8192'
```

Do not change the port per worker in this isolated-container mode. The wrapper already keeps the workers separated by namespace, so the port number is only a local target setting, not a global concurrency key.

In the examples above, `--timeout 15` means 15 minutes because the launcher follows the same convention as the shell parser: bare numbers are interpreted as minutes. For a 15-second cap, use `--timeout 15s` instead.

If you do not want Docker, honggfuzz also supports native Linux namespace isolation flags: `--linux_ns_net=yes --linux_ns_pid --linux_ns_ipc`. The key requirement is that each concurrent instance must not share the same network namespace.

If you already have a working `live555:latest` image, you can reuse it directly with `./run_live555_parallel_docker.sh`; rebuild only if you changed the Dockerfile, the in-container toolchain, or need a fresh image layer.

After all rounds finish, the launcher writes a consolidated `summary.csv` into the same `results-live555_*` folder with `run_index`, `port`, `status`, `exit_code`, `timeout_triggered`, `startup_ready`, `startup_reason`, `failure_reason`, `phase`, `fuzz_started`, `cov`, `ft`, `states`, `leaves`, `exec_per_sec`, `crash_artifacts`, `timeout_artifacts`, `oom_artifacts`, `leak_artifacts`, `bug_artifacts`, `unique_bug_signatures`, and `mutation_graph_edges` for each round.

The `startup_ready` and `startup_reason` columns make it obvious whether the target server ever reached the accept-ready state before fuzzing.

If `timeout` actually fired, the launcher now records it directly as `timeout_triggered=yes` and writes a timeout-specific `failure_reason` such as `timeout_triggered_before_fuzz` or `timeout_triggered_after_fuzz_start`.

`mutation_graph_edges` is derived from SGFuzz's existing `mutation_graph_file` output. It counts the `A -> B` edges in the per-round DOT file and is the closest built-in edge-style metric available here.

`leaves` and `exec_per_sec` are extracted from the SGFuzz progress log. `crash_artifacts` counts the per-round `crash-*` files dumped by SGFuzz when a crash is discovered, while `timeout_artifacts`, `oom_artifacts`, and `leak_artifacts` count the corresponding `timeout-*`, `oom-*`, and `leak-*` dumps.

`bug_artifacts` is the combined count of crash, OOM, and leak artifacts, and `unique_bug_signatures` deduplicates those failure artifacts by content hash so the report can separate repeated hits from distinct bug signatures.

The `phase` column makes startup problems obvious:

- `fuzzing` means the target entered the fuzzing loop normally.
- `no_fuzz_start` means the process exited cleanly but never reached fuzzing.
- `timeout_before_fuzz` means the launcher timed out before fuzzing started.
- `killed_before_fuzz` means the process was terminated by a signal before fuzzing started.
- `failed_before_fuzz` means the round failed before fuzzing began.
- `fuzzing_error` means fuzzing started, but the round still exited with a non-zero code.

### Adapting to ChatAFL-style metrics

If you need to compare SGFuzz Live555 runs against a ChatAFL-style benchmark table,
you can run the adapter manually:

```shell
cd /home/ckt/Documents/000_2026_test_dev/SGFuzz/example/live555
python3 export_chatAFL_metrics.py ./artifacts/results-live555_<Mon-DD_HH-MM-SS>
```

This writes `chatAFL_compatible_metrics.csv` into the given results directory.

`run_live555_parallel_docker.sh` now invokes this adapter automatically after a
parallel campaign and emits:

- one per-result file under each `results-live555_*` directory
- one aggregate file at the parallel root: `parallel-results-live555_*/chatAFL_compatible_metrics.csv`

After writing those CSVs, the parallel launcher also validates that every run
produced a non-empty `artifacts/llvm-cov/export.json` and that the exported
ChatAFL-style rows have non-empty `l_abs` / `b_abs`. If either check fails, the
script reports the failing path and exits non-zero.

Important semantic notes:

- ChatAFL `nodes` / `edges` count IPSM graph nodes / IPSM graph edges
- SGFuzz `states` and `mutation_graph_edges` are kept as SGFuzz-native metrics
- Therefore the adapter no longer fills ChatAFL-style `nodes` / `edges` from
  SGFuzz `states` / `mutation_graph_edges`; those columns are left empty and
  the CSV explains the semantic mismatch via `nodes_source` / `edges_source`
- `hangs` is mapped from SGFuzz `timeout_artifacts`
- `l_abs` / `b_abs` are only filled when LLVM coverage export files are present;
  otherwise they remain empty and the CSV records the reason in `l_abs_source`
  and `b_abs_source`

This means the adapter gives you one comparable table, but it does not pretend that
all SGFuzz-native metrics are strictly identical to ChatAFL benchmark semantics.

### How to report results

When writing up the experiment, you can describe the main progress indicators like this:

- `cov` indicates the current coverage achieved by the fuzzing campaign; a higher value means the target execution space has been explored more broadly.
- `ft` indicates the number of libFuzzer features discovered so far; it is a useful proxy for how diverse the input-triggered behavior is.
- `states` indicates the number of SGFuzz state-feedback states reached; it reflects how much protocol/state space has been explored.

A concise reporting sentence can be:

```text
During the fuzzing campaign, we tracked libFuzzer coverage (`cov`), feature count (`ft`), and SGFuzz state-feedback states (`states`). The campaign was considered more effective when `cov` and `ft` continued to increase, while `states` showed broader protocol-state exploration.
```

If you need a more concrete result summary, you can record each round as:

```text
Run 01: cov=..., ft=..., states=...
Run 02: cov=..., ft=..., states=...
...
Run 05: cov=..., ft=..., states=...
```

You can override the corpus and artifact directories:

```shell
./run_live555_fuzz.sh /path/to/corpus /path/to/artifacts
```

```shell
sudo docker build . -t live555
sudo docker run -it --privileged live555 /bin/bash
cd experiments/live555-sgfuzz/testProgs/
ASAN_OPTIONS=alloc_dealloc_mismatch=0 ./testOnDemandRTSPServer -close_fd_mask=3 -detect_leaks=0 -dict=${WORKDIR}/rtsp.dict -only_ascii=1 ${WORKDIR}/in-rtsp/
```