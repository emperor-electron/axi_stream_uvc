///////////////////////////////////////////////////////////////////
// Filename: example_tb_top.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Worked example of hooking the AXI4-Stream UVC up to a DUT.
//           Read this file and example_base_test.sv together and you
//           have everything needed to drop the UVC into your own
//           testbench.
///////////////////////////////////////////////////////////////////
//
// ============================================================
//  WHAT THIS FILE HAS TO DO
// ============================================================
// A UVM component cannot reach into the design hierarchy on its own, so
// the top module has exactly three jobs:
//
//   1. instantiate one axi_stream_if per AXI4-Stream port of the DUT
//   2. wire those interfaces to the DUT
//   3. publish them to the config DB so the agents can find them
//
// Everything else -- roles, backpressure, stimulus -- is in the test.
//
// The DUT here has one slave port and one master port, so there are two
// interfaces and two agents. A DUT with only a slave port needs just the
// first of each, and the slave agent and its interface simply go away.
//
// ============================================================
//  THE ONE THING THAT CATCHES PEOPLE OUT
// ============================================================
// `virtual axi_stream_if #(8,4,4,8)` and `virtual axi_stream_if #(4,0,0,0)`
// are *different SystemVerilog types*. The type you set into the config
// DB must match the type the agent gets out of it, parameter for
// parameter, or the get() silently fails and the agent issues a NOVIF
// fatal.
//
// The fix is not to be careful -- it is to write the widths down once.
// example_tb_pkg.sv declares them as parameters and gives the two
// parameterized types names (example_vif_t, example_agent_t), and every
// other file uses those names. Do the same in your testbench and the
// mismatch cannot happen.

`timescale 1ns/1ps

module example_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // The UVC package. This plus axi_stream_if.sv is the entire component;
  // see src/axi_stream_uvc.f for the filelist that pulls both in.
  import axi_stream_pkg::*;

  // Your own testbench package: link widths, env, scoreboard, tests.
  import example_tb_pkg::*;

  // ---------------------------------------------------------------------
  // STEP 1 -- clock and reset.
  //
  // Ordinary testbench plumbing; the UVC does not care how they are
  // generated. Reset is released on a falling edge on purpose: keeping
  // it away from the rising edge makes the reset-release rule the UVC
  // asserts ("TVALID must be low on the first ACLK edge after ARESETn
  // goes high") unambiguous.
  // ---------------------------------------------------------------------
  logic aclk;
  logic aresetn;

  initial aclk = 1'b0;
  always #(5ns) aclk = ~aclk;          // 100 MHz

  initial begin
    aresetn = 1'b0;
    repeat (5) @(negedge aclk);
    aresetn = 1'b1;
  end

  // ---------------------------------------------------------------------
  // STEP 2 -- one interface per AXI4-Stream port of the DUT.
  //
  // The widths come from example_tb_pkg so they are stated once. Name
  // them after what they are relative to the DUT: `axis_in` is the DUT's
  // slave port (transfers flow in), `axis_out` is its master port.
  // ---------------------------------------------------------------------
  axi_stream_if #(EX_DATA_BYTES, EX_ID_WIDTH, EX_DEST_WIDTH, EX_USER_WIDTH)
      axis_in (.aclk(aclk), .aresetn(aresetn));

  axi_stream_if #(EX_DATA_BYTES, EX_ID_WIDTH, EX_DEST_WIDTH, EX_USER_WIDTH)
      axis_out (.aclk(aclk), .aresetn(aresetn));

  // ---------------------------------------------------------------------
  // STEP 3 -- wire the DUT to the interfaces.
  //
  // Signal by signal, which works with any DUT whatever its port names.
  // If your DUT is written against the interface instead, the
  // synthesizable modports do the same job in one line each:
  //
  //     example_dut u_dut (.aclk, .aresetn,
  //                        .s_axis(axis_in.dut_slave),
  //                        .m_axis(axis_out.dut_master));
  //
  // Either way, note who drives what: on axis_in the UVC drives TVALID
  // and the payload and the DUT drives TREADY; on axis_out it is the
  // other way round. Every signal ends up with exactly one driver, which
  // is why both ends can share one interface type.
  // ---------------------------------------------------------------------
  example_dut #(
    .DATA_BYTES (EX_DATA_BYTES),
    .ID_WIDTH   (EX_ID_WIDTH),
    .DEST_WIDTH (EX_DEST_WIDTH),
    .USER_WIDTH (EX_USER_WIDTH)
  ) u_dut (
    .aclk          (aclk),
    .aresetn       (aresetn),

    // DUT slave port  <- driven by the UVC's master agent
    .s_axis_tvalid (axis_in.tvalid),
    .s_axis_tready (axis_in.tready),
    .s_axis_tdata  (axis_in.tdata),
    .s_axis_tkeep  (axis_in.tkeep),
    .s_axis_tstrb  (axis_in.tstrb),
    .s_axis_tlast  (axis_in.tlast),
    .s_axis_tid    (axis_in.tid),
    .s_axis_tdest  (axis_in.tdest),
    .s_axis_tuser  (axis_in.tuser),

    // DUT master port -> backpressured by the UVC's slave agent
    .m_axis_tvalid (axis_out.tvalid),
    .m_axis_tready (axis_out.tready),
    .m_axis_tdata  (axis_out.tdata),
    .m_axis_tkeep  (axis_out.tkeep),
    .m_axis_tstrb  (axis_out.tstrb),
    .m_axis_tlast  (axis_out.tlast),
    .m_axis_tid    (axis_out.tid),
    .m_axis_tdest  (axis_out.tdest),
    .m_axis_tuser  (axis_out.tuser)
  );

  // ---------------------------------------------------------------------
  // STEP 4 -- hand the interfaces to the testbench.
  //
  // example_vif_t is the typedef from example_tb_pkg; using it here and
  // in the env guarantees the set and the get agree. The scope "*" makes
  // them visible everywhere, and the field names ("vif_in"/"vif_out")
  // are what the env asks for -- see example_env.sv, STEP 1.
  //
  // With more than one link, give each its own field name, or narrow the
  // scope to the env instance that should receive it.
  // ---------------------------------------------------------------------
  initial begin
    uvm_config_db#(example_vif_t)::set(null, "*", "vif_in",  axis_in);
    uvm_config_db#(example_vif_t)::set(null, "*", "vif_out", axis_out);

    // STEP 5 -- start UVM. Override on the command line with
    // +UVM_TESTNAME=<test>; the Makefile's TEST= does exactly that.
    run_test("example_base_test");
  end

  // ---------------------------------------------------------------------
  // Pass/fail banner. Not part of UVC integration, but worth copying:
  // XSIM exits 0 even after a UVM_FATAL (the test called $finish, it did
  // not crash), so a script that only checks the exit status will call a
  // failing test a pass. The Makefile greps for this line instead.
  // ---------------------------------------------------------------------
  final begin
    uvm_report_server svr;
    int n_fatals, n_errors, n_warnings;
    string test_name;
    svr        = uvm_report_server::get_server();
    n_fatals   = svr.get_severity_count(UVM_FATAL);
    n_errors   = svr.get_severity_count(UVM_ERROR);
    n_warnings = svr.get_severity_count(UVM_WARNING);
    if (!$value$plusargs("UVM_TESTNAME=%s", test_name)) test_name = "example_base_test";
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: example_dut  |  top: example_tb_top");
    $display(" test    : %s", test_name);
    $display(" result  : %s", ((n_fatals == 0) && (n_errors == 0)) ? "PASSED" : "FAILED");
    $display(" fatals=%0d errors=%0d warnings=%0d", n_fatals, n_errors, n_warnings);
    $display("============================================================");
  end

endmodule : example_tb_top
