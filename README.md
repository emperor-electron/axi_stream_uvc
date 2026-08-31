# axi_stream_uvc

A reusable UVM verification component for AMBA AXI4-Stream (ARM IHI 0051A),
scaffolded with [uvm-tb](../uvm-tb) and built out into a full UVC.

It drives either end of a link, applies programmable backpressure, polices the
protocol with assertions that are themselves tested, and works at any TDATA
width without a single compile-time definition.

- **Drives a DUT's slave port** — an `AXIS_MASTER` agent sources TVALID and the
  whole payload.
- **Drives a DUT's master port** — an `AXIS_SLAVE` agent sources TREADY, and is
  where backpressure is programmed.
- **Cannot violate the protocol** — the handshake, reset and byte-encoding rules
  are asserted in the interface, and the assertions are proven to fire by a
  negative test (`make check-protocol`).
- **Programmable backpressure** — six built-in TREADY models plus a policy class
  to write your own, swappable while the simulation runs.
- **Parameterizable widths** — TDATA/TID/TDEST/TUSER are SystemVerilog
  parameters, so five differently sized links elaborate into one snapshot and
  are all exercised by one `make` run.
- **One interface file, synthesizable too** — the clocking blocks, assertions
  and configuration API sit behind `` `ifdef AXI_STREAM_IF_SIM ``, so the same
  `axi_stream_if.sv` is both the UVC's virtual interface and an interface you
  can instantiate in RTL.

Only XSIM (Vivado 2023.2) has been used so far; see
[Simulator notes](#simulator-notes) for the two XSIM bugs this code works
around.

## Using it in your project

The fastest way in is [`example/`](example) — a complete, runnable testbench
around a small DUT, written to be read. `example_tb_top.sv` and
`example_base_test.sv` carry numbered comments walking through connecting the
UVC and configuring it; copy the pair and swap in your own design.

```bash
cd example && make
```

The rest of this section is the same material in prose.

```bash
export AXI_STREAM_UVC_ROOT=/path/to/axi_stream_uvc
```

```bash
xvlog -sv -L uvm -f $AXI_STREAM_UVC_ROOT/src/axi_stream_uvc.f -f my_tb.f
```

That filelist is the entire component: `axi_stream_if.sv` and
`axi_stream_pkg.sv`. Nothing else in this repository is needed, and the UVC
depends on nothing but UVM.

Instantiate an interface per link and hand it to an agent of matching width:

```systemverilog
// In the testbench top -- widths are parameters, so as many differently
// sized links as you like can coexist in one compilation.
axi_stream_if #(.DATA_BYTES(8), .ID_WIDTH(8), .DEST_WIDTH(4), .USER_WIDTH(8))
    axis (.aclk(aclk), .aresetn(aresetn));

my_dut u_dut (.aclk, .aresetn,
              .s_axis_tvalid(axis.tvalid), .s_axis_tready(axis.tready),
              .s_axis_tdata (axis.tdata),  .s_axis_tlast (axis.tlast), ...);

initial
  uvm_config_db#(virtual axi_stream_if #(8, 8, 4, 8))::set(
      null, "uvm_test_top.env.agt", "vif", axis);
```

```systemverilog
// In the env -- one agent, parameterized to match the interface.
axi_stream_agent #(.DATA_BYTES(8), .ID_WIDTH(8), .DEST_WIDTH(4), .USER_WIDTH(8)) agt;

function void build_phase(uvm_phase phase);
  axi_stream_config cfg = axi_stream_config::type_id::create("cfg");
  cfg.role = AXIS_MASTER;              // source transfers into the DUT
  cfg.set_beat_delay(0, 3);            // 0-3 idle cycles between beats
  uvm_config_db#(axi_stream_config)::set(this, "agt", "cfg", cfg);
  agt = axi_stream_agent #(8, 8, 4, 8)::type_id::create("agt", this);
endfunction
```

```systemverilog
// In a test -- sequences are unparameterized, so this is the same code
// whatever the link width is.
axi_stream_random_seq seq = axi_stream_random_seq::type_id::create("seq");
assert (seq.randomize() with { num_packets == 20; });
seq.start(agt.sqr);
```

The agent reconciles `cfg` with its own parameters at build time, so a config
that disagrees with the interface it is attached to is reported rather than
silently truncating payloads.

## How it is put together

The one design decision everything else follows from: **only the three classes
that touch a virtual interface are parameterized.**

`virtual axi_stream_if #(4,...)` and `#(16,...)` are different SystemVerilog
types, so anything holding one has to be parameterized too. That is unavoidable
for the driver and monitor — and stops there:

| Parameterized by link width | Not parameterized |
| --- | --- |
| `axi_stream_master_driver` | `axi_stream_seq_item`, `axi_stream_packet` |
| `axi_stream_slave_driver` | `axi_stream_config`, `axi_stream_ready_policy` |
| `axi_stream_monitor` | `axi_stream_sequencer`, the whole sequence library |
| `axi_stream_agent` (holds the above) | `axi_stream_coverage` |

The transaction carries TDATA/TKEEP/TSTRB as **dynamic arrays sized at run time**
from the config, rather than as vectors of some fixed maximum width. That is
what keeps it unparameterized, and it is why one sequence library, one
scoreboard and one coverage model serve every width: a 12-byte beat and a
16-byte beat are the same type.

`tb/axi_stream_env.sv` shows the pattern for a testbench holding several link
widths at once — an unparameterized `axi_stream_env_base` holding everything a
test touches, and a parameterized `axi_stream_env #(...)` that adds the agents
and publishes its sequencer up into the base. A test can then keep
`axi_stream_env_base envs[$]` containing a 4-byte and a 16-byte link side by
side and start the same sequence on both.

### One file for simulation and synthesis

`axi_stream_if.sv` is meant to be the only AXI4-Stream interface in your
project — the UVC's virtual interface *and* the interface you wire up inside a
design. Everything a synthesis tool would reject (clocking blocks, assertions,
coverpoints, the string and `%m` reporting helpers) is inside
`` `ifdef AXI_STREAM_IF_SIM ``; what remains is the signal set and two
synthesizable modports:

```systemverilog
axi_stream_if #(.DATA_BYTES(8)) axis (.aclk(clk), .aresetn(rstn));
my_producer u_src (.m_axis(axis.dut_master));
my_consumer u_snk (.s_axis(axis.dut_slave));
```

That macro is set automatically from `XILINX_SIMULATOR`, which xvlog and xelab
predefine and Vivado synthesis does not — so neither flow needs anything on the
command line. On a simulator that does not define it, pass
`+define+AXI_STREAM_IF_SIM`.

Verified both ways: `synth_design` for a `xc7z045` accepts a design
instantiating the interface with 0 errors and 0 critical warnings, and forcing
`AXI_STREAM_IF_SIM` on during synthesis makes it fail — so the guard is known
to be load-bearing rather than merely present.

New coverpoints or formal properties belong inside that guard too.

### Optional signals

TID/TDEST/TUSER presence follows from the widths: a width of `0` means the link
does not carry that signal. The signal is still declared (clamped to 1 bit) so
the virtual-interface type stays well formed, but it is driven to 0 and neither
the UVC nor the assertions check it.

TKEEP/TSTRB/TLAST presence is a **config** field, not a parameter, because it
does not change any signal's size — which keeps the number of distinct
virtual-interface types to a minimum.

## Backpressure

TREADY has no protocol restrictions of its own, so every model here is legal by
construction. The slave driver asks its policy for the *next* cycle's TREADY
once per ACLK edge, before this cycle's TVALID can influence it — which makes it
structurally impossible for a model to create a combinational TREADY-from-TVALID
path and hide a deadlock real hardware would hit.

```systemverilog
cfg.set_ready_mode(AXIS_READY_BURST, .burst_beats(8), .stall_cycles(3));
```

| Mode | Behaviour |
| --- | --- |
| `AXIS_READY_ALWAYS` | TREADY tied high; no backpressure |
| `AXIS_READY_NEVER` | TREADY tied low; the sink never accepts |
| `AXIS_READY_RANDOM` | per-cycle coin flip at `ready_percent` |
| `AXIS_READY_DUTY` | square wave: `ready_cycles` high, `stall_cycles` low |
| `AXIS_READY_BURST` | accept `burst_beats` *transfers*, then stall `stall_cycles` |
| `AXIS_READY_DELAY` | hold off `delay_min..delay_max` cycles after TVALID |

Measured TREADY duty cycles from one `axi_stream_backpressure_test` run, which
is how you can tell the models do what they claim:

```
AXIS_READY_DUTY(1 on/3 off)      TREADY high  46 of 183 cycles (25%)
AXIS_READY_RANDOM(30%)           TREADY high  60 of 183 cycles (32%)
AXIS_READY_BURST(4 beats/6 stall) TREADY high 104 of 183 cycles (56%)
AXIS_READY_DELAY(0..8)           TREADY high  32 of 183 cycles (17%)
```

For anything these do not cover — a recorded trace, a credit counter,
backpressure on one TDEST only — extend `axi_stream_ready_policy`, override
`next_ready()`, and assign it to `cfg.ready_policy`. The policy class is
deliberately unparameterized, so one custom model works against every link in
the testbench, and the slave driver re-reads the handle every cycle so a test
can swap models mid-run:

```systemverilog
env.set_backpressure(AXIS_READY_NEVER);   // jam the link solid
// ...
env.set_backpressure(AXIS_READY_ALWAYS);  // and let it drain
```

Source-side pacing is the counterpart: each beat's `delay` field is the number
of idle cycles before it is offered, drawn from
`cfg.min_beat_delay..max_beat_delay`. Leaving both at 0 streams back-to-back at
full rate.

## Protocol checks

`axi_stream_if.sv` carries 20 assertions (the TDATA X-check replicated per
byte) covering the handshake rules
(§2.2.1), reset behaviour (§2.7.2), the reserved byte encoding (§2.4.3) and
X-propagation. They are plain SystemVerilog with no UVM in them: each failure
bumps `protocol_error_count`, and the monitor's `check_phase` turns a non-zero
count into a `UVM_ERROR` so violations fail the test rather than scrolling past
in a log. That also means the interface is usable in a non-UVM testbench.

They police the DUT and the UVC equally — whichever side drives the signal that
breaks a rule is the side the failure points at.

Two things are worth knowing about how they are written:

- **TVALID low during reset** is qualified on reset having already been low at
  the previous edge, giving a synchronous master one ACLK edge to react to an
  asynchronously asserted reset — the same cycle a real sync-reset flop takes. A
  master that keeps offering a transfer *through* reset still fails.
- **TDATA is only X-checked on lanes TKEEP marks as valid**, because AXI4-Stream
  leaves a null byte's TDATA explicitly undefined. `make check-protocol`
  includes a scenario proving an X in a null byte stays quiet.

## Running the self-test

```bash
cd tb && make regress
```

Needs Vivado on the machine (the Makefile sources `settings64.sh` itself);
override with `make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ...`.

| Target | What it does |
| --- | --- |
| `make` | compile, elaborate, run `axi_stream_multiwidth_test` to completion |
| `make regress` | the protocol-checker test, then every test below |
| `make check-protocol` | negative test: break each rule, require it to be caught |
| `make TEST=<name>` | one test |
| `make waves` | open the waveforms in Vivado, simulating first if there are none |
| `make gui` | run interactively in the XSIM GUI |

### Waveforms

`make waves` opens `waves.wdb` in the Vivado window. `waves.wdb` is a real file
target, so the recipe that produces it runs only when it is missing: the first
call simulates and then opens, and every later call opens straight away. Delete
the database (or `make clean`) to force a fresh capture — worth remembering
after editing the design, since make cannot tell that an existing database has
gone stale.

A failing test still opens its waveforms, which is the point of the target;
`make` / `make run` / `make regress` remain the pass/fail gates, and `make
waves` prints a note when the run it is showing you failed.

Arrange the waveform how you like and save it from the GUI as
`axi_stream_tb_top.wcfg` — `<TOP>.wcfg` is what the GUI offers by default — and
every later `make waves` reopens with it via `--view`, so the layout survives
re-running the simulation. `waves.wcfg` is accepted as a fallback name,
`WAVE_CFG=` overrides both, and `make clean` deliberately does not delete
`*.wcfg`: a hand-made arrangement is not a build artifact.

| Test | What it covers |
| --- | --- |
| `axi_stream_smoke_test` | full-rate traffic, no backpressure |
| `axi_stream_multiwidth_test` | all five widths, randomly drawn backpressure and pacing |
| `axi_stream_backpressure_test` | every built-in ready model, one per link |
| `axi_stream_no_ready_test` | TREADY held low for 300 cycles, then released |
| `axi_stream_sparse_test` | null and position byte payloads |
| `axi_stream_reset_test` | ARESETn pulsed mid-traffic, then recovery |

### The five parameter combinations

`axi_stream_tb_top.sv` instantiates all of these at once. They are module and
class parameters — **not** `` `define ``s — so one compilation and one
simulation covers the lot, rather than five recompiles with a different macro
each time.

| Env | TDATA | TID | TDEST | TUSER | TKEEP/TSTRB/TLAST |
| --- | --- | --- | --- | --- | --- |
| `env_w4` | 4 B (32b) | 4 | 4 | 4 | all present |
| `env_w8` | 8 B (64b) | 8 | 4 | 8 | all present |
| `env_w12` | 12 B (96b) | 8 | 8 | 12 | all present |
| `env_w16` | 16 B (128b) | 8 | 8 | 16 | all present |
| `env_min` | 4 B (32b) | — | — | — | TLAST only |

TKEEP and TSTRB are `DATA_BYTES` wide wherever present, and TUSER follows the
spec's recommendation of one bit per byte. 12 bytes is in the list on purpose:
it is not a power of two, which is legal AXI4-Stream and is exactly the case a
UVC that assumes shifts instead of multiplies gets wrong. `env_min` is the
opposite extreme — TDATA/TVALID/TREADY/TLAST and nothing else — which exercises
the paths where optional signals are absent.

Each link is a master agent driving a FIFO, a slave agent backpressuring its
output, and a scoreboard requiring every beat and every packet to come back
unchanged and in order.

### What a passing run has established

All six tests pass on five seeds (1, 7, 42, 12345, 99999), with zero protocol
assertion failures across all ten interfaces, and `make check-protocol` reports
11 of 11 scenarios behaving correctly — so the assertions above are known to be
alive rather than merely silent.

## Repository layout

```
src/                        the reusable UVC -- this is what other projects compile
  axi_stream_if.sv            parameterized interface, clocking blocks, assertions
  axi_stream_pkg.sv           the package; includes everything below
  axi_stream_types.sv         enums, typedefs, capacity constants
  axi_stream_ready_policy.sv  backpressure contract + built-in models
  axi_stream_config.sv        role, geometry, pacing, backpressure
  axi_stream_seq_item.sv      one beat, sized at run time
  axi_stream_packet.sv        a TLAST-delimited frame
  axi_stream_sequencer.sv     unparameterized
  axi_stream_master_driver.sv sources TVALID + payload
  axi_stream_slave_driver.sv  sources TREADY from the policy
  axi_stream_monitor.sv       beat and packet analysis ports
  axi_stream_coverage.sv      width, occupancy, framing, stall coverage
  axi_stream_agent.sv         where parameterized meets unparameterized
  axi_stream_seq_lib.sv       beat / packet / payload / sparse / random
  axi_stream_uvc.f            drop this into another testbench's compile

example/                    a runnable integration example, written to be read
  example_tb_top.sv           STEP 1-5: interfaces, DUT wiring, config DB
  example_base_test.sv        STEP 1-5: configs, backpressure, stimulus
  example_env.sv              STEP 1-4: agents and analysis ports
  example_scoreboard.sv       consuming the beat and packet analysis ports
  example_tb_pkg.sv           the widths, written down once
  example_dut.sv              a register slice, so backpressure has an effect
  Makefile filelist.f wave.tcl

tb/                         self-test; no consuming project needs any of it
  axi_stream_fifo.sv          a protocol-correct FIFO to talk to
  axi_stream_link.sv          one link: two interfaces + a FIFO, parameterized
  axi_stream_tb_ctrl_if.sv    sole owner of ARESETn; lets a test pulse reset
  axi_stream_env.sv           parameterized env + unparameterized base
  axi_stream_scoreboard.sv    beat-level and packet-level checks
  axi_stream_test_lib.sv      the six tests
  axi_stream_if_check_tb.sv   negative test for the assertions (no UVM)
  axi_stream_tb_top.sv        five links, one simulation
  Makefile filelist.f wave.tcl
```

## Simulator notes

XSIM 2023.2 needed two workarounds, both of which would fail silently or hang
rather than produce an error, so they are called out here and commented at the
source:

- **Property formal arguments are ignored.** `property p(sig); ... endproperty`
  compiles and elaborates, and XSIM then drops every assertion that uses it with
  only a warning — checks that look present and do nothing. Every assertion
  here is written out one signal at a time instead.
- **The constraint solver hangs** on a `soft` constraint inside a `foreach` over
  a rand dynamic array, once the other `foreach` constraints on the beat are
  present — not a slow solve, an infinite one. `axi_stream_seq_item` uses a
  plain `dense` knob gating hard implications instead, which behaves the same
  from a user's point of view. The same solver also declares
  `(tkeep[i]==0) -> (tstrb[i]==0)` unsatisfiable in that company, so the byte
  encoding rule is stated as its contrapositive.

The Makefile is structured with a `SIM` variable and an `ifeq` block per
simulator, so Questa/VCS/Xcelium can be added without touching the rest of it.
