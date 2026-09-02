///////////////////////////////////////////////////////////////////
// Filename: axi_stream_monitor.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : UVM monitor that samples an AXI4-Stream link, publishes one
//           axi_stream_seq_item per completed transfer and one
//           axi_stream_packet per TLAST, and turns the interface's
//           protocol assertion failures into UVM errors.
///////////////////////////////////////////////////////////////////
//
// The monitor is passive by construction -- it only ever reads the
// monitor clocking block -- so the same instance works whether the link
// is driven by this UVC, by a DUT, or by both ends of a DUT-to-DUT
// connection being observed.
//
// Two analysis ports, because the two views answer different questions:
//   beat_analysis_port     - one beat per handshake, for cycle-level checks and coverage
//   packet_analysis_port - one packet per TLAST, for content checks that should not
//            care how the frame was blocked into beats or paced
//
// A link configured without TLAST has no frame structure to recover, so
// there every beat is published as a one-beat packet.

class axi_stream_monitor #(
  parameter int DATA_BYTES = 4,
  parameter int ID_WIDTH   = 0,
  parameter int DEST_WIDTH = 0,
  parameter int USER_WIDTH = 0
) extends uvm_monitor;

  typedef virtual axi_stream_if #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) vif_t;
  typedef axi_stream_monitor #(DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH) this_type;

  `uvm_component_param_utils(this_type)

  vif_t             vif;
  axi_stream_config agent_config;

  uvm_analysis_port #(axi_stream_seq_item) beat_analysis_port;
  uvm_analysis_port #(axi_stream_packet)   packet_analysis_port;

  int unsigned num_beats   = 0;
  int unsigned num_packets = 0;

  // Packet under construction, plus the stall counter for the beat
  // currently being offered.
  local axi_stream_packet m_packet;
  local int unsigned      m_stall;

  extern function new(string name = "axi_stream_monitor", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual function void check_phase(uvm_phase phase);
  extern virtual function void report_phase(uvm_phase phase);

  // Snapshot the link at the current clocking event into a fresh item.
  extern virtual function axi_stream_seq_item sample_beat();

  // Append a beat to the packet under construction and publish the
  // packet when the frame ends.
  extern virtual function void collect_packet(axi_stream_seq_item beat);

endclass : axi_stream_monitor

function axi_stream_monitor::new(string name = "axi_stream_monitor", uvm_component parent = null);
  super.new(name, parent);
  beat_analysis_port     = new("beat_analysis_port", this);
  packet_analysis_port = new("packet_analysis_port", this);
endfunction : new

function void axi_stream_monitor::build_phase(uvm_phase phase);
  super.build_phase(phase);
  if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
    `uvm_fatal("NOVIF", $sformatf(
        "no virtual axi_stream_if #(%0d,%0d,%0d,%0d) set in the config DB for %s",
        DATA_BYTES, ID_WIDTH, DEST_WIDTH, USER_WIDTH, get_full_name()))
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "agent_config", agent_config))
    `uvm_fatal("NOCFG", "no axi_stream_config set in the config DB")
endfunction : build_phase

task axi_stream_monitor::run_phase(uvm_phase phase);
  axi_stream_seq_item beat;
  m_stall = 0;

  forever begin
    @(vif.mon_cb);

    if (vif.mon_cb.aresetn !== 1'b1) begin
      // A frame interrupted by reset never completes; drop it rather
      // than splicing its beats onto the next one.
      if ((m_packet != null) && (m_packet.num_beats() > 0))
        `uvm_warning("RESET_PKT", $sformatf(
            "ARESETn asserted mid-packet; discarding %0d collected beats", m_packet.num_beats()))
      m_packet   = null;
      m_stall = 0;
      continue;
    end

    if (vif.mon_cb.tvalid !== 1'b1)
      continue;

    if (vif.mon_cb.tready !== 1'b1) begin
      m_stall++;
      if ((agent_config.stall_timeout_cycles > 0) && (m_stall == agent_config.stall_timeout_cycles))
        `uvm_error("STALL_TIMEOUT", $sformatf(
            {"a transfer has been stalled for %0d cycles with TVALID high and TREADY low ",
             "on %s -- the sink may be deadlocked"},
            m_stall, vif.path()))
      continue;
    end

    beat = sample_beat();
    beat.stall_cycles = m_stall;
    m_stall = 0;
    num_beats++;
    beat_analysis_port.write(beat);
    collect_packet(beat);
  end
endtask : run_phase

function axi_stream_seq_item axi_stream_monitor::sample_beat();
  axi_stream_seq_item beat;
  logic [8*DATA_BYTES-1:0] data_v;
  logic [DATA_BYTES-1:0]   keep_v;
  logic [DATA_BYTES-1:0]   strb_v;

  beat = axi_stream_seq_item::type_id::create("beat");
  beat.set_geometry(agent_config);

  data_v = vif.mon_cb.tdata;
  // An absent TKEEP means every byte is kept; an absent TSTRB means
  // every kept byte is a data byte. Normalising here is what lets the
  // scoreboard compare links that carry different optional signals.
  keep_v = agent_config.has_tkeep ? vif.mon_cb.tkeep : '1;
  strb_v = agent_config.has_tstrb ? vif.mon_cb.tstrb : keep_v;

  for (int i = 0; i < DATA_BYTES; i++) begin
    beat.tdata[i] = data_v[i*8 +: 8];
    beat.tkeep[i] = keep_v[i];
    beat.tstrb[i] = strb_v[i];
  end

  beat.tlast = agent_config.has_tlast ? vif.mon_cb.tlast : 1'b0;
  beat.tid   = agent_config.has_tid   ? axi_stream_id_t'  (vif.mon_cb.tid)   : '0;
  beat.tdest = agent_config.has_tdest ? axi_stream_dest_t'(vif.mon_cb.tdest) : '0;
  beat.tuser = agent_config.has_tuser ? axi_stream_user_t'(vif.mon_cb.tuser) : '0;

  return beat;
endfunction : sample_beat

function void axi_stream_monitor::collect_packet(axi_stream_seq_item beat);
  if (m_packet == null)
    m_packet = axi_stream_packet::type_id::create("packet");
  m_packet.add(beat);

  // No TLAST on this link means no frame structure to recover: each
  // transfer stands alone.
  if (agent_config.has_tlast && !beat.tlast)
    return;

  if (!m_packet.routing_is_constant())
    `uvm_error("PKT_ROUTING",
        "TID/TDEST changed within a packet; AXI4-Stream requires them constant across a frame")

  num_packets++;
  packet_analysis_port.write(m_packet);
  m_packet = null;
endfunction : collect_packet

// The interface's assertions know nothing about UVM: they count their
// own failures. Turning that count into a UVM_ERROR here is what makes
// a protocol violation fail the test rather than scroll past in a log.
function void axi_stream_monitor::check_phase(uvm_phase phase);
  super.check_phase(phase);
  if (vif.protocol_error_count > 0)
    `uvm_error("PROTOCOL", $sformatf(
        "%0d AXI4-Stream protocol assertion failure(s) on %s -- see the $error lines above",
        vif.protocol_error_count, vif.path()))
  if ((m_packet != null) && (m_packet.num_beats() > 0))
    `uvm_warning("PKT_INCOMPLETE", $sformatf(
        "simulation ended with %0d beats collected and no TLAST on %s",
        m_packet.num_beats(), vif.path()))
endfunction : check_phase

function void axi_stream_monitor::report_phase(uvm_phase phase);
  super.report_phase(phase);
  `uvm_info("MON", $sformatf("observed %0d beats in %0d packets", num_beats, num_packets), UVM_LOW)
endfunction : report_phase
