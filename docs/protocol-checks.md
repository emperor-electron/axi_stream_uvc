# Protocol checks

The UVC polices AXI4-Stream with twenty assertions living in
`axi_stream_if.sv`. They check your DUT and the UVC equally — whichever side
drives the signal that breaks a rule is the side the failure points at.

## What is checked

### Handshake (§2.2.1)

| Rule | Fails when |
| --- | --- |
| `TVALID_HELD` | TVALID was deasserted before TREADY completed the handshake |
| `TDATA_STABLE` | TDATA changed while TVALID was high and TREADY low |
| `TKEEP_STABLE`, `TSTRB_STABLE`, `TLAST_STABLE` | Likewise, per signal |
| `TID_STABLE`, `TDEST_STABLE`, `TUSER_STABLE` | Likewise, per signal |

Once a transfer is offered it stays offered, payload frozen, until TREADY
answers. One property per signal, so a failure names the offending signal
rather than making you decode it.

### Reset (§2.7.2)

| Rule | Fails when |
| --- | --- |
| `RESET_TVALID` | TVALID was still asserted a full cycle into ARESETn |
| `RESET_TVALID_EXIT` | TVALID was already high on the first ACLK edge after ARESETn released |

`RESET_TVALID` is qualified on reset having *already* been low at the previous
edge. That gives a synchronous master exactly one ACLK edge to react to an
asynchronously asserted reset — the same cycle a real sync-reset flop takes. A
master that keeps offering a transfer *through* reset still fails, which is the
behaviour worth catching.

### Byte encoding (§2.4.3)

| Rule | Fails when |
| --- | --- |
| `KEEP_STRB_RESERVED` | TKEEP low with TSTRB high — a reserved encoding |

### X propagation

| Rule | Fails when |
| --- | --- |
| `TVALID_X`, `TREADY_X` | A handshake signal is X/Z out of reset |
| `TKEEP_X`, `TSTRB_X`, `TLAST_X`, `TID_X`, `TDEST_X`, `TUSER_X` | Control payload is X/Z while TVALID is asserted |
| `TDATA_X` | A byte is X/Z that TKEEP marks as valid |

`TDATA_X` is checked per byte lane, and only on lanes TKEEP marks as valid:
AXI4-Stream leaves a null byte's TDATA explicitly undefined, so checking it
would be wrong. There is a scenario in the negative test proving an X in a null
byte stays quiet.

## The checks are known to work

A checker that never fires passes everything. So the assertions are not taken
on trust — `tb/axi_stream_if_check_tb.sv` breaks each rule on purpose and fails
unless the interface catches it:

```bash
cd tb && make check-protocol
```

```
  [ok]                legal stalled handshake clean
  [ok]      TVALID withdrawn before handshake caught  (1 violation(s), last rule TVALID_HELD)
  [ok]            TDATA changed while stalled caught  (1 violation(s), last rule TDATA_STABLE)
  [ok]            TLAST changed while stalled caught  (1 violation(s), last rule TLAST_STABLE)
  [ok]      reserved TKEEP=0/TSTRB=1 encoding caught  (1 violation(s), last rule KEEP_STRB_RESERVED)
  [ok]           TVALID asserted during reset caught  (3 violation(s), last rule RESET_TVALID)
  [ok]          TVALID high as reset released caught  (3 violation(s), last rule TVALID_HELD)
  [ok]            TVALID unknown out of reset caught  (2 violation(s), last rule TVALID_X)
  [ok]          X in a byte TKEEP marks valid caught  (2 violation(s), last rule TDATA_X)
  [ok]               X in a null byte (legal) clean
  [ok]         violation with checks_enable=0 clean

 checker self-test: 11 of 11 scenarios behaved correctly
```

Note the three `clean` scenarios. Catching violations is half the job; not
crying wolf on legal activity is the other half.

That testbench is plain SystemVerilog with no UVM in it — it drives the
interface signals directly, which is exactly what a broken master or slave
would do. `make regress` runs it before anything else.

## How failures reach you

The assertions know nothing about UVM. Each failure increments the interface's
own `protocol_error_count` and prints an `$error`:

```
Error: tb_top.axis_in.protocol_error: AXI4-Stream protocol violation
       [TVALID_HELD]: TVALID was deasserted before TREADY completed the handshake
```

The monitor's `check_phase` then turns a non-zero count into a `UVM_ERROR`, so
violations fail the test rather than scrolling past in a log. Keeping UVM out of
the interface is what lets the same file be used in a non-UVM testbench — or
synthesized.

## Turning checks off

For a directed test that drives deliberately illegal stimulus:

```systemverilog
agent_config.protocol_checks_enable = 1'b0;   // agent writes it to the interface
```

or on the interface directly, from a testbench with no UVM in it:

```systemverilog
initial axis.checks_enable = 1'b0;
```

Individual signals are silenced by telling the interface which optional signals
the link carries — the agent does this from your config at
`end_of_elaboration`, so a link with `has_tuser = 0` is never checked for TUSER.

## Checks the UVC cannot break

Some rules are not asserted because the UVC is structurally incapable of
violating them, which is a stronger guarantee than a check:

- **TVALID never waits for TREADY.** The master driver's decision to offer a
  beat comes only from the sequencer. The deadlock cannot be expressed.
- **A stalled beat is never disturbed.** The driver's stall loop touches
  nothing but the clock, so payload stability is structural.
- **No backpressure model can create a combinational TREADY path.** The policy
  is asked for the *next* cycle's TREADY before this cycle's TVALID can
  influence it. See [Backpressure](backpressure.md).

## Packet-level checking

Beyond the signal assertions, the monitor reports two frame-level problems:

- `PKT_ROUTING` — TID or TDEST changed within a packet, which AXI4-Stream
  requires to be constant across a frame.
- `PKT_INCOMPLETE` — the simulation ended with beats collected and no TLAST.

And an optional deadlock watchdog, off by default because a test may
legitimately backpressure forever:

```systemverilog
slave_config.stall_timeout_cycles = 2000;   // STALL_TIMEOUT error past this
```

It turns a hung link into an error at the point of failure, rather than a
timeout thousands of cycles later with no clue where it started.
