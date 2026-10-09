///////////////////////////////////////////////////////////////////
// Filename: example_base_test.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Worked example of configuring and driving the AXI4-Stream
//           UVC. The companion to example_tb_top.sv: that file connects
//           the UVC to the design, this one decides how it behaves.
///////////////////////////////////////////////////////////////////
//
// ============================================================
//  WHAT THIS FILE HAS TO DO
// ============================================================
//   1. build one axi_stream_config per agent, saying which end of the
//      link it drives and how it should pace or backpressure
//   2. create the env that holds the agents
//   3. run stimulus on the master agent's sequencer
//
// The two configs are where nearly all the UVC's behaviour is decided,
// so they are worth reading closely. Everything else here is ordinary
// UVM.
//
// The derived tests at the bottom show the two knobs you are most likely
// to reach for: a different backpressure model, and different stimulus.

class example_base_test extends uvm_test;

  `uvm_component_utils(example_base_test)

  example_env env;

  // Configs are built here rather than inside the env so that a derived
  // test can adjust them in its own build_phase before the agents are
  // created. See example_backpressure_test below.
  axi_stream_config master_config;
  axi_stream_config slave_config;

  int unsigned num_packets = 10;

  extern function new(string name = "example_base_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);

endclass : example_base_test

function example_base_test::new(string name = "example_base_test", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 1 -- the master-side config: the agent that drives transfers
  //           INTO the DUT's slave port.
  // ---------------------------------------------------------------------
  master_config      = axi_stream_config::type_id::create("master_config");
  master_config.role = AXIS_MASTER;

  // Which optional signals this link carries. TKEEP/TSTRB/TLAST are
  // settable because their presence does not change any signal's width.
  // TID/TDEST/TUSER are *not* set here -- the agent derives those from
  // its own width parameters, since a link with ID_WIDTH=0 cannot carry
  // TID no matter what a config claims.
  master_config.has_tkeep = 1'b1;
  master_config.has_tstrb = 1'b1;
  master_config.has_tlast = 1'b1;

  // Source-side pacing: idle ACLK cycles inserted before each beat, which
  // is how TVALID bubbles get injected. (0, 0) streams back-to-back at
  // full rate; widen the window to make the source bursty.
  master_config.set_beat_delay(0, 2);

  // ---------------------------------------------------------------------
  // STEP 2 -- the slave-side config: the agent that accepts transfers
  //           FROM the DUT's master port. This is where backpressure
  //           lives, and it is the reason to have a slave agent at all.
  // ---------------------------------------------------------------------
  slave_config      = axi_stream_config::type_id::create("slave_config");
  slave_config.role = AXIS_SLAVE;
  slave_config.has_tkeep = 1'b1;
  slave_config.has_tstrb = 1'b1;
  slave_config.has_tlast = 1'b1;

  // Pick a backpressure model. The built-ins are:
  //
  //   AXIS_READY_ALWAYS  TREADY tied high -- no backpressure
  //   AXIS_READY_NEVER   TREADY tied low  -- never accepts
  //   AXIS_READY_RANDOM  per-cycle coin flip at .percent()
  //   AXIS_READY_DUTY    .ready_cycles() high, .stall_cycles() low
  //   AXIS_READY_BURST   accept .burst_beats(), then stall .stall_cycles()
  //   AXIS_READY_DELAY   hold off .delay_min()...delay_max() after TVALID
  //
  // For anything else, extend axi_stream_ready_policy, override
  // next_ready(), and assign it to slave_config.ready_policy directly. The
  // policy class is not parameterized by width, so one custom model
  // works on every link in your testbench.
  slave_config.set_ready_mode(AXIS_READY_RANDOM, .percent(60));

  // Optional deadlock watchdog: error out if a transfer stays offered
  // this long without being accepted. Leave it at 0 (the default) if a
  // test deliberately backpressures forever.
  slave_config.stall_timeout_cycles = 2000;

  // ---------------------------------------------------------------------
  // STEP 3 -- hand both configs to the env and build it. The env passes
  //           each one down to its agent; see example_env.sv, STEP 2.
  // ---------------------------------------------------------------------
  uvm_config_db#(axi_stream_config)::set(this, "env", "master_config", master_config);
  uvm_config_db#(axi_stream_config)::set(this, "env", "slave_config", slave_config);

  env = example_env::type_id::create("env", this);
endfunction : build_phase

task example_base_test::run_phase(uvm_phase phase);
  axi_stream_random_seq random_sequence;
  int unsigned n = num_packets;

  phase.raise_objection(this, "streaming traffic through the DUT");

  // ---------------------------------------------------------------------
  // STEP 4 -- run stimulus on the master agent's sequencer.
  //
  // Note what is missing from these three lines: any mention of a width.
  // The transaction sizes itself from the agent's config at randomize
  // time, so this same sequence drives a 4-byte link and a 16-byte link
  // without being told which it is on.
  //
  // The slave agent needs no stimulus at all -- TREADY comes from the
  // backpressure policy configured above, not from transactions.
  //
  // Other sequences in the library:
  //   axi_stream_beat_seq            one beat
  //   axi_stream_packet_seq          one packet; set .payload to send
  //                                  specific bytes, chopped into beats
  //   axi_stream_sparse_packet_seq   null and position byte payloads
  //   axi_stream_random_seq          a mix of the above
  // ---------------------------------------------------------------------
  random_sequence = axi_stream_random_seq::type_id::create("random_sequence");
  if (!random_sequence.randomize() with { num_packets == n; })
    `uvm_fatal("RAND", "sequence randomization failed")
  random_sequence.start(env.master_agent.sequencer);

  // ---------------------------------------------------------------------
  // STEP 5 -- let the last beats reach the far side before ending.
  //
  // random_sequence.start() returns when the last beat has been *driven*, but it is
  // still inside the DUT. Ending the test now would strand it and the
  // scoreboard would report it as lost, so wait for the design to drain.
  // ---------------------------------------------------------------------
  env.scoreboard.wait_until_drained(.timeout_cycles(5000));

  phase.drop_objection(this, "traffic complete");
endtask : run_phase


///////////////////////////////////////////////////////////////////
// Changing the backpressure model is a two-line derived test: build the
// base configuration, then overwrite the one field you care about.
///////////////////////////////////////////////////////////////////
class example_backpressure_test extends example_base_test;

  `uvm_component_utils(example_backpressure_test)

  extern function new(string name = "example_backpressure_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

endclass : example_backpressure_test

function example_backpressure_test::new(string name = "example_backpressure_test",
                                        uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_backpressure_test::build_phase(uvm_phase phase);
  super.build_phase(phase);   // builds both configs and the env

  // Accept four beats, then shut the port for six cycles, forever. This
  // is the model that finds FIFO-full bugs, because the stall always
  // lands after a known number of beats however the source paced them.
  slave_config.set_ready_mode(AXIS_READY_BURST, .burst_beats(4), .stall_cycles(6));

  // ...and make the source bursty too, so the two interact rather than
  // each being tested against a perfectly behaved partner.
  master_config.set_beat_delay(0, 4);
endfunction : build_phase


///////////////////////////////////////////////////////////////////
// Sending specific bytes rather than random ones: build the packet
// sequence yourself and fill in its payload. The sequence chops the byte
// stream into beats of whatever width the link is and marks the leftover
// lanes of a short final beat as null bytes, so the same code works at
// any width.
///////////////////////////////////////////////////////////////////
class example_directed_test extends example_base_test;

  `uvm_component_utils(example_directed_test)

  extern function new(string name = "example_directed_test", uvm_component parent = null);
  extern virtual task run_phase(uvm_phase phase);

endclass : example_directed_test

function example_directed_test::new(string name = "example_directed_test",
                                    uvm_component parent = null);
  super.new(name, parent);
endfunction : new

task example_directed_test::run_phase(uvm_phase phase);
  axi_stream_packet_seq directed_sequence;

  phase.raise_objection(this, "sending a directed payload");

  // A 21-byte frame -- deliberately not a multiple of the 8-byte link
  // width, so the final beat is short and its unused lanes become null
  // bytes. That is the case worth checking by hand in any packet path.
  directed_sequence = axi_stream_packet_seq::type_id::create("directed_sequence");
  directed_sequence.agent_config = master_config;                       // so it knows the link geometry
  for (int i = 0; i < 21; i++)
    directed_sequence.payload.push_back(8'hA0 + i[7:0]);
  if (!directed_sequence.randomize() with { pkt_tid == 3; pkt_tdest == 1; })
    `uvm_fatal("RAND", "directed sequence randomization failed")
  directed_sequence.start(env.master_agent.sequencer);

  env.scoreboard.wait_until_drained(.timeout_cycles(5000));

  phase.drop_objection(this, "directed payload complete");
endtask : run_phase


///////////////////////////////////////////////////////////////////
// Video frames over the same link, using the Xilinx sideband mapping:
// TUSER[0] marks the start of a frame and TLAST the end of every line.
//
// ============================================================
//  WHAT A VIDEO TEST ADDS TO THE FOUR STEPS ABOVE
// ============================================================
// Nothing structural. A frame is sent as ordinary beats, so the configs,
// the agents, the backpressure model and the scoreboard above all keep
// working untouched. Three things get added:
//
//   A. an axi_stream_video_format, saying how pixels sit on TDATA
//   B. a frame to send -- from a file, or from a built-in pattern
//   C. the env's frame collector, told the same format, so the frames
//      coming out of the DUT can be compared against what went in
//
// This link is 8 bytes wide, which holds two RGBA8888 pixels exactly, so
// the format below runs at two pixels per clock. Change EX_DATA_BYTES in
// example_tb_pkg.sv and nothing here needs editing: the sequence asks
// the config how wide the link is and blocks the frame to fit.
///////////////////////////////////////////////////////////////////
class example_video_test extends example_base_test;

  `uvm_component_utils(example_video_test)

  // Where the example's frame lives, relative to the directory make runs
  // in. Override from the command line with PLUSARGS=+IMAGE_DIR=...
  string image_dir = "images";

  extern function new(string name = "example_video_test", uvm_component parent = null);
  extern virtual task run_phase(uvm_phase phase);

endclass : example_video_test

function example_video_test::new(string name = "example_video_test",
                                 uvm_component parent = null);
  super.new(name, parent);
endfunction : new

task example_video_test::run_phase(uvm_phase phase);
  axi_stream_video_format    video_format;
  axi_stream_video_frame     sent_frame;
  axi_stream_video_file_seq  file_sequence;
  axi_stream_video_pattern_seq pattern_sequence;
  string                     from_command_line;
  string                     path;

  phase.raise_objection(this, "sending video frames through the DUT");

  if ($value$plusargs("IMAGE_DIR=%s", from_command_line))
    image_dir = from_command_line;
  path = {image_dir, "/frame_8x4.hex"};

  // ---------------------------------------------------------------------
  // STEP A -- describe the pixels.
  //
  // Two RGBA8888 pixels per clock: 4 components x 8 bits x 2 pixels = 64
  // bits, which is this link's TDATA exactly. The named constructors
  // cover the usual cases:
  //
  //   axi_stream_video_format::rgba8888(ppc)   RGBA, 8 bits per component
  //   axi_stream_video_format::rgba(bits, ppc) RGBA at 10, 12, 16 bits...
  //   axi_stream_video_format::rgb(bits, ppc)  three components
  //   axi_stream_video_format::gray(bits, ppc) one component
  //
  // The SOF and EOL mapping is already the Xilinx one by default; set
  // drive_sof to 0 for a link with no TUSER.
  // ---------------------------------------------------------------------
  video_format = axi_stream_video_format::rgba8888(2);

  `uvm_info("VIDEO", $sformatf("format: %s", video_format.convert2string()), UVM_LOW)

  // ---------------------------------------------------------------------
  // STEP B -- read the frame, and tell the collector what to expect.
  //
  // The frame is loaded here rather than left to the sequence so that its
  // width and height are known before the collector is programmed.
  // Giving the collector the geometry is optional but worth doing: it
  // lets a frame close on its last line instead of waiting for the next
  // frame's SOF.
  // ---------------------------------------------------------------------
  sent_frame = axi_stream_video_frame::type_id::create("sent_frame");
  sent_frame.video_format = video_format;
  if (!sent_frame.load(path))
    `uvm_fatal("VIDEO", $sformatf({"could not read '%s'. Run make from this directory, or pass ",
                                   "PLUSARGS=+IMAGE_DIR=<path>"}, path))

  env.frame_collector.video_format    = video_format;
  env.frame_collector.expected_width  = sent_frame.width;
  env.frame_collector.expected_height = sent_frame.height;

  // ---------------------------------------------------------------------
  // STEP C -- send it. Twice, so the gap between frames is exercised too.
  // ---------------------------------------------------------------------
  file_sequence = axi_stream_video_file_seq::type_id::create("file_sequence");
  file_sequence.frame            = sent_frame;   // already loaded
  file_sequence.line_gap_cycles  = 2;            // horizontal blanking
  file_sequence.frame_gap_cycles = 8;            // vertical blanking
  if (!file_sequence.randomize() with { num_frames == 2; })
    `uvm_fatal("RAND", "video file sequence randomization failed")
  file_sequence.start(env.master_agent.sequencer);

  env.scoreboard.wait_until_drained(.timeout_cycles(5000));

  // ---------------------------------------------------------------------
  // STEP D -- check what came back out of the DUT.
  //
  // compare() is a plain UVM object compare: geometry first, then every
  // pixel masked to the format's real precision. A frame that was
  // re-paced or re-blocked on the way through still compares equal,
  // because the beat structure is not part of the frame.
  // ---------------------------------------------------------------------
  if (env.frame_collector.received_frames.size() != 2)
    `uvm_error("VIDEO", $sformatf("expected 2 frames back, got %0d",
                                  env.frame_collector.received_frames.size()))

  foreach (env.frame_collector.received_frames[f]) begin
    axi_stream_video_frame received = env.frame_collector.received_frames[f];
    if (!sent_frame.compare(received)) begin
      int diff = sent_frame.first_difference(received);
      `uvm_error("VIDEO", $sformatf("frame %0d came back changed (first difference at pixel %0d)",
                                    f, diff))
    end
    else begin
      `uvm_info("VIDEO", $sformatf("frame %0d matches: %s", f, received.convert2string()), UVM_LOW)
    end
  end

  // Dumping what came off the wire is often the quickest way to see what
  // a DUT did to a frame: open the .ppm in any image viewer, or diff the
  // .hex against the input by eye.
  if (env.frame_collector.received_frames.size() > 0) begin
    void'(env.frame_collector.received_frames[0].save_hex("received_frame.hex"));
    void'(env.frame_collector.received_frames[0].save_pnm("received_frame.ppm"));
  end

  // ---------------------------------------------------------------------
  // STEP E -- the same thing without a file, for a test that should not
  //           depend on one. The built-in patterns are RAMP, BARS,
  //           CHECKER, INDEX and RANDOM.
  // ---------------------------------------------------------------------
  env.frame_collector.received_frames.delete();
  env.frame_collector.expected_width  = 16;
  env.frame_collector.expected_height = 8;

  pattern_sequence = axi_stream_video_pattern_seq::type_id::create("pattern_sequence");
  pattern_sequence.video_format = video_format;
  pattern_sequence.pattern      = AXIS_PATTERN_BARS;
  if (!pattern_sequence.randomize() with { frame_width == 16; frame_height == 8;
                                           num_frames == 1; })
    `uvm_fatal("RAND", "video pattern sequence randomization failed")
  pattern_sequence.start(env.master_agent.sequencer);

  env.scoreboard.wait_until_drained(.timeout_cycles(5000));

  if (env.frame_collector.received_frames.size() != 1)
    `uvm_error("VIDEO", $sformatf("expected 1 pattern frame back, got %0d",
                                  env.frame_collector.received_frames.size()))
  else if (!pattern_sequence.frame.compare(env.frame_collector.received_frames[0]))
    `uvm_error("VIDEO", "the generated pattern frame came back changed")
  else
    `uvm_info("VIDEO", "the generated pattern frame matches", UVM_LOW)

  phase.drop_objection(this, "video frames complete");
endtask : run_phase
