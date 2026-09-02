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
//                      .DEST_WIDTH(8), .USER_WIDTH(12)) agent;
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
  axi_stream_config agent_config;

  monitor_t            monitor;
  axi_stream_sequencer sequencer;
  master_driver_t      master_driver;   // non-null only when active and AXIS_MASTER
  slave_driver_t       slave_driver;    // non-null only when active and AXIS_SLAVE
  axi_stream_coverage  coverage;

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

  if (!uvm_config_db#(axi_stream_config)::get(this, "", "agent_config", agent_config)) begin
    `uvm_info("CFG", "no axi_stream_config provided; building a default one", UVM_MEDIUM)
    agent_config = axi_stream_config::type_id::create("agent_config");
  end
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_stream_if #(%0d,%0d,%0d,%0d) set in the config DB for %s",
        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH, get_full_name()))

  adopt_interface_geometry();

  // uvm_agent reads its own is_active from the config DB; keep the two
  // views of "active" from disagreeing by letting the config win.
  is_active = agent_config.is_active;

  // Hand both down to every child, so a user only ever sets them once,
  // on the agent.
  uvm_config_db#(axi_stream_config)::set(this, "*", "agent_config", agent_config);
  uvm_config_db#(vif_t)::set(this, "*", "vif", vif);

  monitor = monitor_t::type_id::create("monitor", this);

  if (agent_config.coverage_enable)
    coverage = axi_stream_coverage::type_id::create("coverage", this);

  if (get_is_active() == UVM_ACTIVE) begin
    sequencer = axi_stream_sequencer::type_id::create("sequencer", this);
    case (agent_config.role)
      AXIS_MASTER : master_driver = master_driver_t::type_id::create("master_driver", this);
      AXIS_SLAVE  : slave_driver = slave_driver_t::type_id::create("slave_driver", this);
      default     : `uvm_fatal("ROLE", $sformatf("unhandled role %s", agent_config.role.name()))
    endcase
  end
endfunction : build_phase

function void axi_stream_agent::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if (coverage != null)
    monitor.beat_analysis_port.connect(coverage.analysis_export);
  if (master_driver != null)
    master_driver.seq_item_port.connect(sequencer.seq_item_export);
  // The slave driver is not sequence-driven: TREADY comes from the
  // backpressure policy, not from transactions, so there is deliberately
  // nothing to connect it to.
endfunction : connect_phase

// The config's widths and the agent's parameters describe the same link
// from two directions. Where the config is silent, take the parameters;
// where it disagrees, say so loudly -- a config that claims 4 bytes on a
// 16-byte link would otherwise just quietly truncate every payload.
function void axi_stream_agent::adopt_interface_geometry();
  if (agent_config.data_bytes != DATA_BYTES) begin
    if (agent_config.data_bytes != 0)
      `uvm_warning("GEOMETRY", $sformatf(
          {"config says TDATA is %0d bytes but this agent is parameterized for %0d; ",
           "using %0d"},
          agent_config.data_bytes, DATA_BYTES, DATA_BYTES))
    agent_config.data_bytes = DATA_BYTES;
  end
  // TID/TDEST/TUSER presence follows straight from the widths: a link
  // parameterized for 8 bits of TID carries TID, and one parameterized
  // for 0 cannot. There is no third option to configure, so this is
  // derived rather than left to a config that could contradict it.
  agent_config.id_width   = ID_WIDTH;
  agent_config.dest_width = DEST_WIDTH;
  agent_config.user_width = USER_WIDTH;
  agent_config.has_tid    = (ID_WIDTH   > 0);
  agent_config.has_tdest  = (DEST_WIDTH > 0);
  agent_config.has_tuser  = (USER_WIDTH > 0);

  // TKEEP/TSTRB/TLAST have no width to derive from -- their presence
  // does not change any signal's size -- so those stay the config's call.
endfunction : adopt_interface_geometry

// Tell the interface which optional signals are real, so its assertions
// stop checking the ones this link does not carry. Done in
// end_of_elaboration so it lands before any driver or DUT has run.
function void axi_stream_agent::end_of_elaboration_phase(uvm_phase phase);
  super.end_of_elaboration_phase(phase);
  vif.configure(.en_tkeep (agent_config.has_tkeep),
                .en_tstrb (agent_config.has_tstrb),
                .en_tlast (agent_config.has_tlast),
                .en_tid   (agent_config.has_tid),
                .en_tdest (agent_config.has_tdest),
                .en_tuser (agent_config.has_tuser),
                .en_checks(agent_config.protocol_checks_enable));
  `uvm_info("CFG", $sformatf("%s -> %s", vif.path(), agent_config.convert2string()), UVM_LOW)
endfunction : end_of_elaboration_phase

function uvm_analysis_port #(axi_stream_seq_item) axi_stream_agent::beat_port();
  return monitor.beat_analysis_port;
endfunction : beat_port

function uvm_analysis_port #(axi_stream_packet) axi_stream_agent::packet_port();
  return monitor.packet_analysis_port;
endfunction : packet_port
