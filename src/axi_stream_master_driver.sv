///////////////////////////////////////////////////////////////////
// Filename: axi_stream_master_driver.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM driver for the master (source) end of an AXI4-Stream
//           link: turns axi_stream_seq_item beats into TVALID/TDATA/
//           TKEEP/TSTRB/TLAST/TID/TDEST/TUSER activity that obeys the
//           handshake and reset rules of AMBA AXI4-Stream.
///////////////////////////////////////////////////////////////////
//
// Use this driver against a DUT's *slave* port -- it is the thing that
// sources transfers.
//
// Three protocol rules shape the whole task below, and are worth being
// explicit about because each one is easy to break by accident:
//
//  1. TVALID must never be withdrawn. Once a beat is offered it stays
//     offered, payload frozen, until TREADY completes the handshake.
//     The stall loop therefore touches nothing but the clock.
//
//  2. TVALID must never depend on TREADY. The decision to offer a beat
//     comes only from the sequencer, so this driver cannot express the
//     "wait for TREADY, then assert TVALID" deadlock even if a test
//     asked it to.
//
//  3. TVALID must be low during reset, and must still be low on the
//     first ACLK edge after ARESETn releases. wait_reset_release()
//     spends that edge doing nothing, which is exactly what it is for.
//
// Back-to-back streaming falls out of the clocking block rather than
// from a special case: after a handshake the driver tentatively writes
// TVALID low, then asks for the next beat. If the sequencer answers in
// zero time, drive_payload() overwrites that write before the clocking
// block applies either of them, so TVALID simply stays high and the
// link runs at full rate. If the sequencer blocks, the low wins and the
// link idles legally.

class axi_stream_master_driver #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0
) extends uvm_driver #(axi_stream_seq_item);

  localparam int TID_W   = (ID_WIDTH   > 0) ? ID_WIDTH   : 1;
  localparam int TDEST_W = (DEST_WIDTH > 0) ? DEST_WIDTH : 1;
  localparam int TUSER_W = (USER_WIDTH > 0) ? USER_WIDTH : 1;

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;
  typedef axi_stream_master_driver #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t             vif;
  axi_stream_config cfg;

  // Beats offered and beats actually transferred; reported at the end of
  // the run so a hung link is obvious without opening a waveform.
  int unsigned num_beats_driven = 0;
  int unsigned num_beats_dropped = 0;

  extern function new(string name = "axi_stream_master_driver", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  // Drive one beat: optional idle gap, then offer it and hold until the
  // handshake completes. Returns 0 if reset aborted the beat.
  extern virtual task drive_beat(axi_stream_seq_item item, output bit completed);

  // Put the link in its idle state: TVALID low, payload cleared. Legal
  // at any time, since TVALID low means nothing is being offered.
  extern virtual task drive_idle();

  // Present a beat's payload and assert TVALID, both applied at the next
  // ACLK edge by the clocking block.
  extern virtual task drive_payload(axi_stream_seq_item item);

  extern virtual task wait_reset_release();

endclass : axi_stream_master_driver

function axi_stream_master_driver::new(string name = "axi_stream_master_driver",
                                       uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_master_driver::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_stream_if #(%0d,%0d,%0d,%0d) set in the config DB for %s",
        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH, get_full_name()))
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "cfg", cfg))
    `uvm_fatal("NOCFG", "no axi_stream_config set in the config DB")
  if (USER_WIDTH > AXIS_MAX_USER_WIDTH)
    `uvm_fatal("USERW", $sformatf(
        "USER_WIDTH=%0d exceeds AXIS_MAX_USER_WIDTH=%0d; raise it in axi_stream_types.sv",
        USER_WIDTH, AXIS_MAX_USER_WIDTH))
endfunction : build_phase

task axi_stream_master_driver::run_phase(uvm_phase phase);
  bit completed;
  drive_idle();
  wait_reset_release();
  forever begin
    seq_item_port.get_next_item(req);
    // Reset may have arrived while we were waiting for stimulus.
    if (vif.aresetn !== 1'b1) begin
      drive_idle();
      wait_reset_release();
    end
    drive_beat(req, completed);
    if (completed) num_beats_driven++;
    else           num_beats_dropped++;
    seq_item_port.item_done();
  end
endtask : run_phase

task axi_stream_master_driver::drive_beat(axi_stream_seq_item item, output bit completed);
  completed = 1'b0;

  // Idle gap before the beat. This is the source-side pacing knob: a
  // non-zero delay is a legal bubble, since TVALID is low throughout.
  if (item.delay > 0) begin
    drive_idle();
    repeat (item.delay) begin
      @(vif.mst_cb);
      if (vif.mst_cb.aresetn !== 1'b1) begin
        drive_idle();
        return;
      end
    end
  end

  drive_payload(item);

  // Rule 1: hold everything steady until TREADY answers. Nothing in this
  // loop writes a payload signal, so stability is structural.
  forever begin
    @(vif.mst_cb);
    if (vif.mst_cb.aresetn !== 1'b1) begin
      `uvm_warning("RESET_ABORT",
          $sformatf("ARESETn asserted mid-transfer; dropping beat: %s", item.convert2string()))
      drive_idle();
      return;
    end
    if (vif.mst_cb.tready === 1'b1)
      break;
    item.stall_cycles++;
  end

  // Handshake complete. Withdraw the offer; a back-to-back beat arriving
  // in zero time will overwrite this before the clocking block applies it.
  vif.mst_cb.tvalid <= 1'b0;
  completed = 1'b1;
endtask : drive_beat

task axi_stream_master_driver::drive_idle();
  vif.mst_cb.tvalid <= 1'b0;
  vif.mst_cb.tdata  <= '0;
  vif.mst_cb.tkeep  <= '0;
  vif.mst_cb.tstrb  <= '0;
  vif.mst_cb.tlast  <= 1'b0;
  vif.mst_cb.tid    <= '0;
  vif.mst_cb.tdest  <= '0;
  vif.mst_cb.tuser  <= '0;
endtask : drive_idle

task axi_stream_master_driver::drive_payload(axi_stream_seq_item item);
  logic [8*DATA_BYTES-1:0] data_v;
  logic [DATA_BYTES-1:0]   keep_v;
  logic [DATA_BYTES-1:0]   strb_v;

  if (item.tdata.size() != DATA_BYTES)
    `uvm_fatal("WIDTH", $sformatf(
        {"beat carries %0d bytes but this link is %0d bytes wide -- did the sequence ",
         "get the agent's config? (%s)"},
        item.tdata.size(), DATA_BYTES, item.convert2string()))

  for (int i = 0; i < DATA_BYTES; i++) begin
    data_v[i*8 +: 8] = item.tdata[i];
    keep_v[i]        = item.tkeep[i];
    // A link with no TSTRB implies every kept byte is a data byte.
    strb_v[i]        = cfg.has_tstrb ? item.tstrb[i] : item.tkeep[i];
  end

  vif.mst_cb.tdata  <= data_v;
  vif.mst_cb.tkeep  <= cfg.has_tkeep ? keep_v : '1;
  vif.mst_cb.tstrb  <= strb_v;
  vif.mst_cb.tlast  <= cfg.has_tlast ? item.tlast : 1'b0;
  vif.mst_cb.tid    <= cfg.has_tid   ? item.tid  [0 +: TID_W]   : '0;
  vif.mst_cb.tdest  <= cfg.has_tdest ? item.tdest[0 +: TDEST_W] : '0;
  vif.mst_cb.tuser  <= cfg.has_tuser ? item.tuser[0 +: TUSER_W] : '0;
  vif.mst_cb.tvalid <= 1'b1;
endtask : drive_payload

// Rule 3: come out of reset with TVALID low, and spend the first
// post-reset ACLK edge doing nothing, so the earliest edge at which this
// driver can assert TVALID is the one after it.
task axi_stream_master_driver::wait_reset_release();
  if (vif.aresetn !== 1'b1) begin
    `uvm_info("RESET", "waiting for ARESETn to deassert", UVM_MEDIUM)
    wait (vif.aresetn === 1'b1);
  end
  @(vif.mst_cb);
endtask : wait_reset_release

function void axi_stream_master_driver::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("DRV", $sformatf("drove %0d beats (%0d dropped by reset)",
                             num_beats_driven, num_beats_dropped), UVM_LOW)
endfunction : report_phase
