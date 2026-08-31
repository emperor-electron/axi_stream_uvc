///////////////////////////////////////////////////////////////////
// Filename: axi_stream_slave_driver.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM driver for the slave (sink) end of an AXI4-Stream link.
//           It drives TREADY and nothing else, taking its cue from the
//           configured axi_stream_ready_policy -- this is the UVC's
//           programmable backpressure generator.
///////////////////////////////////////////////////////////////////
//
// Use this driver against a DUT's *master* port.
//
// Unlike the master driver, this one is not sequence-driven: TREADY is a
// property of the sink, not of any transaction, so it runs free from the
// policy object for the whole simulation and the agent's sequencer stays
// unused on this side. Programming backpressure is therefore a matter of
// configuring (or replacing) the policy, not of writing stimulus:
//
//   cfg.set_ready_mode(AXIS_READY_BURST, .burst_beats(8), .stall_cycles(3));
//   cfg.ready_policy = my_credit_based_policy;   // or anything you like
//
// The policy is asked for the *next* cycle's TREADY once per ACLK edge,
// before this cycle's TVALID can influence it. That one-cycle offset is
// deliberate: it makes it structurally impossible for a backpressure
// model to create a combinational TREADY-from-TVALID path, which is the
// classic way a testbench accidentally hides a deadlock that real
// hardware would hit.

class axi_stream_slave_driver #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0
) extends uvm_driver #(axi_stream_seq_item);

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;
  typedef axi_stream_slave_driver #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t                   vif;
  axi_stream_config       cfg;
  axi_stream_ready_policy policy;

  // Cycle census, reported at the end of the run: the ratio of these is
  // the backpressure the DUT actually saw, which is worth knowing when a
  // random policy makes every seed a different experiment.
  int unsigned num_cycles_ready = 0;
  int unsigned num_cycles_total = 0;
  int unsigned num_beats_accepted = 0;

  extern function new(string name = "axi_stream_slave_driver", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);
  extern virtual task wait_reset_release();

endclass : axi_stream_slave_driver

function axi_stream_slave_driver::new(string name = "axi_stream_slave_driver",
                                      uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_slave_driver::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_stream_if #(%0d,%0d,%0d,%0d) set in the config DB for %s",
        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH, get_full_name()))
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "cfg", cfg))
    `uvm_fatal("NOCFG", "no axi_stream_config set in the config DB")

  // A config that never mentioned backpressure gets none, rather than
  // some arbitrary default throttle it did not ask for.
  if (cfg.ready_policy == null) begin
    axi_stream_default_ready_policy dflt;
    dflt = axi_stream_default_ready_policy::type_id::create("ready_policy");
    dflt.mode = AXIS_READY_ALWAYS;
    cfg.ready_policy = dflt;
  end
  policy = cfg.ready_policy;
endfunction : build_phase

task axi_stream_slave_driver::run_phase(uvm_phase phase);
  // The TREADY value currently on the wire. Tracked here rather than
  // read back from the clocking block because a clocking block output
  // reports what was written to it, not what the link is carrying.
  bit cur_ready;
  bit beat_accepted;
  bit next;

  forever begin
    cur_ready = 1'b0;
    vif.slv_cb.tready <= 1'b0;
    wait_reset_release();
    policy.reset();

    // One decision per ACLK edge, for as long as reset stays away.
    while (vif.slv_cb.aresetn === 1'b1) begin
      // Re-read the config's policy every cycle rather than caching it,
      // so a test can swap the backpressure model mid-run -- switching
      // from AXIS_READY_NEVER to AXIS_READY_ALWAYS to release a
      // deliberately stalled link, say -- and have it take effect.
      if ((cfg.ready_policy != null) && (cfg.ready_policy != policy)) begin
        policy = cfg.ready_policy;
        policy.reset();
        `uvm_info("BACKPRESSURE",
                  $sformatf("backpressure model changed to %s", policy.convert2string()),
                  UVM_MEDIUM)
      end

      beat_accepted = (vif.slv_cb.tvalid === 1'b1) && cur_ready;

      num_cycles_total++;
      if (cur_ready) num_cycles_ready++;
      if (beat_accepted) num_beats_accepted++;

      next = policy.next_ready(.tvalid(vif.slv_cb.tvalid === 1'b1),
                               .tlast (vif.slv_cb.tlast  === 1'b1),
                               .beat_accepted(beat_accepted));

      vif.slv_cb.tready <= next;
      cur_ready         = next;
      @(vif.slv_cb);
    end

    `uvm_info("RESET", "ARESETn asserted; dropping TREADY", UVM_MEDIUM)
  end
endtask : run_phase

task axi_stream_slave_driver::wait_reset_release();
  if (vif.aresetn !== 1'b1) begin
    `uvm_info("RESET", "waiting for ARESETn to deassert", UVM_MEDIUM)
    wait (vif.aresetn === 1'b1);
  end
  @(vif.slv_cb);
endtask : wait_reset_release

function void axi_stream_slave_driver::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("DRV", $sformatf(
      "backpressure %s: accepted %0d beats, TREADY high %0d of %0d cycles (%0d%%)",
      (policy == null) ? "(none)" : policy.convert2string(),
      num_beats_accepted, num_cycles_ready, num_cycles_total,
      (num_cycles_total == 0) ? 0 : (100 * num_cycles_ready) / num_cycles_total), UVM_LOW)
endfunction : report_phase
