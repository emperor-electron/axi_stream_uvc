# AXI4-Stream UVC

A reusable UVM verification component for AMBA AXI4-Stream (ARM IHI 0051A).

It drives either end of a stream, applies programmable backpressure, polices the
protocol with assertions that are themselves tested, and works at any TDATA
width without a single compile-time definition.

```systemverilog
// One agent per AXI4-Stream port of your DUT. The role decides whether it
// sources transfers or sources TREADY -- nothing else changes.
axi_stream_agent #(.DATA_BYTES(8), .ID_WIDTH(4), .DEST_WIDTH(4), .USER_WIDTH(8)) master_agent;
```

## Start here

| If you want to... | Read |
| --- | --- |
| Hook the UVC up to your DUT | [Getting started](getting-started.md) |
| Configure an agent | [Configuration](configuration.md) |
| Backpressure a DUT and see it cope | [Backpressure](backpressure.md) |
| Send traffic | [Sequences](sequences.md) |
| Know what the UVC checks for you | [Protocol checks](protocol-checks.md) |
| Understand or extend the component | [Architecture](architecture.md) |
| Run the tests, capture waveforms | [Simulation](simulation.md) |

There is also a complete, runnable testbench in [`example/`](../example) that
you can copy: `example_tb_top.sv` and `example_base_test.sv` carry numbered
comments walking through every step.

```bash
cd example && make
```

## What it gives you

**Both ends of the stream.** One agent type. Set `role` to `AXIS_MASTER` and it
sources TVALID and the whole payload into your DUT's slave port; set it to
`AXIS_SLAVE` and it sources nothing but TREADY into your DUT's master port. The
agent builds only the driver its role calls for.

**Backpressure you can program.** Six built-in TREADY models — always, never,
random, duty cycle, burst, and delayed — plus a policy class for anything else.
Models can be swapped while the simulation runs, so a test can jam a link solid
and then release it. See [Backpressure](backpressure.md).

**Protocol checking that is known to work.** Twenty assertions live in the
interface and police your DUT and the UVC equally. They are not taken on trust:
`make check-protocol` breaks each rule deliberately and fails unless the
interface catches it. See [Protocol checks](protocol-checks.md).

**Any width, in one simulation.** TDATA/TID/TDEST/TUSER are SystemVerilog
parameters, never `` `define ``s, so a testbench can hold a 4-byte link and a
16-byte link side by side. The transaction sizes itself at run time, which means
one sequence library and one scoreboard serve every width.

**One interface file for RTL and verification.** `axi_stream_if.sv` is both the
UVC's virtual interface and an interface you can instantiate inside a design —
everything unsynthesizable sits behind `` `ifdef AXI_STREAM_IF_SIM ``.

## Requirements

- A SystemVerilog simulator with UVM 1.2. Developed and tested against Vivado
  XSIM 2023.2, whose bundled UVM the Makefiles use automatically.
- Nothing else. The UVC depends on no library but UVM.

On a simulator that does not predefine `XILINX_SIMULATOR`, compile the
interface with `+define+AXI_STREAM_IF_SIM`; see
[Architecture](architecture.md#one-file-for-simulation-and-synthesis).

## Repository layout

```
docs/       you are here
src/        the UVC -- the only thing another project compiles
example/    a runnable integration example, written to be read
tb/         the UVC's own self-test: five link widths in one simulation
```
