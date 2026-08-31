///////////////////////////////////////////////////////////////////
// Filename: axi_stream_packet.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : A whole AXI4-Stream packet -- the run of beats ending in
//           TLAST -- as one comparable object, so a scoreboard can
//           reason about frames rather than reassembling beats itself.
///////////////////////////////////////////////////////////////////
//
// The monitor publishes beats on its `ap` and, separately, a packet on
// `pkt_ap` each time it sees TLAST (or after every beat on a link with
// no TLAST, where each transfer is a packet by definition).
//
// payload() flattens the packet to the byte stream a design actually
// cares about: null bytes are dropped, so a 13-byte frame that crossed
// a 4-byte link as four beats and the same frame on a 16-byte link as
// one beat produce identical payloads. That is what makes width
// conversion checkable with a plain object compare.

class axi_stream_packet extends uvm_object;

  axi_stream_seq_item beats[$];

  `uvm_object_utils(axi_stream_packet)

  extern function new(string name = "axi_stream_packet");

  extern function void add(axi_stream_seq_item beat);
  extern function int unsigned num_beats();

  // Every kept byte, in transfer order, with null lanes removed.
  extern function void payload(ref byte unsigned bytes[$]);
  extern function int unsigned num_payload_bytes();

  // Routing fields, taken from the first beat: AXI4-Stream requires
  // TID/TDEST to be constant for all beats of a packet.
  extern function axi_stream_id_t   tid();
  extern function axi_stream_dest_t tdest();

  // True when every beat carries the same TID/TDEST, which the spec
  // requires of a well-formed packet.
  extern function bit routing_is_constant();

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
  extern virtual function void do_print(uvm_printer printer);
  extern virtual function string convert2string();

endclass : axi_stream_packet

function axi_stream_packet::new(string name = "axi_stream_packet");
  super.new(name);
endfunction : new

function void axi_stream_packet::add(axi_stream_seq_item beat);
  beats.push_back(beat);
endfunction : add

function int unsigned axi_stream_packet::num_beats();
  return beats.size();
endfunction : num_beats

function void axi_stream_packet::payload(ref byte unsigned bytes[$]);
  bytes.delete();
  foreach (beats[b])
    foreach (beats[b].tdata[i])
      if (!beats[b].has_tkeep || beats[b].tkeep[i])
        bytes.push_back(beats[b].tdata[i]);
endfunction : payload

function int unsigned axi_stream_packet::num_payload_bytes();
  num_payload_bytes = 0;
  foreach (beats[b])
    num_payload_bytes += beats[b].num_data_bytes();
endfunction : num_payload_bytes

function axi_stream_id_t axi_stream_packet::tid();
  return (beats.size() == 0) ? '0 : beats[0].tid;
endfunction : tid

function axi_stream_dest_t axi_stream_packet::tdest();
  return (beats.size() == 0) ? '0 : beats[0].tdest;
endfunction : tdest

function bit axi_stream_packet::routing_is_constant();
  foreach (beats[b])
    if ((beats[b].tid !== tid()) || (beats[b].tdest !== tdest()))
      return 1'b0;
  return 1'b1;
endfunction : routing_is_constant

function void axi_stream_packet::do_copy(uvm_object rhs);
  axi_stream_packet rhs_;
  if (rhs == null)
    `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COPY", "cast of rhs to axi_stream_packet failed")
  super.do_copy(rhs);
  beats.delete();
  foreach (rhs_.beats[i]) begin
    axi_stream_seq_item beat;
    if (!$cast(beat, rhs_.beats[i].clone()))
      `uvm_fatal("DO_COPY", "clone of a beat did not yield an axi_stream_seq_item")
    beats.push_back(beat);
  end
endfunction : do_copy

// Compares the flattened payload and the routing fields, deliberately
// *not* the beat structure: the same packet re-blocked onto a different
// link width, or re-paced by a FIFO, is still the same packet.
function bit axi_stream_packet::do_compare(uvm_object rhs, uvm_comparer comparer);
  axi_stream_packet rhs_;
  byte unsigned mine[$];
  byte unsigned theirs[$];

  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COMPARE", "cast of rhs to axi_stream_packet failed")
  if (!super.do_compare(rhs, comparer))
    return 1'b0;

  payload(mine);
  rhs_.payload(theirs);

  if (mine.size() != theirs.size()) begin
    comparer.print_msg($sformatf("payload length differs: %0d vs %0d bytes",
                                 mine.size(), theirs.size()));
    return 1'b0;
  end
  foreach (mine[i]) begin
    if (mine[i] !== theirs[i]) begin
      comparer.print_msg($sformatf("payload byte %0d differs: %02h vs %02h",
                                   i, mine[i], theirs[i]));
      return 1'b0;
    end
  end
  if (tid() !== rhs_.tid()) begin
    comparer.print_msg($sformatf("tid differs: %0h vs %0h", tid(), rhs_.tid()));
    return 1'b0;
  end
  if (tdest() !== rhs_.tdest()) begin
    comparer.print_msg($sformatf("tdest differs: %0h vs %0h", tdest(), rhs_.tdest()));
    return 1'b0;
  end
  return 1'b1;
endfunction : do_compare

function void axi_stream_packet::do_print(uvm_printer printer);
  super.do_print(printer);
  printer.print_field_int("beats", beats.size(), 32, UVM_DEC);
  printer.print_field_int("bytes", num_payload_bytes(), 32, UVM_DEC);
  foreach (beats[i])
    printer.print_string($sformatf("beat[%0d]", i), beats[i].convert2string());
endfunction : do_print

function string axi_stream_packet::convert2string();
  byte unsigned bytes[$];
  string s;
  payload(bytes);
  s = $sformatf("packet: %0d beats, %0d bytes, tid=0x%0h tdest=0x%0h, data=",
                beats.size(), bytes.size(), tid(), tdest());
  foreach (bytes[i]) begin
    // Long frames are summarised: the head is what a mismatch report
    // needs, the whole thing just buries it.
    if (i >= 32) begin
      s = {s, $sformatf("... (+%0d more)", bytes.size() - 32)};
      break;
    end
    s = {s, $sformatf("%02h", bytes[i])};
  end
  return s;
endfunction : convert2string
