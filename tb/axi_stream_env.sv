///////////////////////////////////////////////////////////////////
// Filename: axi_stream_env.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : One link of the self-test: a master agent driving the DUT's
//           slave port, a slave agent applying backpressure to the
//           DUT's master port, and the scoreboard between them.
///////////////////////////////////////////////////////////////////
//
// The pair of classes here is the pattern that makes a width-agnostic
// test possible, and is worth copying into any testbench that has to
// hold several differently sized links at once:
//
//   axi_stream_env_base  - unparameterized. Holds everything a test
//                          actually touches: the two configs, the
//                          master sequencer, the scoreboard, a name.
//   axi_stream_env #(..)  - parameterized. Adds the two agents, which
//                          are the only things that need to know a
//                          width, and publishes its sequencer up into
//                          the base class.
//
// A test can therefore keep `axi_stream_env_base envs[$]` containing a
// 4-byte link and a 16-byte link side by side, and start the same
// sequence on each without a cast or a parameter in sight.

virtual class axi_stream_env_base extends uvm_env;

  axi_stream_config     master_config;      // source end: drives the DUT's slave port
  axi_stream_config     slave_config;       // sink end:   backpressures the DUT's master port
  axi_stream_sequencer  master_sequencer;   // published by the parameterized subclass
  axi_stream_scoreboard scoreboard;

  // Frame-level view of the same two links, for the video tests. Both
  // sit here on every link and stay inert until a test gives them a
  // video_format, so a non-video test pays nothing for them.
  axi_stream_video_frame_collector source_frame_collector;  // link into the DUT
  axi_stream_video_frame_collector sink_frame_collector;    // link out of the DUT

  // Human-readable link name, e.g. "16B/ID8/DEST8/USER16", used in log
  // lines so a failure names the link it came from.
  string link_desc = "";

  extern function new(string name = "axi_stream_env_base", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

  // Convenience for tests: reprogram this link's backpressure.
  extern virtual function void set_backpressure(axi_stream_ready_mode_e mode,
                                                int unsigned percent      = 50,
                                                int unsigned ready_cycles = 1,
                                                int unsigned stall_cycles = 1,
                                                int unsigned burst_beats  = 4,
                                                int unsigned delay_min    = 0,
                                                int unsigned delay_max    = 4);

  // Convenience for tests: reprogram this link's source-side pacing.
  extern virtual function void set_pacing(int unsigned min_cycles, int unsigned max_cycles);

  // Convenience for tests: switch both frame collectors on. A width or
  // height of 0 leaves that one derived -- see
  // axi_stream_video_frame_collector for what each choice costs.
  extern virtual function void set_video_format(axi_stream_video_format video_format,
                                                int unsigned expected_width  = 0,
                                                int unsigned expected_height = 0);

endclass : axi_stream_env_base

function axi_stream_env_base::new(string name = "axi_stream_env_base", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_env_base::build_phase(uvm_phase phase);
  super.build_phase(phase);
  // Configs are created here rather than in the test so that a test only
  // has to override what it cares about, in its own build_phase, before
  // super.build_phase() reaches the agents.
  if (master_config == null) begin
    master_config      = axi_stream_config::type_id::create("master_config");
    master_config.role = AXIS_MASTER;
  end
  if (slave_config == null) begin
    slave_config      = axi_stream_config::type_id::create("slave_config");
    slave_config.role = AXIS_SLAVE;
  end
  scoreboard = axi_stream_scoreboard::type_id::create("scoreboard", this);
  source_frame_collector = axi_stream_video_frame_collector::type_id::create(
                               "source_frame_collector", this);
  sink_frame_collector   = axi_stream_video_frame_collector::type_id::create(
                               "sink_frame_collector", this);
endfunction : build_phase

function void axi_stream_env_base::set_backpressure(axi_stream_ready_mode_e mode,
                                                    int unsigned percent      = 50,
                                                    int unsigned ready_cycles = 1,
                                                    int unsigned stall_cycles = 1,
                                                    int unsigned burst_beats  = 4,
                                                    int unsigned delay_min    = 0,
                                                    int unsigned delay_max    = 4);
  slave_config.set_ready_mode(mode, percent, ready_cycles, stall_cycles,
                         burst_beats, delay_min, delay_max);
endfunction : set_backpressure

function void axi_stream_env_base::set_pacing(int unsigned min_cycles, int unsigned max_cycles);
  master_config.set_beat_delay(min_cycles, max_cycles);
endfunction : set_pacing

function void axi_stream_env_base::set_video_format(axi_stream_video_format video_format,
                                                    int unsigned expected_width  = 0,
                                                    int unsigned expected_height = 0);
  source_frame_collector.video_format    = video_format;
  source_frame_collector.expected_width  = expected_width;
  source_frame_collector.expected_height = expected_height;
  sink_frame_collector.video_format      = video_format;
  sink_frame_collector.expected_width    = expected_width;
  sink_frame_collector.expected_height   = expected_height;
endfunction : set_video_format


///////////////////////////////////////////////////////////////////
// The parameterized half. Everything width-dependent lives here and
// nowhere else in the testbench.
///////////////////////////////////////////////////////////////////
class axi_stream_env #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0
) extends axi_stream_env_base;

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;
  typedef axi_stream_agent       #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) agent_t;
  typedef axi_stream_env         #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  agent_t master_agent;   // on the link into the DUT
  agent_t slave_agent;    // on the link out of the DUT

  vif_t vif_src;     // DUT slave port  (UVC drives TVALID + payload)
  vif_t vif_snk;     // DUT master port (UVC drives TREADY)

  extern function new(string name = "axi_stream_env", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);

endclass : axi_stream_env

function axi_stream_env::new(string name = "axi_stream_env", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(vif_t)::get(this, "", "vif_src", vif_src))
    `uvm_fatal("NOVIF", $sformatf("no 'vif_src' for %s -- did the link module's name match?",
                                  get_full_name()))
  if (!uvm_config_db#(vif_t)::get(this, "", "vif_snk", vif_snk))
    `uvm_fatal("NOVIF", $sformatf("no 'vif_snk' for %s -- did the link module's name match?",
                                  get_full_name()))

  link_desc = $sformatf("%0dB/ID%0d/DEST%0d/USER%0d",
                        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH);

  // Each agent gets its own config and its own end of the link. The
  // agent reconciles these widths with its parameters, so a config that
  // disagrees is caught rather than silently truncating payloads.
  uvm_config_db#(axi_stream_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(axi_stream_config)::set(this, "slave_agent", "agent_config", slave_config);
  uvm_config_db#(vif_t)::set(this, "master_agent", "vif", vif_src);
  uvm_config_db#(vif_t)::set(this, "slave_agent", "vif", vif_snk);

  master_agent = agent_t::type_id::create("master_agent", this);
  slave_agent = agent_t::type_id::create("slave_agent", this);
endfunction : build_phase

function void axi_stream_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);

  // Publish the sequencer through the unparameterized base, so tests can
  // reach it without knowing this link's width.
  master_sequencer = master_agent.sequencer;

  // Both ends feed the scoreboard: what the UVC drove in, and what the
  // DUT gave back. Both streams come from monitors, never from drivers,
  // so the check is against what the wires actually did.
  master_agent.monitor.beat_analysis_port.connect(scoreboard.source_beat_export);
  slave_agent.monitor.beat_analysis_port.connect(scoreboard.sink_beat_export);
  master_agent.monitor.packet_analysis_port.connect(scoreboard.source_packet_export);
  slave_agent.monitor.packet_analysis_port.connect(scoreboard.sink_packet_export);

  // The frame collectors ride on the same beat streams. They rebuild
  // frames from TLAST and TUSER[0] alone, so they need nothing from the
  // sequence that produced the traffic -- the sink-side one would work
  // just as well against a DUT that generated the video itself.
  master_agent.monitor.beat_analysis_port.connect(source_frame_collector.analysis_export);
  slave_agent.monitor.beat_analysis_port.connect(sink_frame_collector.analysis_export);
endfunction : connect_phase
