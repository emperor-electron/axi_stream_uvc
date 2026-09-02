///////////////////////////////////////////////////////////////////
// Filename: axi_stream_seq_item.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM sequence item representing a single AXI4-Stream
//           transfer (one beat), sized at run time from the agent's
//           config so that one transaction type -- and therefore one
//           sequence library and one scoreboard -- serves every link
//           width in the testbench.
///////////////////////////////////////////////////////////////////
//
// TDATA/TKEEP/TSTRB are dynamic arrays sized to the link's byte count,
// rather than vectors of some fixed maximum width. That is what keeps
// this class unparameterized: a 12-byte beat and a 16-byte beat are the
// same type, so a sequence written against one runs unchanged against
// the other and a scoreboard can compare items from links of different
// widths without any casting.
//
// TID/TDEST/TUSER are vectors of the UVC's maximum supported width and
// are constrained to zero above the link's real width, which keeps the
// ergonomic `item.tid == 3` style of constraint working.

class axi_stream_seq_item extends uvm_sequence_item;

  // ---- Link geometry. Not rand: these describe the link the beat is
  // for, and are normally filled in from `agent_config` by pre_randomize().
  int unsigned data_bytes = 4;
  int unsigned id_width   = 0;
  int unsigned dest_width = 0;
  int unsigned user_width = 0;
  bit          has_tkeep  = 1'b1;
  bit          has_tstrb  = 1'b1;
  bit          has_tlast  = 1'b1;
  bit          has_tid    = 1'b0;
  bit          has_tdest  = 1'b0;
  bit          has_tuser  = 1'b0;

  // Bounds for `delay`, likewise copied from the config.
  int unsigned min_delay = 0;
  int unsigned max_delay = 0;

  // When set (the default), every lane of the beat is a data byte.
  // Clear it to let the solver choose the TKEEP/TSTRB pattern freely --
  // still only ever a legal one, since c_byte_encoding is hard.
  bit dense = 1'b1;

  // Optional handle to the agent's config. When set (the sequence base
  // class does this for you), pre_randomize() adopts its geometry, so a
  // sequence never has to restate the link's widths.
  axi_stream_config agent_config;

  // ---- Wire content -------------------------------------------------
  rand byte unsigned      tdata[];   // tdata[0] is TDATA[7:0]
  rand bit                tkeep[];   // one bit per byte
  rand bit                tstrb[];   // one bit per byte
  rand bit                tlast;
  rand axi_stream_id_t    tid;
  rand axi_stream_dest_t  tdest;
  rand axi_stream_user_t  tuser;

  // ---- Stimulus-only: idle ACLK cycles the master driver inserts
  // before offering this beat. Not part of the observed transaction,
  // so do_compare() ignores it and the monitor leaves it at 0.
  rand int unsigned delay;

  // ---- Filled in by the monitor, ignored by the driver -------------
  // Cycles this beat spent stalled with TVALID high waiting for TREADY.
  int unsigned stall_cycles = 0;

  `uvm_object_utils(axi_stream_seq_item)

  // The payload arrays always describe exactly one beat of this link.
  constraint c_sizes {
    tdata.size() == data_bytes;
    tkeep.size() == data_bytes;
    tstrb.size() == data_bytes;
  }

  // AXI4-Stream 2.4.3: TKEEP low with TSTRB high is a reserved encoding.
  // Hard, so no `randomize() with` can talk the item into emitting one.
  //
  // Stated as "a data byte implies a kept byte" rather than the more
  // obvious "an unkept byte implies no data byte". The two are
  // contrapositives and mean exactly the same thing, but XSIM's solver
  // declares the second form unsatisfiable when it is combined with the
  // other foreach constraints below -- even for all-ones, which plainly
  // satisfies it. This form solves correctly.
  constraint c_byte_encoding {
    foreach (tstrb[i]) (tstrb[i] == 1'b1) -> (tkeep[i] == 1'b1);
  }

  // A link that carries no TKEEP behaves as though every byte were kept;
  // one that carries no TSTRB treats every kept byte as a data byte.
  constraint c_absent_keep { foreach (tkeep[i]) (!has_tkeep) -> (tkeep[i] == 1'b1); }
  constraint c_absent_strb { foreach (tstrb[i]) (!has_tstrb) -> (tstrb[i] == tkeep[i]); }
  constraint c_absent_last { (!has_tlast) -> (tlast == 1'b0); }

  // Zero every bit above the link's real width -- and the whole field
  // when the link does not carry the signal at all. Expressed as a shift
  // so it stays a single, cheap constraint at any width.
  constraint c_id_width   { has_tid   ? ((tid   >> id_width)   == '0) : (tid   == '0); }
  constraint c_dest_width { has_tdest ? ((tdest >> dest_width) == '0) : (tdest == '0); }
  constraint c_user_width { has_tuser ? ((tuser >> user_width) == '0) : (tuser == '0); }

  constraint c_delay { delay inside {[min_delay:max_delay]}; }

  // Ordinary traffic is dense: every lane a data byte. Sparse payloads
  // are opt-in, by clearing `dense` before randomizing:
  //
  //   beat.dense = 1'b0;
  //   assert (beat.randomize());          // TKEEP/TSTRB now free
  //
  // A plain knob rather than a `soft` constraint on purpose: XSIM's
  // solver hangs indefinitely on a soft constraint inside a foreach over
  // a rand dynamic array once the other foreach constraints above are
  // present. A non-rand knob gating hard implications behaves the same
  // from a user's point of view and solves in microseconds.
  constraint c_dense_default {
    foreach (tkeep[i]) dense -> (tkeep[i] == 1'b1);
    foreach (tstrb[i]) dense -> (tstrb[i] == 1'b1);
  }

  extern function new(string name = "axi_stream_seq_item");

  // Adopt a link's geometry, so the constraints above size and mask this
  // beat correctly. Called automatically from pre_randomize() when `agent_config`
  // is set; call it directly when building a beat without randomizing.
  extern function void set_geometry(axi_stream_config link_config);

  // Size the payload arrays for the current geometry without touching
  // their contents' randomness -- needed when a beat is assembled by
  // hand (in the monitor, or in a directed sequence).
  extern function void allocate();

  extern function void pre_randomize();

  // ---- Payload helpers ---------------------------------------------
  extern function axi_stream_byte_type_e byte_type(int unsigned index);
  extern function int unsigned num_data_bytes();      // bytes with TKEEP set
  extern function void set_bytes(byte unsigned bytes[]);  // pads/truncates to data_bytes
  extern function string tdata_string();

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
  extern virtual function void do_print(uvm_printer printer);
  extern virtual function string convert2string();

endclass : axi_stream_seq_item

function axi_stream_seq_item::new(string name = "axi_stream_seq_item");
  super.new(name);
  allocate();
endfunction : new

function void axi_stream_seq_item::set_geometry(axi_stream_config link_config);
  if (link_config == null)
    return;
  data_bytes = link_config.data_bytes;
  id_width   = link_config.id_width;
  dest_width = link_config.dest_width;
  user_width = link_config.user_width;
  has_tkeep  = link_config.has_tkeep;
  has_tstrb  = link_config.has_tstrb;
  has_tlast  = link_config.has_tlast;
  has_tid    = link_config.has_tid;
  has_tdest  = link_config.has_tdest;
  has_tuser  = link_config.has_tuser;
  min_delay  = link_config.min_beat_delay;
  max_delay  = link_config.max_beat_delay;
  allocate();
endfunction : set_geometry

function void axi_stream_seq_item::allocate();
  if (tdata.size() != data_bytes) tdata = new [data_bytes] (tdata);
  if (tkeep.size() != data_bytes) tkeep = new [data_bytes] (tkeep);
  if (tstrb.size() != data_bytes) tstrb = new [data_bytes] (tstrb);
endfunction : allocate

function void axi_stream_seq_item::pre_randomize();
  set_geometry(agent_config);
endfunction : pre_randomize

function axi_stream_byte_type_e axi_stream_seq_item::byte_type(int unsigned index);
  if (index >= tkeep.size())
    return AXIS_BYTE_NULL;
  return axi_stream_byte_type_e'({tkeep[index], tstrb[index]});
endfunction : byte_type

function int unsigned axi_stream_seq_item::num_data_bytes();
  num_data_bytes = 0;
  foreach (tkeep[i])
    if (tkeep[i])
      num_data_bytes++;
endfunction : num_data_bytes

// Load a beat from a plain byte stream, padding the tail with null bytes
// when the stream runs out. This is how a packet sequence chops an
// arbitrary-length payload into beats without caring about the width.
function void axi_stream_seq_item::set_bytes(byte unsigned bytes[]);
  allocate();
  foreach (tdata[i]) begin
    if (i < bytes.size()) begin
      tdata[i] = bytes[i];
      tkeep[i] = 1'b1;
      tstrb[i] = 1'b1;
    end
    else begin
      // Short final beat: the leftover lanes carry no data at all.
      tdata[i] = 8'h00;
      tkeep[i] = has_tkeep ? 1'b0 : 1'b1;
      tstrb[i] = 1'b0;
    end
  end
endfunction : set_bytes

// Most-significant byte first, so the string reads the way the TDATA
// vector looks in a waveform. Lanes TKEEP marks as null print as "--".
function string axi_stream_seq_item::tdata_string();
  tdata_string = "";
  for (int i = tdata.size() - 1; i >= 0; i--) begin
    if (has_tkeep && !tkeep[i]) tdata_string = {tdata_string, "--"};
    else                        tdata_string = {tdata_string, $sformatf("%02h", tdata[i])};
  end
endfunction : tdata_string

function void axi_stream_seq_item::do_copy(uvm_object rhs);
  axi_stream_seq_item rhs_;
  if (rhs == null)
    `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COPY", "cast of rhs to axi_stream_seq_item failed")
  super.do_copy(rhs);
  data_bytes   = rhs_.data_bytes;
  id_width     = rhs_.id_width;
  dest_width   = rhs_.dest_width;
  user_width   = rhs_.user_width;
  has_tkeep    = rhs_.has_tkeep;
  has_tstrb    = rhs_.has_tstrb;
  has_tlast    = rhs_.has_tlast;
  has_tid      = rhs_.has_tid;
  has_tdest    = rhs_.has_tdest;
  has_tuser    = rhs_.has_tuser;
  min_delay    = rhs_.min_delay;
  max_delay    = rhs_.max_delay;
  dense        = rhs_.dense;
  agent_config          = rhs_.agent_config;
  tdata        = new [rhs_.tdata.size()] (rhs_.tdata);
  tkeep        = new [rhs_.tkeep.size()] (rhs_.tkeep);
  tstrb        = new [rhs_.tstrb.size()] (rhs_.tstrb);
  tlast        = rhs_.tlast;
  tid          = rhs_.tid;
  tdest        = rhs_.tdest;
  tuser        = rhs_.tuser;
  delay        = rhs_.delay;
  stall_cycles = rhs_.stall_cycles;
endfunction : do_copy

// Compares wire content only. `delay` and `stall_cycles` describe *when*
// a beat happened, not what it carried, so a beat that crossed a FIFO
// still compares equal to the one that went in. TDATA is compared only
// on lanes TKEEP marks as valid: AXI4-Stream leaves a null byte's TDATA
// explicitly undefined, so comparing it would manufacture failures.
function bit axi_stream_seq_item::do_compare(uvm_object rhs, uvm_comparer comparer);
  axi_stream_seq_item rhs_;
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COMPARE", "cast of rhs to axi_stream_seq_item failed")
  if (!super.do_compare(rhs, comparer))
    return 1'b0;

  if (tdata.size() != rhs_.tdata.size()) begin
    comparer.print_msg($sformatf("beat width differs: %0d vs %0d bytes",
                                 tdata.size(), rhs_.tdata.size()));
    return 1'b0;
  end

  foreach (tkeep[i]) begin
    if (tkeep[i] !== rhs_.tkeep[i]) begin
      comparer.print_msg($sformatf("tkeep[%0d] differs: %b vs %b", i, tkeep[i], rhs_.tkeep[i]));
      return 1'b0;
    end
    if (has_tstrb && (tstrb[i] !== rhs_.tstrb[i])) begin
      comparer.print_msg($sformatf("tstrb[%0d] differs: %b vs %b", i, tstrb[i], rhs_.tstrb[i]));
      return 1'b0;
    end
    if (tkeep[i] && (tdata[i] !== rhs_.tdata[i])) begin
      comparer.print_msg($sformatf("tdata[%0d] differs: %02h vs %02h", i, tdata[i], rhs_.tdata[i]));
      return 1'b0;
    end
  end

  if (has_tlast && (tlast !== rhs_.tlast)) begin
    comparer.print_msg($sformatf("tlast differs: %b vs %b", tlast, rhs_.tlast));
    return 1'b0;
  end
  if (has_tid && (tid !== rhs_.tid)) begin
    comparer.print_msg($sformatf("tid differs: %0h vs %0h", tid, rhs_.tid));
    return 1'b0;
  end
  if (has_tdest && (tdest !== rhs_.tdest)) begin
    comparer.print_msg($sformatf("tdest differs: %0h vs %0h", tdest, rhs_.tdest));
    return 1'b0;
  end
  if (has_tuser && (tuser !== rhs_.tuser)) begin
    comparer.print_msg($sformatf("tuser differs: %0h vs %0h", tuser, rhs_.tuser));
    return 1'b0;
  end
  return 1'b1;
endfunction : do_compare

function void axi_stream_seq_item::do_print(uvm_printer printer);
  super.do_print(printer);
  printer.print_string("tdata", tdata_string());
  if (has_tkeep) printer.print_field_int("tkeep", num_data_bytes(), 32, UVM_DEC);
  if (has_tlast) printer.print_field_int("tlast", tlast, 1, UVM_BIN);
  if (has_tid)   printer.print_field_int("tid",   tid,   id_width,   UVM_HEX);
  if (has_tdest) printer.print_field_int("tdest", tdest, dest_width, UVM_HEX);
  if (has_tuser) printer.print_field_int("tuser", tuser, user_width, UVM_HEX);
  printer.print_field_int("delay", delay, 32, UVM_DEC);
endfunction : do_print

function string axi_stream_seq_item::convert2string();
  string s;
  s = $sformatf("tdata=0x%s", tdata_string());
  if (has_tlast) s = {s, $sformatf(" tlast=%0b", tlast)};
  if (has_tid)   s = {s, $sformatf(" tid=0x%0h", tid)};
  if (has_tdest) s = {s, $sformatf(" tdest=0x%0h", tdest)};
  if (has_tuser) s = {s, $sformatf(" tuser=0x%0h", tuser)};
  if (has_tkeep) s = {s, $sformatf(" keep=%0d/%0d", num_data_bytes(), data_bytes)};
  if (delay != 0)        s = {s, $sformatf(" delay=%0d", delay)};
  if (stall_cycles != 0) s = {s, $sformatf(" stalled=%0d", stall_cycles)};
  return s;
endfunction : convert2string
