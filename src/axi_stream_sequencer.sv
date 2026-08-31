///////////////////////////////////////////////////////////////////
// Filename: axi_stream_sequencer.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM sequencer that arbitrates and dispatches
//           axi_stream_seq_item beats from sequences to the AXI4-Stream
//           master driver.
///////////////////////////////////////////////////////////////////
//
// Note what is *not* here: any width parameter. Because the transaction
// is unparameterized, so is the sequencer, so a test can hold every
// link's sequencer -- 4-byte, 12-byte, 16-byte -- in one plain queue and
// start the same sequence on all of them.
//
// The sequencer carries the agent's config so that sequences reached
// through p_sequencer can size their beats without being handed the
// config separately.

class axi_stream_sequencer extends uvm_sequencer #(axi_stream_seq_item);

  axi_stream_config cfg;

  `uvm_component_utils(axi_stream_sequencer)

  extern function new(string name = "axi_stream_sequencer", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);

endclass : axi_stream_sequencer

function axi_stream_sequencer::new(string name = "axi_stream_sequencer", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void axi_stream_sequencer::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "cfg", cfg))
    `uvm_fatal("NOCFG", "no axi_stream_config set in the config DB")
endfunction : build_phase
