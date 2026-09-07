# Configuration

`axi_stream_config` is the object that decides how an agent behaves. One per
agent, handed to it under the config-DB field name `"agent_config"`.

It is deliberately **not parameterized**. The link's widths live here as plain
integers so that sequences, scoreboards and any code you write can be reused
against a 4-byte link and a 16-byte link in the same simulation.

## Fields

### Role and activity

| Field | Default | Meaning |
| --- | --- | --- |
| `role` | `AXIS_MASTER` | `AXIS_MASTER` sources transfers into a DUT's slave port; `AXIS_SLAVE` sources TREADY into a DUT's master port |
| `is_active` | `UVM_ACTIVE` | `UVM_PASSIVE` builds only the monitor, which still checks the protocol and feeds coverage |

The role decides which driver is constructed. The other one is never built, so
each interface signal keeps exactly one driver.

### Link geometry

| Field | Default | Meaning |
| --- | --- | --- |
| `data_bytes` | `0` | TDATA width in bytes. 0 means "not stated" — the agent fills it in from its own parameter |
| `id_width` | `0` | TID width in bits |
| `dest_width` | `0` | TDEST width in bits |
| `user_width` | `0` | TUSER width in bits |

You normally leave all four alone. The agent overwrites them from its type
parameters in `adopt_interface_geometry()`, and only warns if you set
`data_bytes` to a *non-zero* value that disagrees — a silent truncation of every
payload is worth a warning, a default is not.

### Which optional signals the link carries

| Field | Default | Set by |
| --- | --- | --- |
| `has_tkeep` | `1` | you |
| `has_tstrb` | `1` | you |
| `has_tlast` | `1` | you |
| `has_tid` | — | the agent, from `ID_WIDTH > 0` |
| `has_tdest` | — | the agent, from `DEST_WIDTH > 0` |
| `has_tuser` | — | the agent, from `USER_WIDTH > 0` |

The split is not arbitrary. TID/TDEST/TUSER have a width, and a link
parameterized for zero bits of TID cannot carry TID — so that is derived, not
configured. TKEEP/TSTRB/TLAST have no width to derive from (their presence does
not change any signal's size), so those are yours to state.

A link with `has_tkeep = 0` behaves as though every byte were kept; one with
`has_tstrb = 0` treats every kept byte as a data byte. The monitor normalises
both, which is what lets a scoreboard compare links that carry different
optional signals.

### Pacing and backpressure

| Field | Default | Meaning |
| --- | --- | --- |
| `min_beat_delay` | `0` | Source-side: fewest idle cycles before a beat |
| `max_beat_delay` | `0` | Source-side: most idle cycles before a beat |
| `ready_policy` | `null` | Sink-side: the TREADY model. Null gets `AXIS_READY_ALWAYS` |

Left at `0, 0`, the master streams back-to-back at full rate. See
[Backpressure](backpressure.md) for the sink side.

### Checks and instrumentation

| Field | Default | Meaning |
| --- | --- | --- |
| `protocol_checks_enable` | `1` | Drives the interface's own `checks_enable`. Clear it only for a directed test that drives deliberately illegal stimulus |
| `coverage_enable` | `1` | Builds the coverage subscriber inside the agent |
| `stall_timeout_cycles` | `0` | Cycles a transfer may stay offered before the monitor calls it a deadlock. 0 disables the watchdog |

`stall_timeout_cycles` defaults to off because a test may legitimately
backpressure forever (`AXIS_READY_NEVER`). Switch it on wherever the sink is
expected to drain — it turns a hung link into an error at the point of failure
instead of a timeout thousands of cycles later.

## Methods

```systemverilog
// Install a built-in backpressure model. Arguments not relevant to the
// chosen mode are ignored.
function void set_ready_mode(axi_stream_ready_mode_e mode,
                             int unsigned percent      = 50,
                             int unsigned ready_cycles = 1,
                             int unsigned stall_cycles = 1,
                             int unsigned burst_beats  = 4,
                             int unsigned delay_min    = 0,
                             int unsigned delay_max    = 4);

// Program the source-side bubble window.
function void set_beat_delay(int unsigned min_cycles, int unsigned max_cycles);

// State the link geometry by hand. Rarely needed -- the agent does this.
function void set_geometry(int unsigned data_bytes,
                           int unsigned id_width   = 0,
                           int unsigned dest_width = 0,
                           int unsigned user_width = 0,
                           bit          has_tkeep  = 1'b1,
                           bit          has_tstrb  = 1'b1,
                           bit          has_tlast  = 1'b1);

// One-line summary, printed by the agent at end_of_elaboration.
function string convert2string();
```

## A worked pair

```systemverilog
// Source: bursty, full-featured link.
master_config      = axi_stream_config::type_id::create("master_config");
master_config.role = AXIS_MASTER;
master_config.set_beat_delay(0, 4);          // inject TVALID bubbles

// Sink: accept four beats, then shut the port for six cycles, forever.
slave_config      = axi_stream_config::type_id::create("slave_config");
slave_config.role = AXIS_SLAVE;
slave_config.set_ready_mode(AXIS_READY_BURST, .burst_beats(4), .stall_cycles(6));
slave_config.stall_timeout_cycles = 2000;    // this sink is expected to drain
```

A minimal link — TDATA/TVALID/TREADY/TLAST and nothing else — is the same
object with two fields cleared and the interface parameterized at zero:

```systemverilog
// axi_stream_if #(.DATA_BYTES(4), .ID_WIDTH(0), .DEST_WIDTH(0), .USER_WIDTH(0))
master_config.has_tkeep = 1'b0;
master_config.has_tstrb = 1'b0;
```

## What the agent checks at build time

The config's widths and the agent's parameters describe the same link from two
directions, so the agent reconciles them before anything else happens:

- `data_bytes` of 0 is filled in silently; a non-zero disagreement is a
  `GEOMETRY` warning and the parameter wins.
- `id_width` / `dest_width` / `user_width` and the matching `has_*` bits are
  overwritten from the parameters unconditionally.
- The result is echoed once per agent at `end_of_elaboration` as a `CFG` info
  line, so a run's log states exactly what each link was configured to be:

```
uvm_test_top.env.master_agent [CFG] tb_top.axis_in.path -> AXIS_MASTER UVM_ACTIVE:
  TDATA=8B (64b) TID=4b TDEST=4b TUSER=8b | optional: TKEEP TSTRB TLAST TID TDEST TUSER
  | delay=0..4 | ready=(default)
```
