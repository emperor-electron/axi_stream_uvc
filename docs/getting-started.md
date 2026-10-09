# Getting started

Integrating the UVC into an existing UVM testbench. Every snippet here is
drawn from [`example/`](../example), which compiles and runs — if something
does not work, diff against those files.

## 1. Add the UVC to your compile

The whole component is two files, listed in `src/axi_stream_uvc.f`. Filelist
entries resolve relative to wherever the compiler runs, so the paths are
anchored on an environment variable you point at this repository:

```bash
export AXI_STREAM_UVC_ROOT=/path/to/axi_stream_uvc
```

```bash
xvlog -sv -L uvm -f $AXI_STREAM_UVC_ROOT/src/axi_stream_uvc.f -f my_tb.f
```

Then import it wherever you use it:

```systemverilog
import axi_stream_pkg::*;
```

## 2. Write your widths down once

This is the single most useful habit when integrating the UVC, and skipping it
is the most common way to lose an afternoon.

`virtual axi_stream_if #(8,4,4,8)` and `virtual axi_stream_if #(4,0,0,0)` are
**different SystemVerilog types**. A `uvm_config_db` set and get that disagree
by one parameter do not raise an error — the get simply returns 0 and the agent
reports `NOVIF`. Declaring the widths once and naming the types that depend on
them makes the mismatch impossible rather than merely unlikely:

```systemverilog
package my_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_stream_pkg::*;

  // TDATA is in bytes. Any integer number of them is legal -- 12 is as
  // valid as 16. A width of 0 for ID/DEST/USER means the link does not
  // carry that signal at all.
  parameter int MY_DATA_BYTES = 8;    // TDATA 64 bits; TKEEP/TSTRB 8 bits
  parameter int MY_ID_WIDTH   = 4;
  parameter int MY_DEST_WIDTH = 4;
  parameter int MY_USER_WIDTH = 8;

  typedef virtual axi_stream_if #(MY_DATA_BYTES, MY_ID_WIDTH,
                                  MY_DEST_WIDTH, MY_USER_WIDTH) my_vif_t;
  typedef axi_stream_agent      #(MY_DATA_BYTES, MY_ID_WIDTH,
                                  MY_DEST_WIDTH, MY_USER_WIDTH) my_agent_t;
  ...
endpackage
```

Use `my_vif_t` and `my_agent_t` everywhere from here on.

## 3. Instantiate an interface per AXI4-Stream port

One interface per port of the DUT, named for what it is relative to the DUT:

```systemverilog
axi_stream_if #(MY_DATA_BYTES, MY_ID_WIDTH, MY_DEST_WIDTH, MY_USER_WIDTH)
    axis_in (.aclk(aclk), .aresetn(aresetn));

axi_stream_if #(MY_DATA_BYTES, MY_ID_WIDTH, MY_DEST_WIDTH, MY_USER_WIDTH)
    axis_out (.aclk(aclk), .aresetn(aresetn));
```

Wire them to the DUT signal by signal:

```systemverilog
my_dut u_dut (
  .aclk          (aclk),
  .aresetn       (aresetn),

  // DUT slave port  <- driven by the UVC's master agent
  .s_axis_tvalid (axis_in.tvalid),
  .s_axis_tready (axis_in.tready),
  .s_axis_tdata  (axis_in.tdata),
  .s_axis_tkeep  (axis_in.tkeep),
  .s_axis_tlast  (axis_in.tlast),
  // ...tstrb, tid, tdest, tuser

  // DUT master port -> backpressured by the UVC's slave agent
  .m_axis_tvalid (axis_out.tvalid),
  .m_axis_tready (axis_out.tready),
  .m_axis_tdata  (axis_out.tdata),
  // ...and the rest
);
```

If your DUT is written against the interface instead, the synthesizable
modports do the same job in one line each:

```systemverilog
my_dut u_dut (.aclk, .aresetn,
              .s_axis(axis_in.dut_slave),
              .m_axis(axis_out.dut_master));
```

Either way, note who drives what: on `axis_in` the UVC drives TVALID and the
payload while the DUT drives TREADY; on `axis_out` it is the other way round.
Every signal ends up with exactly one driver, which is why both ends can share
one interface type.

## 4. Publish the interfaces

A UVM component cannot reach into the design hierarchy, so the top module has
to hand the interfaces over:

```systemverilog
initial begin
  uvm_config_db#(my_vif_t)::set(null, "*", "vif_in",  axis_in);
  uvm_config_db#(my_vif_t)::set(null, "*", "vif_out", axis_out);
  run_test("my_base_test");
end
```

Using `my_vif_t` here and in the env is what guarantees the set and the get
agree.

## 5. Configure the agents

Two configs, one per agent. This is where nearly all the UVC's behaviour is
decided; see [Configuration](configuration.md) for the full reference.

```systemverilog
function void my_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  // The agent that drives transfers INTO the DUT's slave port.
  master_config      = axi_stream_config::type_id::create("master_config");
  master_config.role = AXIS_MASTER;
  master_config.has_tkeep = 1'b1;
  master_config.has_tstrb = 1'b1;
  master_config.has_tlast = 1'b1;
  master_config.set_beat_delay(0, 2);      // 0-2 idle cycles between beats

  // The agent that accepts transfers FROM the DUT's master port. This is
  // where backpressure lives.
  slave_config      = axi_stream_config::type_id::create("slave_config");
  slave_config.role = AXIS_SLAVE;
  slave_config.has_tkeep = 1'b1;
  slave_config.has_tstrb = 1'b1;
  slave_config.has_tlast = 1'b1;
  slave_config.set_ready_mode(AXIS_READY_RANDOM, .percent(60));

  uvm_config_db#(axi_stream_config)::set(this, "env", "master_config", master_config);
  uvm_config_db#(axi_stream_config)::set(this, "env", "slave_config",  slave_config);

  env = my_env::type_id::create("env", this);
endfunction
```

Note what is *not* set: `has_tid`, `has_tdest` and `has_tuser`. The agent
derives those from its own width parameters, because a link parameterized for
`ID_WIDTH = 0` cannot carry TID no matter what a config claims.

## 6. Build the agents in your env

Each agent expects exactly two things under its own instance name: `"vif"` and
`"agent_config"`.

```systemverilog
function void my_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(my_vif_t)::get(this, "", "vif_in", vif_in))
    `uvm_fatal("NOVIF", "no 'vif_in' -- do the type parameters match?")
  if (!uvm_config_db#(my_vif_t)::get(this, "", "vif_out", vif_out))
    `uvm_fatal("NOVIF", "no 'vif_out' -- do the type parameters match?")
  // ...and the two configs, likewise

  uvm_config_db#(axi_stream_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(axi_stream_config)::set(this, "slave_agent",  "agent_config", slave_config);
  uvm_config_db#(my_vif_t)::set(this, "master_agent", "vif", vif_in);
  uvm_config_db#(my_vif_t)::set(this, "slave_agent",  "vif", vif_out);

  master_agent = my_agent_t::type_id::create("master_agent", this);
  slave_agent  = my_agent_t::type_id::create("slave_agent",  this);
endfunction
```

The agent then fans both down to its own children, so the driver, monitor and
coverage collector need no further plumbing.

## 7. Subscribe to the monitors

Each monitor offers two analysis ports, and which you use is a real choice:

```systemverilog
function void my_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  // pkt: one axi_stream_packet per TLAST -- payload and routing, ignoring
  // how the frame was blocked into beats or paced.
  master_agent.monitor.packet_analysis_port.connect(scoreboard.in_packet_export);
  slave_agent.monitor.packet_analysis_port.connect(scoreboard.out_packet_export);

  // beats: one axi_stream_seq_item per handshake, every field exactly as it
  // appeared on the wire. Use this for cycle-level checks and coverage.
  // master_agent.monitor.beat_analysis_port.connect(...);
endfunction
```

Both streams come from monitors, never from drivers, so your checks are against
what the wires actually did rather than what the testbench meant to do.

## 8. Send traffic

```systemverilog
task my_base_test::run_phase(uvm_phase phase);
  axi_stream_random_seq random_sequence;
  phase.raise_objection(this);

  random_sequence = axi_stream_random_seq::type_id::create("random_sequence");
  if (!random_sequence.randomize() with { num_packets == 20; })
    `uvm_fatal("RAND", "sequence randomization failed")
  random_sequence.start(env.master_agent.sequencer);

  // Let the last beats reach the far side. start() returns when the final
  // beat has been *driven*, but it is still inside the DUT -- ending here
  // would strand it and your scoreboard would call it lost.
  env.scoreboard.wait_until_drained();

  phase.drop_objection(this);
endtask
```

Note what is missing from that sequence: any mention of a width. See
[Sequences](sequences.md).

The slave agent needs no stimulus at all — TREADY comes from the backpressure
policy, not from transactions.

## 9. If your DUT is a video design

Everything above is unchanged — video frames go out as ordinary beats. Three
things get added: a format saying how pixels sit on TDATA, a frame, and a
collector to rebuild the frames coming back.

```systemverilog
// In the env, alongside the scoreboard. It ignores every beat until a test
// gives it a format, so it costs a non-video test nothing.
frame_collector = axi_stream_video_frame_collector::type_id::create("frame_collector", this);
...
slave_agent.monitor.beat_analysis_port.connect(frame_collector.analysis_export);
```

```systemverilog
// In the test. RGBA8888 at two pixels per clock is 64 bits -- an 8-byte link.
axi_stream_video_format video_format = axi_stream_video_format::rgba8888(2);
env.frame_collector.video_format    = video_format;
env.frame_collector.expected_width  = 64;
env.frame_collector.expected_height = 16;

axi_stream_video_pattern_seq video_sequence;
video_sequence = axi_stream_video_pattern_seq::type_id::create("video_sequence");
video_sequence.video_format = video_format;
video_sequence.pattern      = AXIS_PATTERN_BARS;
if (!video_sequence.randomize() with { frame_width == 64; frame_height == 16; })
  `uvm_fatal("RAND", "video sequence randomization failed")
video_sequence.start(env.master_agent.sequencer);

env.scoreboard.wait_until_drained();

if (!video_sequence.frame.compare(env.frame_collector.received_frames[0]))
  `uvm_error("VIDEO", "the frame that came back is not the one sent")
```

SOF is TUSER[0] and EOL is TLAST by default, which is the Xilinx video mapping.
See [Video](video.md), and [Image files](image-files.md) to read the frame from a
file instead. `example_video_test` in
[`example/example_base_test.sv`](../example/example_base_test.sv) is this worked
through with numbered comments.

## Common problems

**`NOVIF` fatal from the agent.** The config-DB type or scope does not match.
Check the interface's four parameters are identical at the `set` and the `get`;
this is what step 2 exists to prevent.

**`no 'agent_config' in the config DB`.** The field name is `"agent_config"`
and the scope must be the agent's instance name.

**A `GEOMETRY` warning about TDATA bytes.** Your config states a `data_bytes`
that disagrees with the agent's `DATA_BYTES` parameter. Leave `data_bytes` at 0
(the default) and let the agent fill it in.

**Beats reported as lost at the end of the test.** The test ended while
transfers were still inside the DUT. Wait for the design to drain before
dropping your objection, as in step 8.

**The video sequence refuses with "needs a TDATA width of at least N bytes".**
The format does not fit the link. Either widen the link or lower
`pixels_per_clock`; the message gives both numbers. See
[Pixel formats](video.md#pixel-formats).

**Video frames come back one short, or the last one never arrives.** A frame
ends at the next SOF, so without `expected_height` the final frame has nothing
to close it. Set `expected_height` on the collector, or call `publish_frame()`
when you are done sending. See [Receiving a frame](video.md#receiving-a-frame).
