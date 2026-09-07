///////////////////////////////////////////////////////////////////
// Filename: axi_stream_coverage.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Functional coverage subscriber for the AXI4-Stream UVC.
//           Answers "did this run actually exercise the protocol?" --
//           byte encodings, framing, routing, and above all how much
//           backpressure the link really saw.
///////////////////////////////////////////////////////////////////
//
// Unparameterized, like every other analysis-side class here, so one
// coverage model aggregates across links of different widths. Beat
// width is covered as a coverpoint instead of being baked into the
// type, which is what makes "did we exercise 12-byte links?" a
// coverage question rather than a compile-time one.

class axi_stream_coverage extends uvm_subscriber #(axi_stream_seq_item);

  `uvm_component_utils(axi_stream_coverage)

  axi_stream_config agent_config;

  // Sampled fields. Covergroups cannot sample a dynamic array directly,
  // so the interesting summaries are reduced to scalars first.
  local int unsigned cov_data_bytes;
  local bit          cov_tlast;
  local bit          cov_sparse;      // any lane not a data byte
  local bit          cov_position;    // any position byte (TKEEP=1,TSTRB=0)
  local int unsigned cov_stall;
  // Truncated to the 8 bits AXI4-Stream recommends as the maximum for
  // TID/TDEST; binning the full 32-bit field would leave almost every
  // bin permanently empty.
  local bit [7:0] cov_tid;
  local bit [7:0] cov_tdest;

  // How full the beat is, reduced to a width-independent category so
  // that one bin set covers a 4-byte and a 16-byte link alike. Bin
  // ranges have to be constants, and a link's byte count is not one.
  typedef enum { OCC_EMPTY, OCC_SINGLE, OCC_PARTIAL, OCC_FULL } occupancy_e;
  local occupancy_e cov_occupancy;

  covergroup cg_beat;
    option.per_instance = 1;
    option.name         = "axi_stream_beat_cg";

    // The link widths this UVC is expected to handle. The four common
    // TDATA sizes get their own bins so a run that quietly skipped one
    // shows up as a hole rather than as a healthy-looking total.
    cp_width : coverpoint cov_data_bytes {
      bins b1    = {1};
      bins b2    = {2};
      bins b4    = {4};
      bins b8    = {8};
      bins b12   = {12};
      bins b16   = {16};
      bins other = default;
    }

    // Empty / one byte / partly filled / completely filled, which is
    // where off-by-one bugs in width converters and packers live.
    cp_occupancy : coverpoint cov_occupancy;

    cp_tlast    : coverpoint cov_tlast;
    cp_sparse   : coverpoint cov_sparse;
    cp_position : coverpoint cov_position;

    // Backpressure actually experienced by this beat. The whole point of
    // a programmable ready model is to fill these bins.
    cp_stall : coverpoint cov_stall {
      bins none       = {0};
      bins short_[3]  = {[1:3]};
      bins mid        = {[4:15]};
      bins long_      = {[16:63]};
      bins very_long  = {[64:$]};
    }

    // The combinations that matter: a stalled end-of-packet beat and a
    // stalled sparse beat are both classic corner cases.
    x_last_stall  : cross cp_tlast, cp_stall;
    x_width_last  : cross cp_width, cp_tlast;
    x_width_stall : cross cp_width, cp_stall;
  endgroup : cg_beat

  covergroup cg_routing;
    option.per_instance = 1;
    option.name         = "axi_stream_routing_cg";
    cp_tid   : coverpoint cov_tid   { bins values[16] = {[0:255]}; }
    cp_tdest : coverpoint cov_tdest { bins values[16] = {[0:255]}; }
  endgroup : cg_routing

  extern function new(string name = "axi_stream_coverage", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  // The formal is `t`, not `beat`, because this overrides
  // uvm_subscriber::write and SystemVerilog matches overrides by formal
  // name -- renaming it would break any named-argument call through a
  // base-class handle. The one place in the UVC that cannot spell a
  // handle out.
  extern virtual function void write(axi_stream_seq_item t);

endclass : axi_stream_coverage

function axi_stream_coverage::new(string name = "axi_stream_coverage", uvm_component parent = null);
  super.new(name, parent);
  cg_beat    = new();
  cg_routing = new();
endfunction : new

function void axi_stream_coverage::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_stream_config set in the config DB")
endfunction : build_phase

function void axi_stream_coverage::write(axi_stream_seq_item t);
  axi_stream_seq_item beat = t;
  if (!agent_config.coverage_enable)
    return;

  cov_data_bytes = beat.data_bytes;
  cov_tlast      = beat.tlast;
  cov_stall      = beat.stall_cycles;
  cov_tid        = beat.tid;
  cov_tdest      = beat.tdest;

  case (beat.num_data_bytes())
    0                       : cov_occupancy = OCC_EMPTY;
    1                       : cov_occupancy = OCC_SINGLE;
    beat.data_bytes            : cov_occupancy = OCC_FULL;
    default                 : cov_occupancy = OCC_PARTIAL;
  endcase

  cov_sparse   = 1'b0;
  cov_position = 1'b0;
  foreach (beat.tkeep[i]) begin
    if (beat.byte_type(i) != AXIS_BYTE_DATA)     cov_sparse   = 1'b1;
    if (beat.byte_type(i) == AXIS_BYTE_POSITION) cov_position = 1'b1;
  end

  cg_beat.sample();
  if (agent_config.has_tid || agent_config.has_tdest)
    cg_routing.sample();
endfunction : write
