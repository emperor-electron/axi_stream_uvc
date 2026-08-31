///////////////////////////////////////////////////////////////////
// Filename: example_scoreboard.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Example of consuming the UVC's analysis ports: every packet
//           that goes into the DUT must come back out of it unchanged
//           and in order.
///////////////////////////////////////////////////////////////////
//
// The DUT is a register slice, so the expected output is simply the
// input and this can be an identity check. Replace the comparison with
// your own model and the plumbing stays the same.
//
// Each monitor offers two analysis ports, and which you subscribe to is
// a real design choice:
//
//   mon.ap      one axi_stream_seq_item per handshake. Every field
//               exactly as it appeared on the wire, including TUSER and
//               the precise TKEEP/TSTRB pattern. Use it for cycle-level
//               checks and coverage.
//   mon.pkt_ap  one axi_stream_packet per TLAST. Comparing these
//               compares the flattened payload and routing, ignoring how
//               the frame was blocked into beats or paced -- so it keeps
//               working if you later put a width converter or a FIFO in
//               the path. That is what this scoreboard uses.
//
// Note that both streams come from monitors, never from drivers, so the
// check is against what the wires actually did rather than what the
// testbench meant to do.

`uvm_analysis_imp_decl(_in_pkt)
`uvm_analysis_imp_decl(_out_pkt)

class example_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(example_scoreboard)

  uvm_analysis_imp_in_pkt  #(axi_stream_packet, example_scoreboard) in_pkt_export;
  uvm_analysis_imp_out_pkt #(axi_stream_packet, example_scoreboard) out_pkt_export;

  // Only ever used for its clock, so wait_until_drained() can count
  // cycles. Assigned by the env.
  example_vif_t vif;

  local axi_stream_packet m_expected[$];

  int unsigned num_matched = 0;
  int unsigned num_failed  = 0;

  extern function new(string name = "example_scoreboard", uvm_component parent = null);
  extern virtual function void write_in_pkt(axi_stream_packet t);
  extern virtual function void write_out_pkt(axi_stream_packet t);
  extern virtual function bit is_drained();
  extern virtual task wait_until_drained(int unsigned timeout_cycles = 5000);
  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

endclass : example_scoreboard

function example_scoreboard::new(string name = "example_scoreboard", uvm_component parent = null);
  super.new(name, parent);
  in_pkt_export  = new("in_pkt_export",  this);
  out_pkt_export = new("out_pkt_export", this);
endfunction : new

function void example_scoreboard::write_in_pkt(axi_stream_packet t);
  m_expected.push_back(t);
endfunction : write_in_pkt

function void example_scoreboard::write_out_pkt(axi_stream_packet t);
  axi_stream_packet expected;
  if (m_expected.size() == 0) begin
    `uvm_error("SB", $sformatf("packet came out that never went in: %s", t.convert2string()))
    num_failed++;
    return;
  end
  expected = m_expected.pop_front();
  // compare() uses axi_stream_packet::do_compare, which checks the
  // flattened payload plus TID/TDEST.
  if (!t.compare(expected)) begin
    `uvm_error("SB", $sformatf("packet mismatch\n  expected: %s\n  actual  : %s",
                               expected.convert2string(), t.convert2string()))
    num_failed++;
  end
  else begin
    num_matched++;
  end
endfunction : write_out_pkt

function bit example_scoreboard::is_drained();
  return (m_expected.size() == 0);
endfunction : is_drained

// Called by the test before it drops its objection. Without this, the
// last packets would still be inside the DUT when the test ends and
// check_phase would report them as lost.
task example_scoreboard::wait_until_drained(int unsigned timeout_cycles = 5000);
  int unsigned elapsed = 0;
  while (!is_drained() && (elapsed < timeout_cycles)) begin
    @(posedge vif.aclk);
    elapsed++;
  end
  if (!is_drained())
    `uvm_warning("SB", $sformatf("%0d packet(s) still in the DUT after %0d cycles",
                                 m_expected.size(), elapsed))
  repeat (4) @(posedge vif.aclk);
endtask : wait_until_drained

function void example_scoreboard::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if (m_expected.size() != 0)
    `uvm_error("SB", $sformatf("%0d packet(s) entered the DUT and never came out",
                               m_expected.size()))
  if ((num_matched == 0) && (num_failed == 0))
    `uvm_error("SB", "no packets were checked at all -- the link never carried traffic")
endfunction : check_phase

function void example_scoreboard::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SB", $sformatf("packets %0d ok / %0d bad", num_matched, num_failed), UVM_LOW)
endfunction : report_phase
