# Simulation

Running the UVC's own tests, and the example. Both directories carry the same
Makefile, so the targets below work in either.

```bash
cd tb       && make          # the UVC's self-test: five link widths at once
cd example  && make          # the integration example
```

Vivado is found automatically — the Makefile sources `settings64.sh` itself, so
nothing needs to be on `PATH` first. It picks the highest-sorting version under
`/tools/Xilinx/Vivado`; override with `make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2`.

## Targets

| Target | What it does |
| --- | --- |
| `make` / `make run` | compile, elaborate, run `TEST` to completion in batch |
| `make regress` | the protocol-checker test, then every test in `REGRESS_TESTS` |
| `make check-protocol` | negative test: break each protocol rule, require it to be caught (`tb/` only) |
| `make waves` | open the waveforms in Vivado, simulating first if there are none |
| `make gui` | run interactively in the XSIM GUI |
| `make compile` / `make elab` | stop after that step |
| `make clean` | remove simulation artifacts |
| `make help` | the same list, from the Makefile |

Common overrides: `TEST=<uvm_test>`, `SEED=<n>`, `UVM_VERBOSITY=<UVM_*>`,
`VIVADO_PATH=<path>`.

```bash
make TEST=axi_stream_backpressure_test SEED=42 UVM_VERBOSITY=UVM_HIGH
```

## Pass and fail

XSIM exits 0 even after a `UVM_FATAL` — the test called `$finish`, it did not
crash — so a script checking only the exit status will call a failing test a
pass. Every top module therefore prints a banner, and the Makefile greps for it:

```
============================================================
 UVM-TB SUMMARY  |  module: axi_stream  |  top: axi_stream_tb_top
 test    : axi_stream_multiwidth_test
 result  : PASSED
 fatals=0 errors=0 warnings=0
============================================================
```

`make run` and `make regress` fail the invocation when that line says `FAILED`,
which is what makes them usable in CI.

## Waveforms

`make waves` opens `waves.wdb` in the Vivado window.

The database is a real file target, so the recipe that produces it runs **only
when it is missing**: the first call simulates and then opens, and every later
call opens straight away. Delete the database (or `make clean`) to force a fresh
capture — worth remembering after editing the design, since make cannot tell
that an existing database has gone stale.

A failing test still opens its waveforms, which is the point of the target;
`make run` stays the pass/fail gate, and `make waves` prints a note when the run
it is showing you failed.

### Keeping your layout

Arrange the waveform how you like it and save it from the GUI (File > Save
Waveform Configuration) as `<TOP>.wcfg` — the name the GUI offers by default.
Every later `make waves` reopens with it via `--view`, so the layout survives
re-running the simulation.

`waves.wcfg` is accepted as a fallback name, `WAVE_CFG=` overrides both, and
`make clean` deliberately does **not** delete `*.wcfg`: a hand-made arrangement
is not a build artifact.

## The self-test

`tb/` exists to test the UVC itself. Five differently parameterized links are
built, driven and checked inside a **single simulation** — the widths are module
and class parameters, not `` `define ``s, so all five elaborate together.

| Env | TDATA | TID | TDEST | TUSER | Optional signals |
| --- | --- | --- | --- | --- | --- |
| `env_w4` | 4 B (32b) | 4 | 4 | 4 | all present |
| `env_w8` | 8 B (64b) | 8 | 4 | 8 | all present |
| `env_w12` | 12 B (96b) | 8 | 8 | 12 | all present |
| `env_w16` | 16 B (128b) | 8 | 8 | 16 | all present |
| `env_min` | 4 B (32b) | — | — | — | TLAST only |

12 bytes is in the list on purpose: it is not a power of two, which is legal
AXI4-Stream and is exactly the case a UVC that assumes shifts instead of
multiplies gets wrong. `env_min` is the opposite extreme —
TDATA/TVALID/TREADY/TLAST and nothing else — exercising the paths where optional
signals are absent.

Each link is a master agent driving a FIFO, a slave agent backpressuring its
output, and a scoreboard requiring every beat and every packet to come back
unchanged and in order.

| Test | Covers |
| --- | --- |
| `axi_stream_smoke_test` | full-rate traffic, no backpressure |
| `axi_stream_multiwidth_test` | all five widths, randomly drawn backpressure and pacing |
| `axi_stream_backpressure_test` | every built-in ready model, one per link |
| `axi_stream_no_ready_test` | TREADY held low 300 cycles, then released |
| `axi_stream_sparse_test` | null and position byte payloads |
| `axi_stream_reset_test` | ARESETn pulsed mid-traffic, then recovery |

All six pass on five seeds (1, 7, 42, 12345, 99999) with zero protocol
assertion failures across all ten interfaces, and `make check-protocol` reports
11 of 11 scenarios behaving correctly — so the assertions are known to be alive
rather than merely silent. See [Protocol checks](protocol-checks.md).

## The example

`example/` is a single 8-byte link around a register slice, written to be read
and copied.

| Test | Covers |
| --- | --- |
| `example_base_test` | random packets, 60% random backpressure |
| `example_backpressure_test` | burst backpressure and a bursty source |
| `example_directed_test` | a specific 21-byte payload on an 8-byte link |

## Adding sources

If your testbench needs other files compiled alongside it — sub-modules your DUT
instantiates, say — list them in `extra_files.f`, one path per line. Unlike
`filelist.f`, that file is created once and never regenerated, so hand edits
survive.
