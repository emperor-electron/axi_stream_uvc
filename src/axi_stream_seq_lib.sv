///////////////////////////////////////////////////////////////////
// Filename: axi_stream_seq_lib.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Reusable AXI4-Stream master sequences: single beats, framed
//           packets, explicit payloads, sparse (null/position byte)
//           packets, and randomised traffic.
///////////////////////////////////////////////////////////////////
//
// None of these sequences is parameterized, and none of them mentions a
// width. They read the link's geometry from the agent's config through
// the sequencer, so the very same sequence object -- started with the
// very same constraints -- produces 4-byte beats on one link and
// 16-byte beats on another.
//
// Source-side pacing comes from each beat's `delay` field, whose window
// is the config's min_beat_delay..max_beat_delay. Leaving that window at
// 0..0 streams at full rate; widening it injects legal TVALID bubbles,
// which is the master-side counterpart to the slave's ready policy.

virtual class axi_stream_base_seq extends uvm_sequence #(axi_stream_seq_item);

  `uvm_declare_p_sequencer(axi_stream_sequencer)

  axi_stream_config agent_config;

  // Non-rand mirrors of the link's routing widths, refreshed by
  // pre_randomize(). Constraints cannot safely dereference `agent_config` (it may
  // still be null when a test randomizes a sequence before starting it),
  // so the widths are copied out first and the constraints use these.
  // With no config yet, both are 0 and the routing fields solve to 0.
  protected int unsigned m_id_width   = 0;
  protected int unsigned m_dest_width = 0;

  extern function new(string name = "axi_stream_base_seq");
  extern virtual task pre_start();
  extern function void pre_randomize();

  // A beat already bound to this link's geometry, ready to randomize.
  extern function axi_stream_seq_item new_beat(string name = "beat");

endclass : axi_stream_base_seq

function axi_stream_base_seq::new(string name = "axi_stream_base_seq");
  super.new(name);
endfunction : new

task axi_stream_base_seq::pre_start();
  super.pre_start();
  if (agent_config == null) begin
    if (p_sequencer == null)
      `uvm_fatal("NOSQR", "sequence needs an axi_stream_sequencer to learn the link geometry")
    agent_config = p_sequencer.agent_config;
  end
  if (agent_config == null)
    `uvm_fatal("NOCFG", "the sequencer has no axi_stream_config")
endtask : pre_start

function void axi_stream_base_seq::pre_randomize();
  m_id_width   = (agent_config == null) ? 0 : agent_config.id_width;
  m_dest_width = (agent_config == null) ? 0 : agent_config.dest_width;
endfunction : pre_randomize

function axi_stream_seq_item axi_stream_base_seq::new_beat(string name = "beat");
  axi_stream_seq_item beat;
  beat = axi_stream_seq_item::type_id::create(name);
  beat.agent_config = agent_config;             // pre_randomize() adopts the geometry
  beat.set_geometry(agent_config);     // ...and so does a beat built by hand
  return beat;
endfunction : new_beat


///////////////////////////////////////////////////////////////////
// One beat, fully random within the link's geometry. TLAST is left
// free, so this is the sequence to use when framing does not matter.
///////////////////////////////////////////////////////////////////
class axi_stream_beat_seq extends axi_stream_base_seq;

  rand bit last;

  `uvm_object_utils(axi_stream_beat_seq)

  extern function new(string name = "axi_stream_beat_seq");
  extern virtual task body();

endclass : axi_stream_beat_seq

function axi_stream_beat_seq::new(string name = "axi_stream_beat_seq");
  super.new(name);
endfunction : new

task axi_stream_beat_seq::body();
  axi_stream_seq_item beat;
  bit beat_last = last;
  beat = new_beat();
  start_item(beat);
  if (!beat.randomize() with { tlast == beat_last; })
    `uvm_fatal("RAND", "beat randomization failed")
  finish_item(beat);
endtask : body


///////////////////////////////////////////////////////////////////
// One packet: a run of beats with TLAST on the last, and TID/TDEST held
// constant across the frame as AXI4-Stream requires.
//
// Give it `payload` and it carries exactly those bytes, chopping them
// into beats of whatever width the link is and marking the leftover
// lanes of a short final beat as null bytes. Leave `payload` empty and
// it generates num_beats random full beats instead.
///////////////////////////////////////////////////////////////////
class axi_stream_packet_seq extends axi_stream_base_seq;

  rand int unsigned num_beats;
  rand axi_stream_id_t   pkt_tid;
  rand axi_stream_dest_t pkt_tdest;

  // Explicit payload; when non-empty it wins over num_beats.
  byte unsigned payload[$];

  constraint c_num_beats { soft num_beats inside {[1:8]}; num_beats > 0; }

  // TID/TDEST have to fit the link, or the beat's own width constraints
  // and these will contradict each other and the solver will fail.
  constraint c_routing { (pkt_tid   >> m_id_width)   == 0;
                         (pkt_tdest >> m_dest_width) == 0; }


  `uvm_object_utils(axi_stream_packet_seq)

  extern function new(string name = "axi_stream_packet_seq");
  extern virtual task body();
  extern protected task send_payload();
  extern protected task send_random_beats();

endclass : axi_stream_packet_seq

function axi_stream_packet_seq::new(string name = "axi_stream_packet_seq");
  super.new(name);
endfunction : new

task axi_stream_packet_seq::body();
  if (payload.size() > 0) send_payload();
  else                    send_random_beats();
endtask : body

task axi_stream_packet_seq::send_payload();
  int unsigned width = agent_config.data_bytes;
  int unsigned sent  = 0;
  int unsigned total = payload.size();

  while (sent < total) begin
    axi_stream_seq_item beat;
    byte unsigned chunk[];
    int unsigned  n = (total - sent > width) ? width : (total - sent);
    bit           is_last = ((sent + n) >= total);
    axi_stream_id_t   t_id   = pkt_tid;
    axi_stream_dest_t t_dest = pkt_tdest;

    chunk = new [n];
    for (int i = 0; i < n; i++)
      chunk[i] = payload[sent + i];

    beat = new_beat();
    start_item(beat);
    // Randomize only what the payload does not pin down: the delay, and
    // TUSER. set_bytes() then overwrites TDATA/TKEEP/TSTRB, so the
    // constraint solver never has to reason about the payload at all.
    if (!beat.randomize() with { tlast == is_last;
                                 tid   == t_id;
                                 tdest == t_dest; })
      `uvm_fatal("RAND", "payload beat randomization failed")
    beat.set_bytes(chunk);
    finish_item(beat);

    sent += n;
  end
endtask : send_payload

task axi_stream_packet_seq::send_random_beats();
  for (int b = 0; b < num_beats; b++) begin
    axi_stream_seq_item beat;
    bit is_last = (b == (num_beats - 1));
    axi_stream_id_t   t_id   = pkt_tid;
    axi_stream_dest_t t_dest = pkt_tdest;

    beat = new_beat();
    start_item(beat);
    if (!beat.randomize() with { tlast == is_last;
                                 tid   == t_id;
                                 tdest == t_dest; })
      `uvm_fatal("RAND", "random beat randomization failed")
    finish_item(beat);
  end
endtask : send_random_beats


///////////////////////////////////////////////////////////////////
// A packet whose beats deliberately contain null and position bytes, to
// exercise the TKEEP/TSTRB encodings a dense-traffic test never reaches.
// The reserved TKEEP=0/TSTRB=1 combination stays unreachable: the
// sequence item forbids it with a hard constraint.
///////////////////////////////////////////////////////////////////
class axi_stream_sparse_packet_seq extends axi_stream_base_seq;

  rand int unsigned num_beats;
  rand axi_stream_id_t   pkt_tid;
  rand axi_stream_dest_t pkt_tdest;

  // Chance, in percent, that any given lane is dropped to a null byte,
  // and that a kept lane is only a position byte.
  rand int unsigned null_percent;
  rand int unsigned position_percent;


  // TID/TDEST have to fit the link, or the beat's own width constraints
  // and these will contradict each other and the solver will fail.
  constraint c_routing { (pkt_tid   >> m_id_width)   == 0;
                         (pkt_tdest >> m_dest_width) == 0; }

  constraint c_shape { soft num_beats inside {[1:6]}; num_beats > 0;
                       soft null_percent     inside {[10:60]};
                       soft position_percent inside {[0:25]};
                       null_percent     inside {[0:100]};
                       position_percent inside {[0:100]}; }

  `uvm_object_utils(axi_stream_sparse_packet_seq)

  extern function new(string name = "axi_stream_sparse_packet_seq");
  extern virtual task body();

endclass : axi_stream_sparse_packet_seq

function axi_stream_sparse_packet_seq::new(string name = "axi_stream_sparse_packet_seq");
  super.new(name);
endfunction : new

task axi_stream_sparse_packet_seq::body();
  if (!agent_config.has_tkeep && !agent_config.has_tstrb) begin
    `uvm_info("SPARSE",
        "link carries neither TKEEP nor TSTRB; sending dense beats instead", UVM_MEDIUM)
  end

  for (int b = 0; b < num_beats; b++) begin
    axi_stream_seq_item beat;
    bit is_last = (b == (num_beats - 1));
    axi_stream_id_t   t_id   = pkt_tid;
    axi_stream_dest_t t_dest = pkt_tdest;

    beat = new_beat();
    beat.dense = 1'b0;          // let the solver spread the lanes as well
    start_item(beat);
    if (!beat.randomize() with { tlast == is_last;
                                 tid   == t_id;
                                 tdest == t_dest; })
      `uvm_fatal("RAND", "sparse beat randomization failed")

    // Shape the lanes to the requested mix afterwards rather than
    // constraining them,
    // so the null/position mix is a plain probability the test can dial
    // rather than something the solver has to reconcile.
    if (agent_config.has_tkeep) begin
      foreach (beat.tkeep[i]) begin
        if ($urandom_range(99, 0) < null_percent) begin
          beat.tkeep[i] = 1'b0;
          beat.tstrb[i] = 1'b0;                  // never the reserved encoding
        end
        else if (agent_config.has_tstrb && ($urandom_range(99, 0) < position_percent)) begin
          beat.tkeep[i] = 1'b1;
          beat.tstrb[i] = 1'b0;                  // position byte
        end
      end
    end
    finish_item(beat);
  end
endtask : body


///////////////////////////////////////////////////////////////////
// A stream of randomly shaped packets: the default workhorse. Packet
// length, routing and pacing are all re-drawn per packet, so a long run
// covers the space without the test having to enumerate it.
///////////////////////////////////////////////////////////////////
class axi_stream_random_seq extends axi_stream_base_seq;

  rand int unsigned num_packets;
  rand int unsigned min_beats;
  rand int unsigned max_beats;

  // Fraction of packets, in percent, drawn from the sparse generator.
  rand int unsigned sparse_percent;

  constraint c_count  { soft num_packets inside {[4:16]}; num_packets > 0; }
  constraint c_beats  { soft min_beats == 1; soft max_beats == 8;
                        min_beats > 0; min_beats <= max_beats; max_beats <= 64; }
  constraint c_sparse { soft sparse_percent == 25; sparse_percent inside {[0:100]}; }

  `uvm_object_utils(axi_stream_random_seq)

  extern function new(string name = "axi_stream_random_seq");
  extern virtual task body();

endclass : axi_stream_random_seq

function axi_stream_random_seq::new(string name = "axi_stream_random_seq");
  super.new(name);
endfunction : new

task axi_stream_random_seq::body();
  for (int p = 0; p < num_packets; p++) begin
    if ($urandom_range(99, 0) < sparse_percent) begin
      axi_stream_sparse_packet_seq sparse_sequence;
      sparse_sequence = axi_stream_sparse_packet_seq::type_id::create($sformatf("sparse_packet_%0d", p));
      sparse_sequence.agent_config = agent_config;
      if (!sparse_sequence.randomize() with { num_beats inside {[min_beats:max_beats]}; })
        `uvm_fatal("RAND", "sparse packet sequence randomization failed")
      sparse_sequence.start(m_sequencer, this);
    end
    else begin
      axi_stream_packet_seq packet_sequence;
      packet_sequence = axi_stream_packet_seq::type_id::create($sformatf("packet_%0d", p));
      packet_sequence.agent_config = agent_config;
      if (!packet_sequence.randomize() with { num_beats inside {[min_beats:max_beats]}; })
        `uvm_fatal("RAND", "packet sequence randomization failed")
      packet_sequence.start(m_sequencer, this);
    end
  end
endtask : body
