# axi_stream_uvc

A reusable UVM verification component for AMBA AXI4-Stream (ARM IHI 0051A),
scaffolded with [uvm-tb](../uvm-tb) and built out into a full UVC.

It drives either end of a stream, applies programmable backpressure, polices the
protocol with assertions that are themselves tested, and works at any TDATA
width without a single compile-time definition.

## Documentation

**[Start with `docs/`](docs/README.md).** In brief:

| | |
| --- | --- |
| [Getting started](docs/getting-started.md) | hooking the UVC up to your DUT |
| [Configuration](docs/configuration.md) | the `axi_stream_config` reference |
| [Backpressure](docs/backpressure.md) | ready models, and writing your own |
| [Sequences](docs/sequences.md) | the stimulus library |
| [Protocol checks](docs/protocol-checks.md) | what is asserted, and proof it fires |
| [Architecture](docs/architecture.md) | how it is built, and how to extend it |
| [Simulation](docs/simulation.md) | make targets, tests, waveforms |

## Quick start

```bash
cd example && make          # a complete, runnable integration example
cd tb      && make regress  # the UVC's own self-test
```

To use it in your own testbench, the whole component is two files:

```bash
export AXI_STREAM_UVC_ROOT=/path/to/axi_stream_uvc
xvlog -sv -L uvm -f $AXI_STREAM_UVC_ROOT/src/axi_stream_uvc.f -f my_tb.f
```

See [Getting started](docs/getting-started.md).

## Layout

```
docs/       documentation -- start here
src/        the UVC; the only thing another project compiles
example/    a runnable integration example, written to be read
tb/         the UVC's self-test: five link widths in one simulation
```

## Requirements

A SystemVerilog simulator with UVM 1.2. Developed and tested against Vivado
XSIM 2023.2, whose bundled UVM the Makefiles use automatically. The UVC depends
on no library but UVM.
