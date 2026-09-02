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
