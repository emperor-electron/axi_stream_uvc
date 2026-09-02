///////////////////////////////////////////////////////////////////
// Filename: axi_stream_scoreboard.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Checks one link of the self-test: every beat and every
//           packet the UVC drives into the FIFO must come back out of
//           it unchanged and in order.
///////////////////////////////////////////////////////////////////
//
// This is where the UVC gets graded. The DUT is a plain FIFO, so the
// expected output is exactly the input -- which means any difference is
// the UVC mis-driving, mis-sampling, or losing a transfer, and the
// scoreboard can be a strict identity check rather than a model.
//
// Two levels, because they fail differently:
//
//   beats   - strict, field for field, including TUSER and the exact
//             TKEEP/TSTRB pattern. Catches a driver that mangles a lane
//             or a monitor that samples a cycle late.
//   packets - payload and routing only, ignoring how the frame was
//             blocked or paced. Catches a lost or spliced frame, and is
//             the check that would survive putting a width converter in
//             the middle.
//
// Note what it does *not* compare: `delay` and `stall_cycles`. Those
// describe when a beat happened, not what it carried; a FIFO is free to
// re-pace traffic and still be correct.

`uvm_analysis_imp_decl(_source_beat)
`uvm_analysis_imp_decl(_sink_beat)
`uvm_analysis_imp_decl(_source_packet)
`uvm_analysis_imp_decl(_sink_packet)

class axi_stream_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(axi_stream_scoreboard)

  uvm_analysis_imp_source_beat   #(axi_stream_seq_item, axi_stream_scoreboard) source_beat_export;
  uvm_analysis_imp_sink_beat     #(axi_stream_seq_item, axi_stream_scoreboard) sink_beat_export;
  uvm_analysis_imp_source_packet #(axi_stream_packet,   axi_stream_scoreboard) source_packet_export;
  uvm_analysis_imp_sink_packet   #(axi_stream_packet,   axi_stream_scoreboard) sink_packet_export;

  local axi_stream_seq_item m_beats_in [$];
  local axi_stream_packet   m_packets_in  [$];

  int unsigned num_beats_matched   = 0;
  int unsigned num_beats_failed    = 0;
  int unsigned num_pkts_matched    = 0;
  int unsigned num_pkts_failed     = 0;

  // Cleared while a test is deliberately disturbing the link (a mid-run
  // reset, say), where transfers are expected to be lost and comparing
  // them would report the test's own stimulus as a DUT failure.
  bit checking_enabled = 1'b1;

  extern function new(string name = "axi_stream_scoreboard", uvm_component parent = null);

  // True once everything that went in has come back out.
  extern virtual function bit is_drained();

  // Forget all outstanding expectations, for use after a disturbance.
  extern virtual function void flush();

  extern virtual function void write_source_beat(axi_stream_seq_item beat);
  extern virtual function void write_sink_beat(axi_stream_seq_item beat);
  extern virtual function void write_source_packet(axi_stream_packet packet);
  extern virtual function void write_sink_packet(axi_stream_packet packet);
  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

endclass : axi_stream_scoreboard

function axi_stream_scoreboard::new(string name = "axi_stream_scoreboard",
                                    uvm_component parent = null);
  super.new(name, parent);
  source_beat_export = new("source_beat_export", this);
  sink_beat_export = new("sink_beat_export", this);
  source_packet_export  = new("source_packet_export",  this);
  sink_packet_export  = new("sink_packet_export",  this);
endfunction : new

function bit axi_stream_scoreboard::is_drained();
  return (m_beats_in.size() == 0) && (m_packets_in.size() == 0);
endfunction : is_drained

function void axi_stream_scoreboard::flush();
  if (m_beats_in.size() != 0 || m_packets_in.size() != 0)
    `uvm_info("SB", $sformatf("flushing %0d pending beat(s) and %0d pending packet(s)",
                              m_beats_in.size(), m_packets_in.size()), UVM_MEDIUM)
  m_beats_in.delete();
  m_packets_in.delete();
endfunction : flush

function void axi_stream_scoreboard::write_source_beat(axi_stream_seq_item beat);
  if (!checking_enabled) return;
  m_beats_in.push_back(beat);
endfunction : write_source_beat

function void axi_stream_scoreboard::write_sink_beat(axi_stream_seq_item beat);
  axi_stream_seq_item expected;
  if (!checking_enabled) return;
  if (m_beats_in.size() == 0) begin
    `uvm_error("SB_BEAT", $sformatf("beat came out of the DUT that never went in: %s",
                                    beat.convert2string()))
    num_beats_failed++;
    return;
  end
  expected = m_beats_in.pop_front();
  if (!beat.compare(expected)) begin
    `uvm_error("SB_BEAT", $sformatf("beat mismatch\n  expected: %s\n  actual  : %s",
                                    expected.convert2string(), beat.convert2string()))
    num_beats_failed++;
  end
  else begin
    num_beats_matched++;
  end
endfunction : write_sink_beat

function void axi_stream_scoreboard::write_source_packet(axi_stream_packet packet);
  if (!checking_enabled) return;
  m_packets_in.push_back(packet);
endfunction : write_source_packet

function void axi_stream_scoreboard::write_sink_packet(axi_stream_packet packet);
  axi_stream_packet expected;
  if (!checking_enabled) return;
  if (m_packets_in.size() == 0) begin
    `uvm_error("SB_PKT", $sformatf("packet came out of the DUT that never went in: %s",
                                   packet.convert2string()))
    num_pkts_failed++;
    return;
  end
  expected = m_packets_in.pop_front();
  if (!packet.compare(expected)) begin
    `uvm_error("SB_PKT", $sformatf("packet mismatch\n  expected: %s\n  actual  : %s",
                                   expected.convert2string(), packet.convert2string()))
    num_pkts_failed++;
  end
  else begin
    num_pkts_matched++;
  end
endfunction : write_sink_packet

// Anything still queued at the end went into the DUT and never came
// out. With a FIFO and a sink that keeps draining, that is a lost
// transfer -- which is exactly the failure a deadlocked backpressure
// model would produce, so it is worth an error rather than a warning.
function void axi_stream_scoreboard::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if (m_beats_in.size() != 0)
    `uvm_error("SB_LEAK", $sformatf("%0d beat(s) entered the DUT and never came out",
                                    m_beats_in.size()))
  if (m_packets_in.size() != 0)
    `uvm_error("SB_LEAK", $sformatf("%0d packet(s) entered the DUT and never came out",
                                    m_packets_in.size()))
  if ((num_beats_matched == 0) && (num_beats_failed == 0))
    `uvm_error("SB_EMPTY", "no beats were checked at all -- the link never carried traffic")
endfunction : check_phase

function void axi_stream_scoreboard::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("SB", $sformatf("beats %0d ok / %0d bad, packets %0d ok / %0d bad",
                            num_beats_matched, num_beats_failed,
                            num_pkts_matched,  num_pkts_failed), UVM_LOW)
endfunction : report_phase
