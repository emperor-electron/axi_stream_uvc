///////////////////////////////////////////////////////////////////
// Filename: axi_stream_link.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : One complete AXI4-Stream link of the self-test: a source
//           interface into a FIFO, a sink interface out of it, and the
//           config-DB plumbing that hands both to the matching env.
///////////////////////////////////////////////////////////////////
//
// This module is what makes "test several parameter combinations in one
// simulation" cheap. Everything a link needs is behind one parameter
// list, so the top module adds a width by instantiating this again with
// different numbers -- no `define, no second compile, no second run.
//
// ENV_NAME must match the instance name of the env that drives this
// link, since that is the config-DB scope the two interfaces are
// published to.
//
// Note which end drives what. On `src`, the UVC's master agent drives
// TVALID and the payload and the FIFO drives TREADY; on `snk` it is the
// other way round. Each signal therefore has exactly one driver, which
// is why the same interface type can serve both ends.

module axi_stream_link #(
  parameter string ENV_NAME   = "env",
  parameter int    DATA_BYTES = 4,
  parameter int    ID_WIDTH   = 0,
  parameter int    DEST_WIDTH = 0,
  parameter int    USER_WIDTH = 0,
  parameter int    FIFO_DEPTH = 16
) (
  input logic aclk,
  input logic aresetn
);

  import uvm_pkg::*;

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;

  // Into the DUT: driven by the UVC's master agent.
  axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) src (aclk, aresetn);
  // Out of the DUT: backpressured by the UVC's slave agent.
  axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) snk (aclk, aresetn);

  axi_stream_fifo #(
    .DATA_BYTES (DATA_BYTES),
    .ID_WIDTH   (ID_WIDTH),
    .DEST_WIDTH (DEST_WIDTH),
    .USER_WIDTH (USER_WIDTH),
    .DEPTH      (FIFO_DEPTH)
  ) u_fifo (
    .aclk          (aclk),
    .aresetn       (aresetn),

    .s_axis_tvalid (src.tvalid),
    .s_axis_tready (src.tready),
    .s_axis_tdata  (src.tdata),
    .s_axis_tkeep  (src.tkeep),
    .s_axis_tstrb  (src.tstrb),
    .s_axis_tlast  (src.tlast),
    .s_axis_tid    (src.tid),
    .s_axis_tdest  (src.tdest),
    .s_axis_tuser  (src.tuser),

    .m_axis_tvalid (snk.tvalid),
    .m_axis_tready (snk.tready),
    .m_axis_tdata  (snk.tdata),
    .m_axis_tkeep  (snk.tkeep),
    .m_axis_tstrb  (snk.tstrb),
    .m_axis_tlast  (snk.tlast),
    .m_axis_tid    (snk.tid),
    .m_axis_tdest  (snk.tdest),
    .m_axis_tuser  (snk.tuser)
  );

  initial begin
    uvm_config_db#(vif_t)::set(null, {"*.", ENV_NAME}, "vif_src", src);
    uvm_config_db#(vif_t)::set(null, {"*.", ENV_NAME}, "vif_snk", snk);
  end

endmodule : axi_stream_link
