///////////////////////////////////////////////////////////////////
// Filename: axi_stream_agent.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM agent for one end of an AXI4-Stream link. Instantiates
//           the monitor plus, when active, the driver appropriate to
//           the configured role and its sequencer, and reconciles the
//           run-time config with the interface's compile-time widths.
///////////////////////////////////////////////////////////////////
//
// This is the only place where the UVC's two worlds meet.
//
//  - Below it, three classes are parameterized by the link's widths,
//    because they touch a virtual interface and `virtual axi_stream_if
//    #(4,...)` and `#(16,...)` are different types.
//
//  - Above it, everything -- transactions, sequences, the sequencer,
//    coverage, and any scoreboard you write -- is unparameterized, so
//    it is written once and reused at every width.
//
// Instantiating one is therefore the only place a width appears:
//
//   axi_stream_agent #(.DATA_BYTES(12), .ID_WIDTH(8),
//                      .DEST_WIDTH(8), .USER_WIDTH(12)) agt;
//
// The role decides which driver exists at all. A master agent sources
// transfers into a DUT's slave port; a slave agent sources nothing but
// TREADY into a DUT's master port and is where backpressure is
// configured. Either way the monitor is the same and always present, so
// a passive agent still checks the protocol and feeds coverage.

class axi_stream_agent #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0
) extends uvm_agent;

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;
  typedef axi_stream_agent         #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) this_type;
  typedef axi_stream_master_driver #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) master_driver_t;
  typedef axi_stream_slave_driver  #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) slave_driver_t;
  typedef axi_stream_monitor       #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) monitor_t;

  `uvm_component_param_utils(this_type)

  vif_t             vif;
  axi_stream_config cfg;

  monitor_t           mon;
  axi_stream_sequencer sqr;
  master_driver_t     mst_drv;   // non-null only when active and AXIS_MASTER
  slave_driver_t      slv_drv;   // non-null only when active and AXIS_SLAVE
  axi_stream_coverage cov;

  extern function new(string name = "axi_stream_agent", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);
  extern virtual function void end_of_elaboration_phase(uvm_phase phase);

  // Fill in any link geometry the config did not state, and reject any
  // it stated wrongly, using this agent's own parameters as the truth.
  extern virtual function void adopt_interface_geometry();

  // Convenience for a testbench that holds the agent handle: the
  // sequencer to start master stimulus on, and the beat/packet streams.
  extern virtual function uvm_analysis_port #(axi_stream_seq_item) beat_port();
  extern virtual function uvm_analysis_port #(axi_stream_packet)   packet_port();

endclass : axi_stream_agent

function axi_stream_agent::new(string name = "axi_stream_agent", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_agent::build_phase(uvm_phase phase);
  super.build_phase(phase);

  if (!uvm_config_db#(axi_stream_config)::get(this, "", "cfg", cfg)) begin
    `uvm_info("CFG", "no axi_stream_config provided; building a default one", UVM_MEDIUM)
    cfg = axi_stream_config::type_id::create("cfg");
  end
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_stream_if #(%0d,%0d,%0d,%0d) set in the config DB for %s",
        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH, get_full_name()))

  adopt_interface_geometry();

  // uvm_agent reads its own is_active from the config DB; keep the two
  // views of "active" from disagreeing by letting the config win.
  is_active = cfg.is_active;

  // Hand both down to every child, so a user only ever sets them once,
  // on the agent.
  uvm_config_db#(axi_stream_config)::set(this, "*", "cfg", cfg);
  uvm_config_db#(vif_t)::set(this, "*", "vif", vif);

  mon = monitor_t::type_id::create("mon", this);

  if (cfg.coverage_enable)
    cov = axi_stream_coverage::type_id::create("cov", this);

  if (get_is_active() == UVM_ACTIVE) begin
    sqr = axi_stream_sequencer::type_id::create("sqr", this);
    case (cfg.role)
      AXIS_MASTER : mst_drv = master_driver_t::type_id::create("mst_drv", this);
      AXIS_SLAVE  : slv_drv = slave_driver_t::type_id::create("slv_drv", this);
      default     : `uvm_fatal("ROLE", $sformatf("unhandled role %s", cfg.role.name()))
    endcase
  end
endfunction : build_phase

function void axi_stream_agent::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if (cov != null)
    mon.ap.connect(cov.analysis_export);
  if (mst_drv != null)
    mst_drv.seq_item_port.connect(sqr.seq_item_export);
  // The slave driver is not sequence-driven: TREADY comes from the
  // backpressure policy, not from transactions, so there is deliberately
  // nothing to connect it to.
endfunction : connect_phase

// The config's widths and the agent's parameters describe the same link
// from two directions. Where the config is silent, take the parameters;
// where it disagrees, say so loudly -- a config that claims 4 bytes on a
// 16-byte link would otherwise just quietly truncate every payload.
function void axi_stream_agent::adopt_interface_geometry();
  if (cfg.data_bytes != DATA_BYTES) begin
    if (cfg.data_bytes != 0)
      `uvm_warning("GEOMETRY", $sformatf(
          {"config says TDATA is %0d bytes but this agent is parameterized for %0d; ",
           "using %0d"},
          cfg.data_bytes, DATA_BYTES, DATA_BYTES))
    cfg.data_bytes = DATA_BYTES;
  end
  // TID/TDEST/TUSER presence follows straight from the widths: a link
  // parameterized for 8 bits of TID carries TID, and one parameterized
  // for 0 cannot. There is no third option to configure, so this is
  // derived rather than left to a config that could contradict it.
  cfg.id_width   = ID_WIDTH;
  cfg.dest_width = DEST_WIDTH;
  cfg.user_width = USER_WIDTH;
  cfg.has_tid    = (ID_WIDTH   > 0);
  cfg.has_tdest  = (DEST_WIDTH > 0);
  cfg.has_tuser  = (USER_WIDTH > 0);

  // TKEEP/TSTRB/TLAST have no width to derive from -- their presence
  // does not change any signal's size -- so those stay the config's call.
endfunction : adopt_interface_geometry

// Tell the interface which optional signals are real, so its assertions
// stop checking the ones this link does not carry. Done in
// end_of_elaboration so it lands before any driver or DUT has run.
function void axi_stream_agent::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  vif.configure(.en_tkeep (cfg.has_tkeep),
                .en_tstrb (cfg.has_tstrb),
                .en_tlast (cfg.has_tlast),
                .en_tid   (cfg.has_tid),
                .en_tdest (cfg.has_tdest),
                .en_tuser (cfg.has_tuser),
                .en_checks(cfg.protocol_checks_enable));
  `uvm_info("CFG", $sformatf("%s -> %s", vif.path(), cfg.convert2string()), UVM_LOW)
endfunction : end_of_elaboration_phase

function uvm_analysis_port #(axi_stream_seq_item) axi_stream_agent::beat_port();
  return mon.ap;
endfunction : beat_port

function uvm_analysis_port #(axi_stream_packet) axi_stream_agent::packet_port();
  return mon.pkt_ap;
endfunction : packet_port
