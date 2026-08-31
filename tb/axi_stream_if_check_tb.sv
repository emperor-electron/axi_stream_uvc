///////////////////////////////////////////////////////////////////
// Filename: axi_stream_if_check_tb.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Negative test for the interface's protocol assertions.
//           Drives deliberately illegal AXI4-Stream activity and fails
//           unless every rule catches its own violation.
///////////////////////////////////////////////////////////////////
//
// The UVC's own tests all pass, which says nothing on its own: a checker
// that never fires passes everything. This testbench exists to show the
// checkers are alive, one rule at a time, by breaking each rule on
// purpose and requiring the interface to notice.
//
// Deliberately plain SystemVerilog with no UVM in it. It drives the
// interface's signals directly, which is exactly what a broken master
// or slave would do, and reads protocol_error_count to see what was
// caught. That also demonstrates the interface is usable outside UVM.
//
// Signals move on the falling edge of ACLK throughout, so every change
// is unambiguously before or after the rising edge the assertions
// sample on.

`timescale 1ns/1ps

module axi_stream_if_check_tb;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  always #(5ns) aclk = ~aclk;

  axi_stream_if #(.DATA_BYTES(4), .ID_WIDTH(4), .DEST_WIDTH(4), .USER_WIDTH(4))
      u (.aclk(aclk), .aresetn(aresetn));

  int unsigned checks_run    = 0;
  int unsigned checks_passed = 0;
  int unsigned base;

  task automatic idle();
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    u.tdata  <= '0;
    u.tkeep  <= '1;
    u.tstrb  <= '1;
    u.tlast  <= 1'b0;
    u.tid    <= '0;
    u.tdest  <= '0;
    u.tuser  <= '0;
  endtask

  task automatic reset_link();
    @(negedge aclk);
    aresetn <= 1'b0;
    idle();
    repeat (3) @(negedge aclk);
    aresetn <= 1'b1;
    repeat (2) @(negedge aclk);
  endtask

  // A scenario that breaks a rule must be caught.
  task automatic expect_caught(string what, int unsigned base_count);
    checks_run++;
    if (u.protocol_error_count > base_count) begin
      checks_passed++;
      $display("  [ok]     %-34s caught  (%0d violation(s), last rule %s)",
               what, u.protocol_error_count - base_count, u.last_protocol_error_rule);
    end
    else begin
      $display("  [MISSED] %-34s NOT caught -- this checker is dead", what);
    end
  endtask

  // ...and a scenario that breaks nothing must not be.
  task automatic expect_quiet(string what, int unsigned base_count);
    checks_run++;
    if (u.protocol_error_count == base_count) begin
      checks_passed++;
      $display("  [ok]     %-34s clean", what);
    end
    else begin
      $display("  [FALSE]  %-34s reported %0d violation(s) on legal activity (last rule %s)",
               what, u.protocol_error_count - base_count, u.last_protocol_error_rule);
    end
  endtask

  initial begin
    $display("============================================================");
    $display(" AXI4-Stream interface protocol-checker self-test");
    $display("============================================================");

    // --- Legal activity must stay quiet -------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hA5A5_1234;
    u.tlast  <= 1'b1;
    repeat (3) @(negedge aclk);      // stalled, payload held steady
    u.tready <= 1'b1;
    @(negedge aclk);                 // handshake
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_quiet("legal stalled handshake", base);

    // --- TVALID withdrawn before TREADY answered ----------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'h1111_2222;
    repeat (2) @(negedge aclk);
    u.tvalid <= 1'b0;                // never handshook
    repeat (2) @(negedge aclk);
    expect_caught("TVALID withdrawn before handshake", base);

    // --- Payload changed mid-stall ------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hAAAA_AAAA;
    @(negedge aclk);
    u.tdata  <= 32'hBBBB_BBBB;       // TREADY still low
    @(negedge aclk);
    u.tready <= 1'b1;                // then complete it legally
    @(negedge aclk);
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("TDATA changed while stalled", base);

    // --- TLAST changed mid-stall --------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hCAFE_0001;
    u.tlast  <= 1'b0;
    @(negedge aclk);
    u.tlast  <= 1'b1;
    @(negedge aclk);
    u.tready <= 1'b1;
    @(negedge aclk);
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("TLAST changed while stalled", base);

    // --- Reserved byte encoding: TKEEP low with TSTRB high ------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hDEAD_BEEF;
    u.tkeep  <= 4'b1110;
    u.tstrb  <= 4'b0001;             // lane 0 is the reserved encoding
    u.tready <= 1'b1;
    @(negedge aclk);
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_caught("reserved TKEEP=0/TSTRB=1 encoding", base);

    // --- TVALID held high through reset -------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'h0F0F_0F0F;
    @(negedge aclk);
    aresetn  <= 1'b0;                // TVALID never dropped
    repeat (4) @(negedge aclk);
    u.tvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("TVALID asserted during reset", base);

    // --- TVALID already high on the first edge after reset release ----
    @(negedge aclk);
    aresetn  <= 1'b0;
    idle();
    repeat (3) @(negedge aclk);
    base = u.protocol_error_count;
    u.tvalid <= 1'b1;                // asserted on the release edge itself
    aresetn  <= 1'b1;
    repeat (3) @(negedge aclk);
    u.tvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("TVALID high as reset released", base);

    // --- X on the handshake -------------------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'bx;
    repeat (2) @(negedge aclk);
    u.tvalid <= 1'b0;
    repeat (2) @(negedge aclk);
    expect_caught("TVALID unknown out of reset", base);

    // --- X in a byte TKEEP says is valid ------------------------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hxxxx_0000;       // upper bytes X, TKEEP says they count
    u.tkeep  <= 4'b1111;
    u.tstrb  <= 4'b1111;
    u.tready <= 1'b1;
    @(negedge aclk);
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_caught("X in a byte TKEEP marks valid", base);

    // --- X in a null byte is legal and must stay quiet -----------------
    reset_link();
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'hxxxx_0000;       // same X, but now those lanes are null
    u.tkeep  <= 4'b0011;
    u.tstrb  <= 4'b0011;
    u.tready <= 1'b1;
    @(negedge aclk);
    u.tvalid <= 1'b0;
    u.tready <= 1'b0;
    idle();
    repeat (2) @(negedge aclk);
    expect_quiet("X in a null byte (legal)", base);

    // --- Checks can be switched off for a directed negative test ------
    reset_link();
    u.checks_enable = 1'b0;
    base = u.protocol_error_count;
    @(negedge aclk);
    u.tvalid <= 1'b1;
    u.tdata  <= 32'h3333_3333;
    repeat (2) @(negedge aclk);
    u.tvalid <= 1'b0;                // same violation as scenario 2
    repeat (2) @(negedge aclk);
    expect_quiet("violation with checks_enable=0", base);
    u.checks_enable = 1'b1;

    $display("------------------------------------------------------------");
    $display(" checker self-test: %0d of %0d scenarios behaved correctly",
             checks_passed, checks_run);
    $display("============================================================");
    $display(" UVM-TB SUMMARY  |  module: axi_stream_if  |  top: axi_stream_if_check_tb");
    $display(" test    : axi_stream_if_check_tb");
    $display(" result  : %s", (checks_passed == checks_run) ? "PASSED" : "FAILED");
    $display(" fatals=0 errors=%0d warnings=0", checks_run - checks_passed);
    $display("============================================================");
    $finish;
  end

endmodule : axi_stream_if_check_tb
