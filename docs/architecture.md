# Architecture

How the UVC is built, and why. Read this before extending it.

## The one decision everything follows from

`virtual axi_stream_if #(4,...)` and `virtual axi_stream_if #(16,...)` are
**different SystemVerilog types**. Anything holding one must be parameterized
too — and if you let that spread, every sequence, scoreboard and coverage model
in your testbench ends up parameterized by a width it does not care about.

So the parameterization is confined to the components that genuinely touch a
virtual interface, and stops there:

| Parameterized `#(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH)` | Not parameterized |
| --- | --- |
| `axi_stream_if` | `axi_stream_seq_item`, `axi_stream_packet` |
| `axi_stream_master_driver` | `axi_stream_config`, `axi_stream_ready_policy` |
| `axi_stream_slave_driver` | `axi_stream_sequencer` |
| `axi_stream_monitor` | the whole sequence library |
| `axi_stream_agent` (holds the three above) | `axi_stream_coverage` |

**The agent is the seam.** Below it, three components hold a virtual interface.
Above it, nothing does — so stimulus, checking and coverage are written once and
work at every width.

What makes that possible is the transaction: `axi_stream_seq_item` carries
TDATA/TKEEP/TSTRB as **dynamic arrays sized at run time** from the config,
rather than as vectors of some fixed maximum width. A 12-byte beat and a 16-byte
beat are the same type. TID/TDEST/TUSER are vectors of the UVC's maximum
supported width, constrained to zero above the link's real width, which keeps
the ergonomic `item.tid == 3` style of constraint working.

## Class map

```
src/
  axi_stream_if.sv             interface: signals, clocking blocks, assertions
  axi_stream_types.sv          enums, typedefs, capacity constants
  axi_stream_ready_policy.sv   backpressure contract + six built-in models
  axi_stream_config.sv         role, geometry, pacing, backpressure, checks
  axi_stream_seq_item.sv       one beat, sized at run time
  axi_stream_packet.sv         a TLAST-delimited frame
  axi_stream_sequencer.sv      unparameterized, carries the config
  axi_stream_master_driver.sv  sources TVALID and the payload
  axi_stream_slave_driver.sv   sources TREADY from the policy
  axi_stream_monitor.sv        beat and packet analysis ports, protocol reporting
  axi_stream_coverage.sv       width, occupancy, framing and stall coverage
  axi_stream_agent.sv          where parameterized meets unparameterized
  axi_stream_seq_lib.sv        beat / packet / payload / sparse / random
  axi_stream_pkg.sv            the package; includes the above in dependency order
```

### The agent

```systemverilog
axi_stream_agent #(.DATA_BYTES(8), .ID_WIDTH(4), .DEST_WIDTH(4), .USER_WIDTH(8)) master_agent;
```

| Handle | Present when |
| --- | --- |
| `monitor` | always — a passive agent still checks and covers |
| `coverage` | `agent_config.coverage_enable` |
| `sequencer` | active |
| `master_driver` | active and `role == AXIS_MASTER` |
| `slave_driver` | active and `role == AXIS_SLAVE` |

The role decides which driver is *constructed*. The other is never built, so
each interface signal keeps exactly one driver and both ends can share one
interface type.

## The virtual interface path

Three hops. The middle one is what people get wrong.

```
your tb_top      set(null, "*", "vif_in", axis_in)             physical interface
     |
your env         get(this, "", "vif_in", vif_in)               env claims it
     |           set(this, "master_agent", "vif", vif_in)      re-published per agent
     |
agent            get(this, "", "vif", vif)                     agent claims it
     |           set(this, "*", "vif", vif)                    fanned out to children
     |
driver, monitor  get(this, "", "vif", vif)
```

The env re-publishes under the field name `"vif"`, scoped to each agent's
instance name. That is what lets one agent receive the DUT's slave port and the
other its master port while both use the same key. The agent then fans out to
`"*"`, so the driver, monitor and coverage collector need no plumbing of their
own.

`agent_config` travels the identical path, which is why the driver and monitor
never need telling anything twice.

**The type must match exactly at every hop.** `uvm_config_db` is keyed on type,
so a `set` of `#(8,4,4,8)` and a `get` of `#(8,4,4,0)` do not fail loudly — the
`get` returns 0 and the agent reports `NOVIF`. Declaring the widths once and
naming the dependent types is the defence; see
[Getting started](getting-started.md#2-write-your-widths-down-once).

## Race-free driving and sampling

The interface's clocking blocks use `default input #1step output #0`:

- `input #1step` samples in the Preponed region — the value that settled
  *before* the edge, exactly what a real flop sees.
- `output #0` drives in the Re-NBA region *after* the edge, so a DUT's
  `always_ff` sampling that same edge still sees the old value.

Together they make driving and sampling race-free without depending on the
timescale, which matters for a UVC reused at whatever clock period its host
testbench happens to run.

Back-to-back streaming falls out of this rather than from a special case: after
a handshake the master driver tentatively writes TVALID low, then asks for the
next beat. If the sequencer answers in zero time, the payload write overwrites
that low before the clocking block applies either — so TVALID simply stays high
and the link runs at full rate. If the sequencer blocks, the low wins and the
link idles legally.

## One file for simulation and synthesis

`axi_stream_if.sv` is meant to be the only AXI4-Stream interface in your
project: the UVC's virtual interface *and* the interface you instantiate inside
a design.

Everything a synthesis tool would reject — clocking blocks, assertions,
coverpoints, the string and `%m` reporting helpers — sits behind
`` `ifdef AXI_STREAM_IF_SIM ``. What remains is the signal set and two
synthesizable modports:

```systemverilog
axi_stream_if #(.DATA_BYTES(8)) axis (.aclk(clk), .aresetn(rstn));
my_producer u_src (.m_axis(axis.dut_master));
my_consumer u_snk (.s_axis(axis.dut_slave));
```

The macro is set automatically from `XILINX_SIMULATOR`, which xvlog and xelab
predefine and Vivado synthesis does not — so neither flow needs anything on the
command line. On a simulator that does not define it:

```bash
vlog +define+AXI_STREAM_IF_SIM ...
```

The UVC needs the simulation half, so a UVC compile without that macro fails
loudly at the first reference to `mst_cb` rather than subtly.

Both directions are verified: `synth_design` for an `xc7z045` accepts a design
instantiating the interface with 0 errors and 0 critical warnings, and forcing
`AXI_STREAM_IF_SIM` on during synthesis makes it fail — so the guard is known to
be load-bearing rather than merely present.

New coverpoints or formal properties belong inside that guard too.

## Naming

Class handles are spelled out: `master_driver`, not `mst_drv`; `monitor`, not
`mon`; `sequencer`, `coverage`, `scoreboard`, `master_agent`. Two names cannot
be, because SystemVerilog reserves them:

| Wanted | Reserved by | Used instead |
| --- | --- | --- |
| `config` | `config` / `endconfig` | `agent_config`, `master_config`, `slave_config` |
| `sequence` | assertion sequences | `random_sequence`, `packet_sequence`, `directed_sequence` |

Virtual-interface handles stay `vif` / `vif_src` / `vif_snk`: an interface is
not a class, and `vif` is near-universal in UVM.

Config-DB field names track the handles they fill, so the key is
`"agent_config"`, not `"cfg"`.

## Holding several link widths at once

For a testbench with one link geometry, name the parameterized types once and
use them everywhere — that is what [`example/`](../example) does.

For several widths live at the same time, `tb/axi_stream_env.sv` shows the
pattern: an unparameterized `axi_stream_env_base` holding everything a test
touches (both configs, the master sequencer, the scoreboard), plus a
parameterized `axi_stream_env #(...)` that adds the agents and publishes its
sequencer up into the base.

A test can then keep `axi_stream_env_base envs[$]` containing a 4-byte and a
16-byte link side by side and start the same sequence on each, with no cast and
no parameter in sight. `tb/` does exactly that with five links.

## Simulator notes

XSIM 2023.2 needed two workarounds, both of which fail silently rather than
erroring, so they are called out here and commented at the source:

- **Property formal arguments are ignored.** `property p(sig); ... endproperty`
  compiles and elaborates, and XSIM then drops every assertion using it with
  only a warning — checks that look present and do nothing. Every assertion is
  written out one signal at a time instead.
- **The constraint solver hangs** on a `soft` constraint inside a `foreach` over
  a rand dynamic array, once the transaction's other `foreach` constraints are
  present — not a slow solve, an infinite one. `axi_stream_seq_item` uses a
  plain `dense` knob gating hard implications instead. The same solver also
  declares `(tkeep[i]==0) -> (tstrb[i]==0)` unsatisfiable in that company, so
  the byte-encoding rule is stated as its contrapositive.
