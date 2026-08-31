///////////////////////////////////////////////////////////////////
// Filename: axi_stream_if.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Parameterizable AMBA AXI4-Stream interface (ARM IHI 0051A).
//           One file serving two masters: a synthesizable interface to
//           wire up inside a design, and -- under a simulation-only
//           guard -- the clocking blocks, protocol assertions and
//           configuration API that make it the UVC's virtual interface.
///////////////////////////////////////////////////////////////////
//
// Synthesizable and verification content in one file
// --------------------------------------------------
// Everything a synthesis tool would reject -- clocking blocks,
// assertions, coverpoints, the string/`%m` reporting helpers -- lives
// inside `ifdef AXI_STREAM_IF_SIM`. What is left outside it is just the
// signal set and the DUT-facing modports, so the same file can be
// instantiated in RTL and elaborated by Vivado synthesis:
//
//   axi_stream_if #(.DATA_BYTES(8)) axis (.aclk(clk), .aresetn(rstn));
//   my_producer u_src (.m_axis(axis.dut_master));
//   my_consumer u_snk (.s_axis(axis.dut_slave));
//
// AXI_STREAM_IF_SIM is set automatically from XILINX_SIMULATOR, which
// xvlog/xelab predefine and Vivado synthesis does not, so nothing has to
// be passed on the command line for either flow. On a simulator that
// does not define it, ask for it explicitly:
//
//   vlog +define+AXI_STREAM_IF_SIM ...
//
// The UVC needs the simulation half (its drivers and monitor talk to the
// clocking blocks), so a UVC compile without that macro will not build --
// loudly, at the first reference to `mst_cb`, rather than subtly.
//
// Parameterization
// ----------------
// Every width is a SystemVerilog *parameter*, never a compile-time
// `define, so a single compilation can hold as many differently sized
// AXI-Stream interfaces as it likes:
//
//   axi_stream_if #(.DATA_BYTES(4),  .ID_WIDTH(4), .DEST_WIDTH(4), .USER_WIDTH(4))  a (aclk, aresetn);
//   axi_stream_if #(.DATA_BYTES(16), .ID_WIDTH(8), .DEST_WIDTH(8), .USER_WIDTH(16)) b (aclk, aresetn);
//
// A width of 0 for ID/DEST/USER means "this optional signal does not
// exist on my DUT". The signal is still declared (clamped to 1 bit) so
// that the virtual-interface type stays well formed, but the UVC drives
// it to 0 and neither the UVC nor the assertions below check it.
//
// TKEEP/TSTRB/TLAST are always DATA_BYTES/DATA_BYTES/1 bit wide when
// present; because their presence does not change any signal's *size*,
// it is a run-time property (`has_tkeep` and friends, normally written
// by the agent from its config object) rather than a parameter. That
// keeps the number of distinct virtual-interface types to a minimum.
//
// Signal presence and `checks_enable` are plain variables, so a
// testbench with no UVM in it can set them directly:
//
//   initial dut_in.configure(.en_tkeep(1), .en_tstrb(0), .en_tlast(1),
//                            .en_tid(0), .en_tdest(0), .en_tuser(1));
//

// Derive the simulation gate from the simulator's own macro, unless the
// user has already asked for it. `ifndef first, so an explicit
// +define+AXI_STREAM_IF_SIM on any other simulator wins.
`ifndef AXI_STREAM_IF_SIM
  `ifdef XILINX_SIMULATOR
    `define AXI_STREAM_IF_SIM
  `endif
`endif

interface axi_stream_if #(
  // TDATA width, in bytes. TDATA is 8*DATA_BYTES bits wide; TKEEP and
  // TSTRB are DATA_BYTES bits wide. AXI4-Stream permits any integer
  // number of bytes -- 12 (a non-power-of-two) is as legal as 16.
  parameter int DATA_BYTES = 4,
  // TID width in bits, 0 => no TID.   AXI4-Stream recommends <= 8 bits.
  parameter int ID_WIDTH   = 0,
  // TDEST width in bits, 0 => no TDEST. AXI4-Stream recommends <= 4 bits.
  parameter int DEST_WIDTH = 0,
  // TUSER width in bits, 0 => no TUSER. AXI4-Stream recommends an
  // integer multiple of DATA_BYTES, but does not require it.
  parameter int USER_WIDTH = 0
) (
  input logic aclk,
  input logic aresetn
);

  // Widths clamped to >= 1 so that `logic [-1:0]` can never be declared.
  // Use the has_* bits, not these, to decide whether a signal is real.
  localparam int TDATA_W = 8 * DATA_BYTES;
  localparam int TKEEP_W = DATA_BYTES;
  localparam int TSTRB_W = DATA_BYTES;
  localparam int TID_W   = (ID_WIDTH   > 0) ? ID_WIDTH   : 1;
  localparam int TDEST_W = (DEST_WIDTH > 0) ? DEST_WIDTH : 1;
  localparam int TUSER_W = (USER_WIDTH > 0) ? USER_WIDTH : 1;

  // ---------------------------------------------------------------------
  // AXI4-Stream signals. Driven by the master side (everything except
  // TREADY) and the slave side (TREADY only); each signal therefore has
  // exactly one driver in any legal connection.
  // ---------------------------------------------------------------------
  logic               tvalid;
  logic               tready;
  logic [TDATA_W-1:0] tdata;
  logic [TKEEP_W-1:0] tkeep;
  logic [TSTRB_W-1:0] tstrb;
  logic               tlast;
  logic [TID_W-1:0]   tid;
  logic [TDEST_W-1:0] tdest;
  logic [TUSER_W-1:0] tuser;

  // ---------------------------------------------------------------------
  // DUT-facing modports. A DUT written against these gets the signal
  // directions checked at elaboration; a DUT with plain ports can just
  // be wired to the signals by name instead. Both are synthesizable.
  // ---------------------------------------------------------------------
  modport dut_slave (
    input  aclk, aresetn, tvalid, tdata, tkeep, tstrb, tlast, tid, tdest, tuser,
    output tready
  );

  modport dut_master (
    input  aclk, aresetn, tready,
    output tvalid, tdata, tkeep, tstrb, tlast, tid, tdest, tuser
  );

  // =====================================================================
  // Everything below here is simulation-only: clocking blocks, the
  // verification configuration API, and the protocol assertions. None of
  // it is synthesizable, and none of it is compiled unless
  // AXI_STREAM_IF_SIM is set (see the header).
  //
  // New coverpoints or formal properties belong inside this guard too.
  // =====================================================================
`ifdef AXI_STREAM_IF_SIM

  // ---------------------------------------------------------------------
  // Run-time description of which optional signals this link actually
  // uses, and whether the assertions below are live. Defaults describe
  // the widest sensible link; the agent overwrites them from its config.
  // ---------------------------------------------------------------------
  bit has_tkeep     = 1'b1;
  bit has_tstrb     = 1'b1;
  bit has_tlast     = 1'b1;
  bit has_tid       = (ID_WIDTH   > 0);
  bit has_tdest     = (DEST_WIDTH > 0);
  bit has_tuser     = (USER_WIDTH > 0);
  bit checks_enable = 1'b1;

  // Every assertion failure below bumps this counter as well as printing.
  // The agent's check_phase turns a non-zero count into a UVM_ERROR, so
  // protocol violations fail the test even though the assertions
  // themselves know nothing about UVM.
  int unsigned protocol_error_count = 0;

  // Rule name of the most recent failure, so a checker testbench can
  // report which rule fired without having to scrape the log.
  string last_protocol_error_rule = "";

  // Formals are prefixed so they cannot shadow the signals of the same
  // name declared above -- `has_tkeep = tkeep` would otherwise be one
  // typo away from assigning the wire to its own presence flag.
  function automatic void configure(bit en_tkeep, bit en_tstrb, bit en_tlast,
                                    bit en_tid, bit en_tdest, bit en_tuser,
                                    bit en_checks = 1'b1);
    has_tkeep     = en_tkeep;
    has_tstrb     = en_tstrb;
    has_tlast     = en_tlast;
    has_tid       = en_tid;
    has_tdest     = en_tdest;
    has_tuser     = en_tuser;
    checks_enable = en_checks;
  endfunction

  // Hierarchical path of this interface instance, so a UVM component
  // holding only a virtual handle can still name it in a report.
  function automatic string path();
    return $sformatf("%m");
  endfunction

  function automatic void protocol_error(string rule, string msg);
    protocol_error_count++;
    last_protocol_error_rule = rule;
    $error("%m: AXI4-Stream protocol violation [%s]: %s", rule, msg);
  endfunction

  // ---------------------------------------------------------------------
  // Clocking blocks.
  //
  // `input #1step` samples each signal in the Preponed region, i.e. the
  // value that settled *before* the clock edge -- exactly what a real
  // flop sees. `output #0` drives in the Re-NBA region *after* the edge,
  // so a DUT's always_ff sampling the same edge still sees the old value.
  // Together they make driving and sampling race-free without depending
  // on the timescale, which matters here because a UVC gets reused at
  // whatever clock period the host testbench happens to run.
  // ---------------------------------------------------------------------
  clocking mst_cb @(posedge aclk);
    default input #1step output #0;
    output tvalid, tdata, tkeep, tstrb, tlast, tid, tdest, tuser;
    input  tready;
    input  aresetn;
  endclocking : mst_cb

  clocking slv_cb @(posedge aclk);
    default input #1step output #0;
    output tready;
    input  tvalid, tdata, tkeep, tstrb, tlast, tid, tdest, tuser;
    input  aresetn;
  endclocking : slv_cb

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input tvalid, tready, tdata, tkeep, tstrb, tlast, tid, tdest, tuser;
    input aresetn;
  endclocking : mon_cb

  // UVC-facing modports, for testbenches that prefer to pass modports
  // around. The UVC itself takes the whole interface, since it needs
  // both a clocking block and the configure()/protocol_error_count API.
  modport mst_mp (clocking mst_cb, input aclk, aresetn);
  modport slv_mp (clocking slv_cb, input aclk, aresetn);
  modport mon_mp (clocking mon_cb, input aclk, aresetn);

  // =====================================================================
  // Protocol checks -- AMBA AXI4-Stream Protocol Specification (IHI
  // 0051A), section 2.2 (handshake) and 2.7 (reset). These police the
  // UVC and the DUT equally: whichever side drives the signal that
  // breaks a rule is the side the failure points at.
  //
  // Every property uses `aresetn !== 1'b1` rather than `!aresetn` in its
  // disable condition so that an X on reset disables the check instead
  // of evaluating to X and (in some tools) letting it run anyway.
  // =====================================================================

  // ---- 2.2.1: once TVALID is asserted it must stay asserted until the
  // handshake occurs. A master may not withdraw an offered transfer.
  property p_tvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (tvalid === 1'b1 && tready !== 1'b1) |=> (tvalid === 1'b1);
  endproperty
  a_tvalid_held : assert property (p_tvalid_held)
    else protocol_error("TVALID_HELD",
        "TVALID was deasserted before TREADY completed the handshake");

  // ---- 2.2.1: the payload must not change while a transfer is stalled.
  //
  // Written out one signal at a time rather than as a single property
  // taking the signal as an argument: property formal arguments are
  // legal SystemVerilog but XSIM silently *ignores* properties that use
  // them, which would leave these checks looking present and doing
  // nothing. One property per signal also means a failure names the
  // offending signal without having to decode an argument.
  property p_tdata_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tdata);
  endproperty
  a_tdata_stable : assert property (p_tdata_stable)
    else protocol_error("TDATA_STABLE", "TDATA changed while TVALID was asserted and TREADY low");

  property p_tkeep_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tkeep)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tkeep);
  endproperty
  a_tkeep_stable : assert property (p_tkeep_stable)
    else protocol_error("TKEEP_STABLE", "TKEEP changed while TVALID was asserted and TREADY low");

  property p_tstrb_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tstrb)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tstrb);
  endproperty
  a_tstrb_stable : assert property (p_tstrb_stable)
    else protocol_error("TSTRB_STABLE", "TSTRB changed while TVALID was asserted and TREADY low");

  property p_tlast_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tlast)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tlast);
  endproperty
  a_tlast_stable : assert property (p_tlast_stable)
    else protocol_error("TLAST_STABLE", "TLAST changed while TVALID was asserted and TREADY low");

  property p_tid_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tid)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tid);
  endproperty
  a_tid_stable : assert property (p_tid_stable)
    else protocol_error("TID_STABLE", "TID changed while TVALID was asserted and TREADY low");

  property p_tdest_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tdest)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tdest);
  endproperty
  a_tdest_stable : assert property (p_tdest_stable)
    else protocol_error("TDEST_STABLE", "TDEST changed while TVALID was asserted and TREADY low");

  property p_tuser_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tuser)
      (tvalid === 1'b1 && tready !== 1'b1) |=> $stable(tuser);
  endproperty
  a_tuser_stable : assert property (p_tuser_stable)
    else protocol_error("TUSER_STABLE", "TUSER changed while TVALID was asserted and TREADY low");

  // ---- 2.7.2: TVALID must be LOW while ARESETn is asserted.
  //
  // Qualified on reset having *already* been low at the previous edge,
  // which gives a synchronous master exactly one ACLK edge to react to
  // an asynchronously asserted reset -- the same one cycle a real
  // sync-reset flop takes. A master that keeps offering a transfer
  // through reset still fails, which is the behaviour worth catching.
  //
  // Written as "not HIGH" rather than "=== 0" so the X on TVALID before
  // any driver has run does not trip it; a real 1 during reset does.
  property p_tvalid_low_in_reset;
    @(posedge aclk) disable iff (!checks_enable)
      ($past(aresetn) === 1'b0) |-> (tvalid !== 1'b1);
  endproperty
  a_tvalid_low_in_reset : assert property (p_tvalid_low_in_reset)
    else protocol_error("RESET_TVALID", "TVALID was still asserted a full cycle into ARESETn");

  // ---- 2.7.2: a master may only begin driving TVALID at a rising ACLK
  // edge *following* the edge at which ARESETn went high, so TVALID must
  // still be low on that first post-reset edge. By now a driver has run,
  // so this one demands a hard 0.
  property p_tvalid_low_after_reset;
    @(posedge aclk) disable iff (!checks_enable)
      $rose(aresetn) |-> (tvalid === 1'b0);
  endproperty
  a_tvalid_low_after_reset : assert property (p_tvalid_low_after_reset)
    else protocol_error("RESET_TVALID_EXIT",
        "TVALID was already high on the first ACLK edge after ARESETn deasserted");

  // ---- 2.4.3: TKEEP LOW with TSTRB HIGH is a reserved encoding.
  //   TKEEP=1,TSTRB=1 -> data byte     TKEEP=1,TSTRB=0 -> position byte
  //   TKEEP=0,TSTRB=0 -> null byte     TKEEP=0,TSTRB=1 -> RESERVED
  property p_keep_strb_legal;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tkeep || !has_tstrb)
      (tvalid === 1'b1) |-> ((~tkeep & tstrb) == '0);
  endproperty
  a_keep_strb_legal : assert property (p_keep_strb_legal)
    else protocol_error("KEEP_STRB_RESERVED",
        "TKEEP low with TSTRB high is a reserved byte encoding");

  // ---- Handshake signals must never be X/Z once out of reset: an X on
  // TVALID or TREADY makes the whole handshake meaningless.
  property p_tvalid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(tvalid);
  endproperty
  a_tvalid_known : assert property (p_tvalid_known)
    else protocol_error("TVALID_X", "TVALID is X/Z out of reset");

  property p_tready_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable) !$isunknown(tready);
  endproperty
  a_tready_known : assert property (p_tready_known)
    else protocol_error("TREADY_X", "TREADY is X/Z out of reset");

  // Control payload must be known whenever a transfer is offered.
  // Again one property per signal, for the reason given above.
  property p_tkeep_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tkeep)
      (tvalid === 1'b1) |-> !$isunknown(tkeep);
  endproperty
  a_tkeep_known : assert property (p_tkeep_known)
    else protocol_error("TKEEP_X", "TKEEP is X/Z while TVALID is asserted");

  property p_tstrb_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tstrb)
      (tvalid === 1'b1) |-> !$isunknown(tstrb);
  endproperty
  a_tstrb_known : assert property (p_tstrb_known)
    else protocol_error("TSTRB_X", "TSTRB is X/Z while TVALID is asserted");

  property p_tlast_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tlast)
      (tvalid === 1'b1) |-> !$isunknown(tlast);
  endproperty
  a_tlast_known : assert property (p_tlast_known)
    else protocol_error("TLAST_X", "TLAST is X/Z while TVALID is asserted");

  property p_tid_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tid)
      (tvalid === 1'b1) |-> !$isunknown(tid);
  endproperty
  a_tid_known : assert property (p_tid_known)
    else protocol_error("TID_X", "TID is X/Z while TVALID is asserted");

  property p_tdest_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tdest)
      (tvalid === 1'b1) |-> !$isunknown(tdest);
  endproperty
  a_tdest_known : assert property (p_tdest_known)
    else protocol_error("TDEST_X", "TDEST is X/Z while TVALID is asserted");

  property p_tuser_known;
    @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable || !has_tuser)
      (tvalid === 1'b1) |-> !$isunknown(tuser);
  endproperty
  a_tuser_known : assert property (p_tuser_known)
    else protocol_error("TUSER_X", "TUSER is X/Z while TVALID is asserted");

  // Only bytes that TKEEP marks as data/position bytes have to carry
  // defined data -- a null byte's TDATA is explicitly "undefined" in the
  // spec, so checking it would be wrong.
  for (genvar b = 0; b < DATA_BYTES; b++) begin : g_byte_known
    a_tdata_known : assert property (
      @(posedge aclk) disable iff (aresetn !== 1'b1 || !checks_enable)
        (tvalid === 1'b1 && (!has_tkeep || tkeep[b] === 1'b1)) |-> !$isunknown(tdata[b*8 +: 8])
    ) else protocol_error("TDATA_X",
        $sformatf("TDATA byte %0d is X/Z but TKEEP marks it as a valid byte", b));
  end : g_byte_known

`endif  // AXI_STREAM_IF_SIM

endinterface : axi_stream_if
