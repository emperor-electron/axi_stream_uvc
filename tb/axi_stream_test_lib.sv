///////////////////////////////////////////////////////////////////
// Filename: axi_stream_test_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : The UVC's self-test. Five differently parameterized
//           AXI4-Stream links are built, driven and checked inside a
//           single simulation, under every backpressure model the UVC
//           offers.
///////////////////////////////////////////////////////////////////
//
// The five links, all live at once in one compilation:
//
//   env_w4   TDATA  4B  TID 4  TDEST 4  TUSER  4   TKEEP TSTRB TLAST
//   env_w8   TDATA  8B  TID 8  TDEST 4  TUSER  8   TKEEP TSTRB TLAST
//   env_w12  TDATA 12B  TID 8  TDEST 8  TUSER 12   TKEEP TSTRB TLAST
//   env_w16  TDATA 16B  TID 8  TDEST 8  TUSER 16   TKEEP TSTRB TLAST
//   env_min  TDATA  4B  --     --       --         TLAST only
//
// The first four are the common TDATA widths, each with the TUSER width
// AXI4-Stream recommends (one bit per byte) and TKEEP/TSTRB implicitly
// at DATA_BYTES. 12 bytes is in there on purpose: it is not a power of
// two, which is legal and is exactly the case a UVC that quietly
// assumes shifts instead of multiplies gets wrong. env_min is the
// opposite extreme -- TDATA/TVALID/TREADY/TLAST and nothing else --
// which exercises the paths where optional signals are absent.
//
// Not one of these widths is a `define. They are module and class
// parameters, so all five elaborate together and a single `make` run
// covers the lot.
//
// Every link is checked by its own scoreboard against its own FIFO, and
// every link's interface runs the protocol assertions the whole time,
// so a UVC bug that only shows up at one width has nowhere to hide.

class axi_stream_base_test extends uvm_test;

  `uvm_component_utils(axi_stream_base_test)

  // The parameterization under test. These five declarations are the
  // only place in the testbench where a width is written down.
  axi_stream_env #(4,  4, 4, 4)  env_w4;
  axi_stream_env #(8,  8, 4, 8)  env_w8;
  axi_stream_env #(12, 8, 8, 12) env_w12;
  axi_stream_env #(16, 8, 8, 16) env_w16;
  axi_stream_env #(4,  0, 0, 0)  env_min;

  // ...and this is why that is bearable: a width-agnostic handle to
  // every one of them, which is what the rest of the test uses.
  axi_stream_env_base envs[$];

  virtual axi_stream_tb_ctrl_if ctrl;

  int unsigned packets_per_link = 8;
  int unsigned max_drain_cycles = 20000;

  extern function new(string name = "axi_stream_base_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void end_of_elaboration_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);

  // Per-link knobs, overridden by the tests below. Called once per link
  // during build, before the agents exist.
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);

  // Per-link stimulus, run concurrently on every link.
  extern virtual task run_link(axi_stream_env_base e, int unsigned index);

  // Wait until every link's scoreboard has seen its traffic come back,
  // rather than guessing at a fixed settling time.
  extern virtual task drain(int unsigned limit_cycles = 0);
  extern virtual function bit all_links_drained();

  extern function axi_stream_config make_config(string name, axi_stream_role_e link_role,
                                             bit en_tkeep = 1'b1, bit en_tstrb = 1'b1,
                                             bit en_tlast = 1'b1);

endclass : axi_stream_base_test

function axi_stream_base_test::new(string name = "axi_stream_base_test",
                                   uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_base_test::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(virtual axi_stream_tb_ctrl_if)::get(this, "", "ctrl", ctrl))
    `uvm_fatal("NOCTRL", "no virtual axi_stream_tb_ctrl_if set in the config DB")

  // The instance names below must match the ENV_NAME parameter of the
  // matching axi_stream_link instance in the top module: that is how
  // each link's two interfaces reach the right env through the config DB.
  env_w4  = axi_stream_env #(4,  4, 4, 4) ::type_id::create("env_w4",  this);
  env_w8  = axi_stream_env #(8,  8, 4, 8) ::type_id::create("env_w8",  this);
  env_w12 = axi_stream_env #(12, 8, 8, 12)::type_id::create("env_w12", this);
  env_w16 = axi_stream_env #(16, 8, 8, 16)::type_id::create("env_w16", this);
  env_min = axi_stream_env #(4,  0, 0, 0) ::type_id::create("env_min", this);

  envs = '{env_w4, env_w8, env_w12, env_w16, env_min};

  // Configs are assigned here, in the test's build_phase, because the
  // envs' own build_phase runs afterwards and only creates a default
  // config where the test has not supplied one.
  foreach (envs[i]) begin
    // env_min is the bare link: TDATA/TVALID/TREADY/TLAST and nothing
    // else, so both ends drop TKEEP and TSTRB.
    bit lean = (envs[i] == env_min);
    envs[i].master_config = make_config("master_config", AXIS_MASTER, .en_tkeep(!lean), .en_tstrb(!lean));
    envs[i].slave_config = make_config("slave_config", AXIS_SLAVE,  .en_tkeep(!lean), .en_tstrb(!lean));
    configure_link(envs[i], i);
  end
endfunction : build_phase

function axi_stream_config axi_stream_base_test::make_config(string name,
                                                          axi_stream_role_e link_role,
                                                          bit en_tkeep = 1'b1,
                                                          bit en_tstrb = 1'b1,
                                                          bit en_tlast = 1'b1);
  axi_stream_config link_config;
  link_config           = axi_stream_config::type_id::create(name);
  link_config.role      = link_role;
  link_config.has_tkeep = en_tkeep;
  link_config.has_tstrb = en_tstrb;
  link_config.has_tlast = en_tlast;
  // TID/TDEST/TUSER presence comes from the agent's parameters; see
  // axi_stream_agent::adopt_interface_geometry.
  return link_config;
endfunction : make_config

// Default: no backpressure, no source pacing. Every test below changes
// at least one of these.
function void axi_stream_base_test::configure_link(axi_stream_env_base e, int unsigned index);
  e.set_backpressure(AXIS_READY_ALWAYS);
  e.set_pacing(0, 0);
endfunction : configure_link

function void axi_stream_base_test::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  `uvm_info("TEST", $sformatf("%s: %0d AXI4-Stream links, %0d packets each",
                              get_type_name(), envs.size(), packets_per_link), UVM_LOW)
endfunction : end_of_elaboration_phase

task axi_stream_base_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "streaming traffic on every link");

  // Every link runs concurrently, so the whole set of widths is exercised
  // in the time one of them would take.
  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end
  wait fork;

  drain();
  phase.drop_objection(this, "all links finished");
endtask : run_phase

task axi_stream_base_test::run_link(axi_stream_env_base e, int unsigned index);
  axi_stream_random_seq random_sequence;
  int unsigned n = packets_per_link;
  random_sequence = axi_stream_random_seq::type_id::create($sformatf("random_%0d", index));
  if (!random_sequence.randomize() with { num_packets == n; })
    `uvm_fatal("RAND", "random sequence randomization failed")
  random_sequence.start(e.master_sequencer);
endtask : run_link

function bit axi_stream_base_test::all_links_drained();
  foreach (envs[i])
    if (!envs[i].scoreboard.is_drained())
      return 1'b0;
  return 1'b1;
endfunction : all_links_drained

task axi_stream_base_test::drain(int unsigned limit_cycles = 0);
  int unsigned limit   = (limit_cycles == 0) ? max_drain_cycles : limit_cycles;
  int unsigned elapsed = 0;
  while ((elapsed < limit) && !all_links_drained()) begin
    ctrl.wait_cycles(16);
    elapsed += 16;
  end
  if (!all_links_drained())
    `uvm_warning("DRAIN", $sformatf(
        "links still had traffic outstanding after %0d cycles", elapsed))
  // A few more cycles so the last beats reach the monitors' analysis ports.
  ctrl.wait_cycles(8);
endtask : drain


///////////////////////////////////////////////////////////////////
// The quickest useful run: a little traffic on every link with no
// backpressure and no pacing, so the link runs flat out and any basic
// wiring or width mistake shows up immediately.
///////////////////////////////////////////////////////////////////
class axi_stream_smoke_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_smoke_test)

  extern function new(string name = "axi_stream_smoke_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);

endclass : axi_stream_smoke_test

function axi_stream_smoke_test::new(string name = "axi_stream_smoke_test",
                                    uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 4;
endfunction : new

function void axi_stream_smoke_test::configure_link(axi_stream_env_base e, int unsigned index);
  e.set_backpressure(AXIS_READY_ALWAYS);
  e.set_pacing(0, 0);
  // Back-to-back at full rate: nothing should ever stall, so a stall of
  // any length means the driver is inserting bubbles it was not asked for.
  e.slave_config.stall_timeout_cycles = 64;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// The headline test: all five parameterizations at once, each with its
// own randomly drawn backpressure model and source pacing.
///////////////////////////////////////////////////////////////////
class axi_stream_multiwidth_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_multiwidth_test)

  extern function new(string name = "axi_stream_multiwidth_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);

endclass : axi_stream_multiwidth_test

function axi_stream_multiwidth_test::new(string name = "axi_stream_multiwidth_test",
                                         uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 12;
endfunction : new

function void axi_stream_multiwidth_test::configure_link(axi_stream_env_base e,
                                                         int unsigned index);
  axi_stream_default_ready_policy policy;
  policy = axi_stream_default_ready_policy::type_id::create($sformatf("policy_%0d", index));
  // Anything but NEVER: this test expects every link to drain.
  if (!policy.randomize() with { mode != AXIS_READY_NEVER;
                                 ready_percent inside {[25:90]};
                                 stall_cycles  inside {[1:6]};
                                 burst_beats   inside {[1:12]};
                                 delay_max     inside {[0:8]}; })
    `uvm_fatal("RAND", "backpressure policy randomization failed")
  e.slave_config.ready_policy = policy;
  e.set_pacing(0, $urandom_range(4, 0));
  e.slave_config.stall_timeout_cycles = 2000;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// Every built-in backpressure model, one per link, deterministically
// assigned so a single run exercises all of them and the log says which
// link had which.
///////////////////////////////////////////////////////////////////
class axi_stream_backpressure_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_backpressure_test)

  extern function new(string name = "axi_stream_backpressure_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);

endclass : axi_stream_backpressure_test

function axi_stream_backpressure_test::new(string name = "axi_stream_backpressure_test",
                                           uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 10;
endfunction : new

function void axi_stream_backpressure_test::configure_link(axi_stream_env_base e,
                                                           int unsigned index);
  case (index)
    0 : e.set_backpressure(AXIS_READY_ALWAYS);
    1 : e.set_backpressure(AXIS_READY_RANDOM, .percent(30));
    2 : e.set_backpressure(AXIS_READY_DUTY,   .ready_cycles(1), .stall_cycles(3));
    3 : e.set_backpressure(AXIS_READY_BURST,  .burst_beats(4), .stall_cycles(6));
    4 : e.set_backpressure(AXIS_READY_DELAY,  .delay_min(0), .delay_max(8));
    default : e.set_backpressure(AXIS_READY_RANDOM, .percent(50));
  endcase
  // Source-side bubbles too, so the two pacing mechanisms interact
  // rather than each being tested against a perfectly behaved partner.
  e.set_pacing(0, 3);
  e.slave_config.stall_timeout_cycles = 4000;
endfunction : configure_link


///////////////////////////////////////////////////////////////////
// A link that refuses every transfer, then relents.
//
// This is the sharpest test of the master driver's handshake: with
// TREADY held low for hundreds of cycles, TVALID and the entire payload
// must stay exactly as first offered. The interface's TVALID_HELD and
// *_STABLE assertions are what actually check that, all the way through
// the stall. Releasing the backpressure afterwards then proves the
// stalled beats were only held, not lost.
///////////////////////////////////////////////////////////////////
class axi_stream_no_ready_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_no_ready_test)

  int unsigned stall_cycles = 300;

  extern function new(string name = "axi_stream_no_ready_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);
  extern virtual task run_phase(uvm_phase phase);

endclass : axi_stream_no_ready_test

function axi_stream_no_ready_test::new(string name = "axi_stream_no_ready_test",
                                       uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 6;
endfunction : new

function void axi_stream_no_ready_test::configure_link(axi_stream_env_base e,
                                                       int unsigned index);
  e.set_backpressure(AXIS_READY_NEVER);
  e.set_pacing(0, 0);
  // The whole point of this test is a very long legitimate stall, so the
  // deadlock watchdog stays off until backpressure is released.
  e.slave_config.stall_timeout_cycles = 0;
endfunction : configure_link

task axi_stream_no_ready_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "stalling every link, then releasing");

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end

  // Let the FIFOs fill and every link jam solid against TREADY low.
  ctrl.wait_cycles(stall_cycles);
  foreach (envs[i])
    if (envs[i].scoreboard.num_beats_matched != 0)
      `uvm_error("BACKPRESSURE", $sformatf(
          "link %s delivered %0d beats while TREADY was held low the whole time",
          envs[i].link_desc, envs[i].scoreboard.num_beats_matched))

  `uvm_info("BACKPRESSURE", "releasing backpressure on every link", UVM_LOW)
  foreach (envs[i]) begin
    envs[i].set_backpressure(AXIS_READY_ALWAYS);
    envs[i].slave_config.stall_timeout_cycles = 4000;
  end

  wait fork;
  drain();
  phase.drop_objection(this, "all links drained after release");
endtask : run_phase


///////////////////////////////////////////////////////////////////
// Traffic made of null and position bytes rather than dense payloads,
// which is where the TKEEP/TSTRB encodings get exercised. The reserved
// TKEEP=0/TSTRB=1 combination stays unreachable by construction, and
// the interface asserts that it never appears.
///////////////////////////////////////////////////////////////////
class axi_stream_sparse_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_sparse_test)

  extern function new(string name = "axi_stream_sparse_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);
  extern virtual task run_link(axi_stream_env_base e, int unsigned index);

endclass : axi_stream_sparse_test

function axi_stream_sparse_test::new(string name = "axi_stream_sparse_test",
                                     uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 8;
endfunction : new

function void axi_stream_sparse_test::configure_link(axi_stream_env_base e, int unsigned index);
  e.set_backpressure(AXIS_READY_RANDOM, .percent(60));
  e.set_pacing(0, 2);
  e.slave_config.stall_timeout_cycles = 4000;
endfunction : configure_link

task axi_stream_sparse_test::run_link(axi_stream_env_base e, int unsigned index);
  for (int p = 0; p < packets_per_link; p++) begin
    axi_stream_sparse_packet_seq sparse_sequence;
    sparse_sequence = axi_stream_sparse_packet_seq::type_id::create($sformatf("sparse_%0d_%0d", index, p));
    if (!sparse_sequence.randomize())
      `uvm_fatal("RAND", "sparse sequence randomization failed")
    sparse_sequence.start(e.master_sequencer);
  end
endtask : run_link


///////////////////////////////////////////////////////////////////
// Reset in the middle of live traffic on every link at once.
//
// The transfers in flight when ARESETn drops are expected to be lost --
// that is what reset means -- so checking is switched off across the
// disturbance and the scoreboards are flushed afterwards. What is being
// tested is what happens next: that both drivers come out of reset
// legally (TVALID low on the first edge after release, which the
// interface asserts) and that the link then carries a clean pass of
// traffic with nothing left over from before.
///////////////////////////////////////////////////////////////////
class axi_stream_reset_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_reset_test)

  extern function new(string name = "axi_stream_reset_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);
  extern virtual task run_phase(uvm_phase phase);

endclass : axi_stream_reset_test

function axi_stream_reset_test::new(string name = "axi_stream_reset_test",
                                    uvm_component parent = null);
  super.new(name, parent);
  packets_per_link = 10;
endfunction : new

function void axi_stream_reset_test::configure_link(axi_stream_env_base e, int unsigned index);
  e.set_backpressure(AXIS_READY_RANDOM, .percent(40));
  e.set_pacing(0, 2);
  e.slave_config.stall_timeout_cycles = 4000;
endfunction : configure_link

task axi_stream_reset_test::run_phase(uvm_phase phase);
  phase.raise_objection(this, "reset in the middle of traffic");

  // --- Pass 1: traffic across a reset. Nothing here is checked. ---
  foreach (envs[i]) envs[i].scoreboard.checking_enabled = 1'b0;

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end

  ctrl.wait_cycles(150);
  `uvm_info("RESET", "asserting ARESETn while every link is streaming", UVM_LOW)
  ctrl.assert_reset(6);

  wait fork;
  drain(2000);

  // --- Pass 2: the link must now behave as though nothing happened. ---
  foreach (envs[i]) begin
    envs[i].scoreboard.flush();
    envs[i].scoreboard.checking_enabled = 1'b1;
  end
  `uvm_info("RESET", "reset released; re-running traffic with checking on", UVM_LOW)

  foreach (envs[i]) begin
    automatic int unsigned idx = i;
    fork
      run_link(envs[idx], idx);
    join_none
  end
  wait fork;
  drain();

  phase.drop_objection(this, "post-reset traffic verified");
endtask : run_phase


///////////////////////////////////////////////////////////////////
// Video frames, at every pixel format and pixels-per-clock the UVC
// claims to support, on all five links at once.
//
// Each link runs several passes, one per format that fits it, and every
// pass sends whole frames and then checks that the frames rebuilt from
// the wire are the frames that were sent. What that actually proves,
// per pass:
//
//   * the pixel packing round-trips -- the bits the sequence put on
//     TDATA are the bits the collector reads back as pixels
//   * SOF and EOL land on the right beats, since the collector finds
//     frame and line boundaries from nothing else
//   * a short final beat is handled, because most of the frame widths
//     below are deliberately not a multiple of pixels_per_clock
//   * beat padding is handled, because several formats below do not
//     fill TDATA
//
// The two collectors are set up differently on purpose. The sink one is
// told the frame geometry, which is the recommended way and the only way
// on a link with no TKEEP. The source one is told nothing and derives
// the width from the kept bytes and the frame boundary from SOF, so both
// paths are exercised in the same run.
//
// Formats per link, all in one simulation:
//
//   link     TDATA  formats
//   -------- -----  -----------------------------------------------
//   env_w4     4B   RGBA8888 x1                        (32b, exact)
//   env_w8     8B   RGBA16 x1, RGBA8888 x2, RGBA10 x1  (64/64/40b)
//   env_w12   12B   RGBA12 x2, RGBA10 x2               (96/80b)
//   env_w16   16B   RGBA8888 x4, RGBA16 x2, RGBA12 x2  (128/128/96b)
//   env_min    4B   RGBA8888 x1, no SOF (no TUSER)     (32b, exact)
///////////////////////////////////////////////////////////////////
class axi_stream_video_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_video_test)

  int unsigned frames_per_pass   = 2;
  int unsigned frame_wait_limit  = 40000;

  // Frame geometry per link. The widths are chosen so that the largest
  // pixels-per-clock on that link does not divide the width, which is
  // the case a sender or receiver that assumes whole pixel groups gets
  // wrong -- 7 against 2 pixels per clock, 10 against 4.
  int unsigned m_frame_width[]  = '{8, 6, 7, 10, 4};
  int unsigned m_frame_height[] = '{4, 3, 4,  3, 4};

  extern function new(string name = "axi_stream_video_test", uvm_component parent = null);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);
  extern virtual task run_link(axi_stream_env_base e, int unsigned index);

  // The formats worth sending on this link, widest first.
  extern virtual function void build_formats(axi_stream_env_base e, int unsigned index,
                                             ref axi_stream_video_format formats[$]);

  // One pass: program both collectors, send frames_per_pass frames, and
  // check what came back at both ends.
  extern virtual task send_and_check(axi_stream_env_base e, int unsigned index,
                                     axi_stream_video_format video_format, int unsigned pass);

  // Block until the sink has rebuilt `count` frames, or complain.
  extern virtual task wait_for_frames(axi_stream_env_base e, int unsigned count);

  // Compare every frame a collector rebuilt against the one that was
  // sent, naming the link, the format and the differing pixel on
  // failure.
  extern virtual function void check_collected(axi_stream_env_base e,
                                               axi_stream_video_frame_collector collector,
                                               axi_stream_video_frame expected,
                                               axi_stream_video_format video_format,
                                               string which);

endclass : axi_stream_video_test

function axi_stream_video_test::new(string name = "axi_stream_video_test",
                                    uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_video_test::configure_link(axi_stream_env_base e, int unsigned index);
  // Backpressure and source bubbles both on: a frame has to survive
  // being stalled anywhere, including in the middle of a line, and SOF
  // and EOL have to stay attached to their beats while it does.
  e.set_backpressure(AXIS_READY_RANDOM, .percent(70));
  e.set_pacing(0, 2);
  e.slave_config.stall_timeout_cycles = 4000;
endfunction : configure_link

function void axi_stream_video_test::build_formats(axi_stream_env_base e, int unsigned index,
                                                   ref axi_stream_video_format formats[$]);
  formats.delete();
  case (index)
    0 : begin   // 4-byte link: one RGBA8888 pixel exactly fills a beat
      formats.push_back(axi_stream_video_format::rgba8888(1));
    end
    1 : begin   // 8-byte link
      formats.push_back(axi_stream_video_format::rgba(16, 1));  // 64b, exact fit
      formats.push_back(axi_stream_video_format::rgba8888(2));  // 64b, two pixels per clock
      formats.push_back(axi_stream_video_format::rgba(10, 1));  // 40b of 64: 3 bytes padded
    end
    2 : begin   // 12-byte link
      formats.push_back(axi_stream_video_format::rgba(12, 2));  // 96b, exact fit
      formats.push_back(axi_stream_video_format::rgba(10, 2));  // 80b of 96: 2 bytes padded
    end
    3 : begin   // 16-byte link
      formats.push_back(axi_stream_video_format::rgba8888(4));  // 128b, four pixels per clock
      formats.push_back(axi_stream_video_format::rgba(16, 2));  // 128b, exact fit
      formats.push_back(axi_stream_video_format::rgba(12, 2));  // 96b of 128: 4 bytes padded
    end
    default : begin   // env_min: TDATA/TVALID/TREADY/TLAST and nothing else
      axi_stream_video_format bare_format;
      bare_format = axi_stream_video_format::rgba8888(1);
      // No TUSER here, so there is no SOF to mark. The frame still goes
      // out as TLAST-delimited lines; the receiver is told the height
      // instead of finding it. This is the degraded case working, not a
      // workaround -- see axi_stream_video_base_seq's warning.
      bare_format.drive_sof = 1'b0;
      formats.push_back(bare_format);
    end
  endcase
endfunction : build_formats

task axi_stream_video_test::run_link(axi_stream_env_base e, int unsigned index);
  axi_stream_video_format formats[$];

  build_formats(e, index, formats);

  foreach (formats[k])
    send_and_check(e, index, formats[k], k);
endtask : run_link

task axi_stream_video_test::send_and_check(axi_stream_env_base e, int unsigned index,
                                           axi_stream_video_format video_format,
                                           int unsigned pass);
  axi_stream_video_pattern_seq video_sequence;
  axi_stream_video_frame       expected;
  axi_stream_video_pattern_e   pattern;
  int unsigned                 w = m_frame_width[index];
  int unsigned                 h = m_frame_height[index];
  int unsigned                 n = frames_per_pass;

  // A different pattern each pass, so no pass can pass for the reason
  // the previous one did.
  case (pass % 4)
    0       : pattern = AXIS_PATTERN_BARS;
    1       : pattern = AXIS_PATTERN_INDEX;
    2       : pattern = AXIS_PATTERN_RAMP;
    default : pattern = AXIS_PATTERN_CHECKER;
  endcase

  // The sink is told the geometry; the source derives everything.
  e.set_video_format(video_format, 0, 0);
  e.sink_frame_collector.expected_width  = w;
  e.sink_frame_collector.expected_height = h;
  if (!video_format.drive_sof)
    e.source_frame_collector.expected_height = h;  // nothing to close a frame on otherwise

  e.source_frame_collector.reset();
  e.sink_frame_collector.reset();
  e.source_frame_collector.received_frames.delete();
  e.sink_frame_collector.received_frames.delete();

  video_sequence = axi_stream_video_pattern_seq::type_id::create(
                       $sformatf("video_%0d_%0d", index, pass));
  video_sequence.video_format = video_format;
  video_sequence.pattern      = pattern;
  if (!video_sequence.randomize() with { frame_width  == w;
                                         frame_height == h;
                                         num_frames   == n; })
    `uvm_fatal("RAND", "video pattern sequence randomization failed")

  `uvm_info("VIDEO", $sformatf("%s: sending %0d %0dx%0d %s frame(s) as %s",
                               e.link_desc, n, w, h, pattern.name(),
                               video_format.convert2string()), UVM_LOW)
  video_sequence.start(e.master_sequencer);
  expected = video_sequence.frame;

  wait_for_frames(e, n);

  // The last frame of a pass has no SOF after it to close it, so it is
  // flushed by hand. Only the source side needs this: the sink was told
  // the height and closes on the line count.
  e.source_frame_collector.publish_frame();

  check_collected(e, e.source_frame_collector, expected, video_format, "source");
  check_collected(e, e.sink_frame_collector,   expected, video_format, "sink");
endtask : send_and_check

task axi_stream_video_test::wait_for_frames(axi_stream_env_base e, int unsigned count);
  int unsigned elapsed = 0;
  while ((elapsed < frame_wait_limit) &&
         (e.sink_frame_collector.received_frames.size() < count)) begin
    ctrl.wait_cycles(16);
    elapsed += 16;
  end
  // A few more cycles so a frame that completed on the last sampled
  // beat has reached the analysis ports.
  ctrl.wait_cycles(8);
endtask : wait_for_frames

function void axi_stream_video_test::check_collected(axi_stream_env_base e,
                                                     axi_stream_video_frame_collector collector,
                                                     axi_stream_video_frame expected,
                                                     axi_stream_video_format video_format,
                                                     string which);
  if (expected == null) begin
    `uvm_error("VIDEO", $sformatf("%s %s: the sequence produced no frame to compare against",
                                  e.link_desc, which))
    return;
  end

  if (collector.received_frames.size() != frames_per_pass) begin
    `uvm_error("VIDEO", $sformatf(
        "%s %s [%s]: rebuilt %0d frame(s), expected %0d",
        e.link_desc, which, video_format.convert2string(),
        collector.received_frames.size(), frames_per_pass))
    return;
  end

  foreach (collector.received_frames[f]) begin
    axi_stream_video_frame received = collector.received_frames[f];
    if (!expected.compare(received)) begin
      int diff = expected.first_difference(received);
      if (diff < 0) begin
        `uvm_error("VIDEO", $sformatf("%s %s [%s]: frame %0d differs: %0dx%0d vs %0dx%0d",
                                      e.link_desc, which, video_format.convert2string(), f,
                                      expected.width, expected.height,
                                      received.width, received.height))
      end
      else begin
        int unsigned row = diff / expected.width;
        int unsigned col = diff % expected.width;
        `uvm_error("VIDEO", $sformatf(
            "%s %s [%s]: frame %0d pixel (row %0d, col %0d) sent %s, got %s",
            e.link_desc, which, video_format.convert2string(), f, row, col,
            expected.component_string(row, col), received.component_string(row, col)))
      end
    end
  end

  `uvm_info("VIDEO", $sformatf("%s %s [%s]: %0d frame(s) match",
                               e.link_desc, which, video_format.convert2string(),
                               collector.received_frames.size()), UVM_LOW)
endfunction : check_collected


///////////////////////////////////////////////////////////////////
// The image file readers and writers, in a live simulation.
//
// Every checked-in file under images/ is read, sent over all five links
// and checked against what came back, which proves the readers produce
// the pixels the sender then puts on the wire. The files are chosen to
// cover the grammars rather than to look like anything:
//
//   frame_4x4.hex     the plain ASCII hex frame, banner comments and all
//   bars_8x4.hex      colour bars, so a component swap would be obvious
//   gradient_4x3.hex  every spelling the hex reader accepts at once:
//                     bare hex, 0x and 0X, '_' separators, '//' and '#'
//                     comments, a trailing comment on a data line, and a
//                     blank line inside the image
//   rgb_4x3.ppm       Netpbm P3, read into a 3-component RGB frame
//   ramp_4x3.pgm      Netpbm P2, read with no format set at all, so the
//                     format is derived from the file's own header
//
// Link 0 additionally round-trips each received frame back out through
// every writer and reads it in again, which is what covers write_hex,
// write_pnm in both its ASCII and binary forms, and the binary P5/P6
// reader that no checked-in text file would reach.
///////////////////////////////////////////////////////////////////
class axi_stream_video_file_test extends axi_stream_base_test;

  `uvm_component_utils(axi_stream_video_file_test)

  // Where the images live. Overridable from the command line, since a
  // relative path only works from the directory make runs in:
  //   make TEST=axi_stream_video_file_test PLUSARGS=+IMAGE_DIR=/path/to/images
  string image_dir = "images";

  int unsigned frame_wait_limit = 40000;

  extern function new(string name = "axi_stream_video_file_test", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void configure_link(axi_stream_env_base e, int unsigned index);
  extern virtual task run_link(axi_stream_env_base e, int unsigned index);

  // The file list, and the format each one is read with. A null format
  // means "let the file say", which only a PNM can.
  extern virtual function string image_name(int unsigned which);
  extern virtual function axi_stream_video_format image_format(int unsigned which);
  extern virtual function int unsigned num_images();

  extern virtual task send_file(axi_stream_env_base e, int unsigned index, int unsigned which);
  extern virtual task wait_for_frames(axi_stream_env_base e, int unsigned count);

  // Write a frame out and read it straight back in, which has to give
  // the same frame. Run on one link only: it tests the file layer, which
  // does not care what the traffic looked like.
  extern virtual function void round_trip(axi_stream_video_frame frame, string tag);

endclass : axi_stream_video_file_test

function axi_stream_video_file_test::new(string name = "axi_stream_video_file_test",
                                         uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_video_file_test::build_phase(uvm_phase phase);
  string from_command_line;
  super.build_phase(phase);
  if ($value$plusargs("IMAGE_DIR=%s", from_command_line))
    image_dir = from_command_line;
endfunction : build_phase

function void axi_stream_video_file_test::configure_link(axi_stream_env_base e,
                                                         int unsigned index);
  e.set_backpressure(AXIS_READY_RANDOM, .percent(75));
  e.set_pacing(0, 1);
  e.slave_config.stall_timeout_cycles = 4000;
endfunction : configure_link

function int unsigned axi_stream_video_file_test::num_images();
  return 5;
endfunction : num_images

function string axi_stream_video_file_test::image_name(int unsigned which);
  case (which)
    0       : return "frame_4x4.hex";
    1       : return "bars_8x4.hex";
    2       : return "gradient_4x3.hex";
    3       : return "rgb_4x3.ppm";
    default : return "ramp_4x3.pgm";
  endcase
endfunction : image_name

function axi_stream_video_format axi_stream_video_file_test::image_format(int unsigned which);
  case (which)
    // A hex token is a packed pixel word, so the hex files need to be
    // told the layout; there is nothing in the file to derive it from.
    0, 1, 2 : return axi_stream_video_format::rgba8888(1);
    // 24 bits on a 4-byte link: one byte of every beat is padding.
    3       : return axi_stream_video_format::rgb(8, 1);
    // Null: read_pnm derives gray 8bpc from the P2 header itself.
    default : return null;
  endcase
endfunction : image_format

task axi_stream_video_file_test::run_link(axi_stream_env_base e, int unsigned index);
  for (int unsigned which = 0; which < num_images(); which++)
    send_file(e, index, which);
endtask : run_link

task axi_stream_video_file_test::send_file(axi_stream_env_base e, int unsigned index,
                                           int unsigned which);
  axi_stream_video_file_seq video_sequence;
  axi_stream_video_frame    expected;
  axi_stream_video_format   video_format;
  string                    path = {image_dir, "/", image_name(which)};

  // The frame is loaded here rather than inside the sequence so that its
  // geometry is known before the collectors are programmed with it.
  expected = axi_stream_video_frame::type_id::create("expected");
  expected.video_format = image_format(which);
  if (!expected.load(path)) begin
    `uvm_error("VIDEO_FILE", $sformatf("%s: could not read '%s'", e.link_desc, path))
    return;
  end
  video_format = expected.video_format;     // set by the reader when it was null

  // env_min carries no TUSER, so SOF cannot be marked there.
  if (e == env_min)
    video_format.drive_sof = 1'b0;

  e.set_video_format(video_format, expected.width, expected.height);
  e.source_frame_collector.reset();
  e.sink_frame_collector.reset();
  e.source_frame_collector.received_frames.delete();
  e.sink_frame_collector.received_frames.delete();

  video_sequence = axi_stream_video_file_seq::type_id::create(
                       $sformatf("file_%0d_%0d", index, which));
  video_sequence.frame = expected;          // already loaded; the sequence just sends it
  if (!video_sequence.randomize() with { num_frames == 1; })
    `uvm_fatal("RAND", "video file sequence randomization failed")

  `uvm_info("VIDEO_FILE", $sformatf("%s: sending %s as %s",
                                    e.link_desc, path, video_format.convert2string()), UVM_LOW)
  video_sequence.start(e.master_sequencer);

  wait_for_frames(e, 1);

  if (e.sink_frame_collector.received_frames.size() != 1) begin
    `uvm_error("VIDEO_FILE", $sformatf("%s: '%s' produced %0d frame(s) at the sink, expected 1",
                                       e.link_desc, path,
                                       e.sink_frame_collector.received_frames.size()))
    return;
  end

  if (!expected.compare(e.sink_frame_collector.received_frames[0])) begin
    int diff = expected.first_difference(e.sink_frame_collector.received_frames[0]);
    `uvm_error("VIDEO_FILE", $sformatf("%s: '%s' came back changed (first difference at pixel %0d)",
                                       e.link_desc, path, diff))
    return;
  end

  `uvm_info("VIDEO_FILE", $sformatf("%s: '%s' (%0dx%0d) round-tripped over the link",
                                    e.link_desc, path, expected.width, expected.height), UVM_LOW)

  // The writers and the binary reader, once, on the frame that just came
  // off the wire.
  if (index == 0)
    round_trip(e.sink_frame_collector.received_frames[0],
               $sformatf("received_%0d", which));
endtask : send_file

task axi_stream_video_file_test::wait_for_frames(axi_stream_env_base e, int unsigned count);
  int unsigned elapsed = 0;
  while ((elapsed < frame_wait_limit) &&
         (e.sink_frame_collector.received_frames.size() < count)) begin
    ctrl.wait_cycles(16);
    elapsed += 16;
  end
  ctrl.wait_cycles(8);
endtask : wait_for_frames

function void axi_stream_video_file_test::round_trip(axi_stream_video_frame frame, string tag);
  axi_stream_video_frame reread;
  string                 hex_path = {tag, ".hex"};

  if (!frame.save_hex(hex_path)) begin
    `uvm_error("VIDEO_FILE", $sformatf("could not write '%s'", hex_path))
    return;
  end
  reread = axi_stream_video_frame::type_id::create("reread");
  reread.video_format = frame.video_format;
  if (!reread.load(hex_path))
    `uvm_error("VIDEO_FILE", $sformatf("could not read back '%s'", hex_path))
  else if (!frame.compare(reread))
    `uvm_error("VIDEO_FILE", $sformatf("'%s' did not survive a write/read round trip", hex_path))
  else
    `uvm_info("VIDEO_FILE", $sformatf("'%s' round-tripped through the hex writer and reader",
                                      hex_path), UVM_LOW)

  // PNM carries at most three components, so a frame with an alpha
  // channel would come back opaque and compare unequal for a reason
  // that is the format's, not the UVC's. Round-trip only the frames PNM
  // can actually hold.
  if (frame.video_format.components_per_pixel > 3) begin
    `uvm_info("VIDEO_FILE", $sformatf(
        "skipping the PNM round trip for %s: PNM holds 3 components, this frame has %0d",
        tag, frame.video_format.components_per_pixel), UVM_MEDIUM)
    return;
  end

  // Binary (P5/P6) and ASCII (P2/P3) are different writers and
  // different readers, so both go round.
  for (int pass = 0; pass < 2; pass++) begin
    bit    binary   = (pass == 1);
    string pnm_path = {tag, binary ? "_bin" : "_ascii",
                       (frame.video_format.components_per_pixel >= 3) ? ".ppm" : ".pgm"};

    if (!frame.save_pnm(pnm_path, binary)) begin
      `uvm_error("VIDEO_FILE", $sformatf("could not write '%s'", pnm_path))
      continue;
    end
    reread = axi_stream_video_frame::type_id::create("reread");
    reread.video_format = frame.video_format;
    if (!reread.load(pnm_path))
      `uvm_error("VIDEO_FILE", $sformatf("could not read back '%s'", pnm_path))
    else if (!frame.compare(reread))
      `uvm_error("VIDEO_FILE", $sformatf("'%s' did not survive a write/read round trip", pnm_path))
    else
      `uvm_info("VIDEO_FILE", $sformatf("'%s' round-tripped through the PNM writer and reader",
                                        pnm_path), UVM_LOW)
  end
endfunction : round_trip
