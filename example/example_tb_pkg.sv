///////////////////////////////////////////////////////////////////
// Filename: example_tb_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Testbench package for the integration example. Declares the
//           link's widths once and names the two parameterized types
//           that depend on them, so no other file has to repeat them.
///////////////////////////////////////////////////////////////////

package example_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // The UVC. This import plus axi_stream_if.sv is all a project needs.
  import axi_stream_pkg::*;

  // ---------------------------------------------------------------------
  // Your link's geometry, written down once.
  //
  // A width of 0 for ID/DEST/USER means the link does not carry that
  // signal at all -- so a plain TDATA/TVALID/TREADY/TLAST stream is
  // ID_WIDTH = DEST_WIDTH = USER_WIDTH = 0. TDATA is in *bytes*, and any
  // integer number of them is legal: 12 is as valid as 16.
  // ---------------------------------------------------------------------
  parameter int EX_DATA_BYTES = 8;   // TDATA is 64 bits; TKEEP/TSTRB are 8
  parameter int EX_ID_WIDTH   = 4;
  parameter int EX_DEST_WIDTH = 4;
  parameter int EX_USER_WIDTH = 8;   // one bit per byte, as the spec suggests

  // ---------------------------------------------------------------------
  // Names for the two parameterized types that carry those widths.
  //
  // This is the single most useful habit when integrating the UVC.
  // `virtual axi_stream_if #(8,4,4,8)` and `#(4,0,0,0)` are different
  // SystemVerilog types, so a config-DB set() and get() that disagree by
  // one parameter fail silently -- the agent just reports NOVIF. Writing
  // the widths once and using these names everywhere makes that
  // impossible rather than merely unlikely.
  // ---------------------------------------------------------------------
  typedef virtual axi_stream_if #(EX_DATA_BYTES, EX_ID_WIDTH,
                                  EX_DEST_WIDTH, EX_USER_WIDTH) example_vif_t;

  typedef axi_stream_agent      #(EX_DATA_BYTES, EX_ID_WIDTH,
                                  EX_DEST_WIDTH, EX_USER_WIDTH) example_agent_t;

  `include "example_scoreboard.sv"
  `include "example_env.sv"
  `include "example_base_test.sv"

endpackage : example_tb_pkg
