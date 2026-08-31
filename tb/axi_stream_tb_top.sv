///////////////////////////////////////////////////////////////////
// Filename: axi_stream_tb_top.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Top level of the AXI4-Stream UVC self-test. Instantiates
//           five differently parameterized links side by side under one
//           clock and one reset, and starts the UVM test that drives
//           all of them at once.
///////////////////////////////////////////////////////////////////
//
// The five instantiations below are the whole answer to "does the UVC
// handle the popular AXI4-Stream parameter combinations?". They are
// module parameters, not `defines, so all five widths elaborate into a
// single snapshot and one simulation exercises the lot -- rather than
// five recompiles of the same testbench with a different macro each time.
//
// Each ENV_NAME matches an env instance name in axi_stream_base_test;
// that string is the config-DB scope the link's interfaces are published
// to, and is the only coupling between this file and the test.

`timescale 1ns/1ps

module axi_stream_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi_stream_pkg::*;
  import axi_stream_tb_pkg::*;

  // 100 MHz free-running clock.
  logic aclk;
  initial aclk = 1'b0;
  always #(5ns) aclk = ~aclk;

  // Sole owner of ARESETn for every link.
  axi_stream_tb_ctrl_if #(.RESET_CYCLES(5)) ctrl (.aclk(aclk));

  // ---------------------------------------------------------------------
  //  name       TDATA   TID  TDEST  TUSER    notes
  //  --------   -----   ---  -----  -----    -----------------------------
  //  env_w4      4 B     4     4      4      smallest common width
  //  env_w8      8 B     8     4      8
  //  env_w12    12 B     8     8     12      not a power of two, on purpose
  //  env_w16    16 B     8     8     16      widest common width
  //  env_min     4 B     -     -      -      TDATA/TVALID/TREADY/TLAST only
  //
  // TKEEP and TSTRB are DATA_BYTES wide wherever they are present, and
  // TUSER follows the spec's recommendation of one bit per byte.
  // ---------------------------------------------------------------------
  axi_stream_link #(.ENV_NAME("env_w4"),  .DATA_BYTES(4),  .ID_WIDTH(4), .DEST_WIDTH(4),
                    .USER_WIDTH(4),  .FIFO_DEPTH(16)) u_link_w4  (aclk, ctrl.aresetn);

  axi_stream_link #(.ENV_NAME("env_w8"),  .DATA_BYTES(8),  .ID_WIDTH(8), .DEST_WIDTH(4),
                    .USER_WIDTH(8),  .FIFO_DEPTH(16)) u_link_w8  (aclk, ctrl.aresetn);

  axi_stream_link #(.ENV_NAME("env_w12"), .DATA_BYTES(12), .ID_WIDTH(8), .DEST_WIDTH(8),
                    .USER_WIDTH(12), .FIFO_DEPTH(8))  u_link_w12 (aclk, ctrl.aresetn);

  axi_stream_link #(.ENV_NAME("env_w16"), .DATA_BYTES(16), .ID_WIDTH(8), .DEST_WIDTH(8),
                    .USER_WIDTH(16), .FIFO_DEPTH(8))  u_link_w16 (aclk, ctrl.aresetn);

  axi_stream_link #(.ENV_NAME("env_min"), .DATA_BYTES(4),  .ID_WIDTH(0), .DEST_WIDTH(0),
                    .USER_WIDTH(0),  .FIFO_DEPTH(4))  u_link_min (aclk, ctrl.aresetn);

  initial begin
    uvm_config_db#(virtual axi_stream_tb_ctrl_if)::set(null, "*", "ctrl", ctrl);
    run_test("axi_stream_multiwidth_test");
  end

  // ---------------------------------------------------------------------
  // Pass/fail banner, printed once at the end of simulation. XSIM exits 0
  // even after a UVM_FATAL, so the Makefile greps this instead.
  // ---------------------------------------------------------------------
  function automatic void print_summary(
      bit pass, int n_fatals, int n_errors, int n_warnings, string test_name
  );
    string status = pass ? "PASSED" : "FAILED";
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: axi_stream  |  top: axi_stream_tb_top");
    $display(" test    : %s", test_name);
    $display(" result  : %s", status);
    $display(" fatals=%0d errors=%0d warnings=%0d", n_fatals, n_errors, n_warnings);
    $display("============================================================");
  endfunction

  final begin
    uvm_report_server svr;
    int n_fatals, n_errors, n_warnings;
    string test_name;
    svr        = uvm_report_server::get_server();
    n_fatals   = svr.get_severity_count(UVM_FATAL);
    n_errors   = svr.get_severity_count(UVM_ERROR);
    n_warnings = svr.get_severity_count(UVM_WARNING);
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name)) test_name = "axi_stream_multiwidth_test";
    print_summary((n_fatals == 0) && (n_errors == 0), n_fatals, n_errors, n_warnings, test_name);
  end

endmodule : axi_stream_tb_top
