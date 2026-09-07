# Backpressure

Testing that a design copes with a sink that will not accept is the main reason
to put a slave agent on it. This is how you program that sink.

## How it works

The slave driver drives TREADY and nothing else. It is not sequence-driven:
TREADY is a property of the sink, not of any transaction, so it runs free from a
policy object for the whole simulation.

The policy is asked once per ACLK edge for the value of TREADY in the **next**
cycle:

```systemverilog
pure virtual function bit next_ready(bit tvalid, bit tlast, bit beat_accepted);
```

That one-cycle offset is deliberate. Because the policy cannot see the TVALID it
is about to answer, no model — not even one you write — can accidentally create
a combinational TREADY-from-TVALID path. That path is the classic way a
testbench hides a deadlock that real hardware would hit.

TREADY has no protocol restrictions of its own: a slave may assert, deassert or
hold it at any time. Every model here is therefore legal by construction. Only
the *master* side has stability rules to obey.

## The built-in models

```systemverilog
slave_config.set_ready_mode(AXIS_READY_BURST, .burst_beats(8), .stall_cycles(3));
```

| Mode | Behaviour | Knobs |
| --- | --- | --- |
| `AXIS_READY_ALWAYS` | TREADY tied high; no backpressure | — |
| `AXIS_READY_NEVER` | TREADY tied low; the sink never accepts | — |
| `AXIS_READY_RANDOM` | Independent per-cycle coin flip | `percent` |
| `AXIS_READY_DUTY` | Free-running square wave | `ready_cycles`, `stall_cycles` |
| `AXIS_READY_BURST` | Accept N *transfers*, then stall | `burst_beats`, `stall_cycles` |
| `AXIS_READY_DELAY` | Hold off after TVALID appears | `delay_min`, `delay_max` |

Which to reach for:

**`AXIS_READY_DUTY`** is time-driven and identical on every seed. Use it to
reproduce a fixed-rate sink — a 1-in-N downstream clock crossing, say — exactly
the same way every run.

**`AXIS_READY_BURST`** is traffic-driven: it counts *accepted transfers*, not
cycles. This is the model that finds FIFO-full bugs, because the stall always
lands after a known number of beats however the source paced them.

**`AXIS_READY_DELAY`** re-draws a hold-off for every transfer, exercising the
"TVALID before TREADY" handshake ordering a master must tolerate. Its counter
only advances while TVALID is asserted, so the delay measures real stall rather
than idle time.

**`AXIS_READY_NEVER`** is for proving a master holds a stalled beat correctly —
see [the release pattern](#jamming-a-link-and-releasing-it) below.

### They do what they claim

Measured TREADY duty cycles from one `axi_stream_backpressure_test` run, which
assigns a different model to each of five links:

```
AXIS_READY_DUTY(1 on/3 off)        TREADY high  46 of 183 cycles (25%)
AXIS_READY_RANDOM(30%)             TREADY high  60 of 183 cycles (32%)
AXIS_READY_BURST(4 beats/6 stall)  TREADY high 104 of 183 cycles (56%)
AXIS_READY_DELAY(0..8)             TREADY high  32 of 183 cycles (17%)
```

Every slave driver reports its own census at the end of a run, so you can always
tell how much backpressure a DUT actually saw:

```
[DRV] backpressure AXIS_READY_BURST(4 beats/6 stall): accepted 53 beats,
      TREADY high 104 of 183 cycles (56%)
```

That matters when a random policy makes every seed a different experiment.

## Randomising a whole profile

Every knob is `rand`, so a test can draw a backpressure profile rather than
pick one:

```systemverilog
axi_stream_default_ready_policy policy;
policy = axi_stream_default_ready_policy::type_id::create("policy");
if (!policy.randomize() with { mode != AXIS_READY_NEVER;   // this link must drain
                               ready_percent inside {[25:90]};
                               stall_cycles  inside {[1:6]};
                               burst_beats   inside {[1:12]}; })
  `uvm_fatal("RAND", "policy randomization failed")
slave_config.ready_policy = policy;
```

## Writing your own model

For anything the built-ins do not cover — replaying a recorded trace, following
a credit counter, backpressuring only packets with a given TDEST — extend the
base class and assign it to the config:

```systemverilog
class credit_ready_policy extends axi_stream_ready_policy;
  `uvm_object_utils(credit_ready_policy)

  int unsigned credits = 8;

  function new(string name = "credit_ready_policy");
    super.new(name);
  endfunction

  // Called once per ACLK edge, for the cycle after this one.
  virtual function bit next_ready(bit tvalid, bit tlast, bit beat_accepted);
    if (beat_accepted && (credits > 0))
      credits--;
    return (credits > 0);
  endfunction

  // Called whenever ARESETn asserts, so a stateful model restarts cleanly
  // instead of resuming mid-pattern.
  virtual function void reset();
    credits = 8;
  endfunction
endclass
```

```systemverilog
slave_config.ready_policy = credit_ready_policy::type_id::create("policy");
```

The policy class is **not parameterized by link width**, so one custom model
works against every link in your testbench regardless of its TDATA size.

## Changing backpressure mid-run

The slave driver re-reads `agent_config.ready_policy` every cycle rather than
caching it, so swapping the handle takes effect immediately. It notices the
change, resets the new policy and logs it.

### Jamming a link and releasing it

This is the sharpest test of a master's handshake. With TREADY held low for
hundreds of cycles, TVALID and the entire payload must stay exactly as first
offered — which the interface's `TVALID_HELD` and `*_STABLE` assertions check
throughout the stall. Releasing the backpressure afterwards then proves the
stalled beats were only held, not lost:

```systemverilog
// Start with the sink refusing everything.
slave_config.set_ready_mode(AXIS_READY_NEVER);
slave_config.stall_timeout_cycles = 0;        // the stall is deliberate

fork
  random_sequence.start(env.master_agent.sequencer);
join_none

repeat (300) @(posedge vif.aclk);             // let it jam solid

slave_config.set_ready_mode(AXIS_READY_ALWAYS);
slave_config.stall_timeout_cycles = 4000;     // now it must drain
```

`tb/axi_stream_test_lib.sv` runs exactly this as `axi_stream_no_ready_test`,
across all five link widths at once, and additionally asserts that no beat was
delivered while TREADY was low.

## The source side

Backpressure's counterpart is source-side pacing: idle cycles the master driver
inserts before offering a beat. TVALID is low throughout, so a bubble is always
legal.

```systemverilog
master_config.set_beat_delay(0, 4);   // 0-4 idle cycles before each beat
```

The window feeds each transaction's `delay` field, which the sequence library
constrains into it. Leaving both at 0 streams back-to-back at full rate — and
that full rate is real: after a handshake the driver tentatively writes TVALID
low and then asks for the next beat, so if the sequencer answers in zero time
the write is overwritten before the clocking block applies either and TVALID
simply stays high.

Exercising both sides at once is worth doing deliberately; a source that is
always ready and a sink that is always ready test each other very gently.
