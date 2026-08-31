///////////////////////////////////////////////////////////////////
// Filename: axi_stream_tb_pkg.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Local package for the AXI4-Stream UVC's self-test:
//           scoreboard, per-link environment, and the test library.
///////////////////////////////////////////////////////////////////
//
// Kept separate from axi_stream_pkg (the reusable UVC) on purpose:
// axi_stream_uvc.f pulls in only the UVC, so a project reusing it never
// compiles this file, the FIFO, or these tests.

package axi_stream_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_stream_pkg::*;

  `include "axi_stream_scoreboard.sv"
  `include "axi_stream_env.sv"
  `include "axi_stream_test_lib.sv"

endpackage : axi_stream_tb_pkg
