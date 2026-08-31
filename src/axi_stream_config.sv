///////////////////////////////////////////////////////////////////
// Filename: axi_stream_config.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Per-agent configuration for the AXI4-Stream UVC: which end
//           of the link the agent drives, which optional signals the
//           link carries, how wide they are, how the source paces
//           itself, and which backpressure model the sink applies.
///////////////////////////////////////////////////////////////////
//
// This object is deliberately *not* parameterized. The interface widths
// live here as plain integers so that sequences, the scoreboard and any
// user code can be written once and reused against a 4-byte link and a
// 16-byte link in the same simulation. The agent cross-checks these
// numbers against its own type parameters at build time, so a config
// that disagrees with the interface it is attached to is a loud error
// rather than a silently truncated payload.

class axi_stream_config extends uvm_object;

  // ---- Which end of the link, and whether we drive it at all ---------
  axi_stream_role_e role      = AXIS_MASTER;
  uvm_active_passive_enum is_active = UVM_ACTIVE;

  // ---- Link geometry. Normally filled in by the agent from its own
  // parameters (see axi_stream_agent::adopt_interface_geometry), so a
  // test only has to set these when building a config by hand.
  // 0 means "not stated": the agent fills it in from its own parameters
  // without complaint. A non-zero value that disagrees with the agent is
  // reported, since that is a real contradiction rather than a default.
  int unsigned data_bytes = 0;
  int unsigned id_width   = 0;
  int unsigned dest_width = 0;
  int unsigned user_width = 0;

  // ---- Which optional signals this link actually carries. TKEEP,
  // TSTRB and TLAST do not change any signal's width, so their presence
  // is configuration rather than parameterization; TID/TDEST/TUSER
  // default to "present iff the corresponding width is non-zero".
  bit has_tkeep = 1'b1;
  bit has_tstrb = 1'b1;
  bit has_tlast = 1'b1;
  bit has_tid   = 1'b0;
  bit has_tdest = 1'b0;
  bit has_tuser = 1'b0;

  // ---- Master-side pacing. The sequence library constrains each
  // transaction's `delay` (idle ACLK cycles inserted before the beat)
  // into this window, which is how a source-side bubble pattern is
  // programmed. Leaving both at 0 streams back-to-back at full rate.
  int unsigned min_beat_delay = 0;
  int unsigned max_beat_delay = 0;

  // ---- Slave-side backpressure. Left null, the agent installs an
  // axi_stream_default_ready_policy in AXIS_READY_ALWAYS mode.
  axi_stream_ready_policy ready_policy;

  // ---- Checks and instrumentation -----------------------------------
  // Drives the interface's own `checks_enable`; clear it only to let a
  // directed test drive deliberately illegal stimulus.
  bit protocol_checks_enable = 1'b1;
  bit coverage_enable        = 1'b1;

  // Cycles a transfer may stay offered (TVALID high, TREADY low) before
  // the monitor calls it a deadlock. 0 disables the watchdog, which is
  // the default because a test may legitimately backpressure forever
  // (AXIS_READY_NEVER); switch it on wherever the sink is expected to
  // drain.
  int unsigned stall_timeout_cycles = 0;

  `uvm_object_utils(axi_stream_config)

  extern function new(string name = "axi_stream_config");

  // Convenience: install a built-in backpressure model without having to
  // construct the policy object by hand. Arguments not relevant to the
  // chosen mode are ignored.
  extern function void set_ready_mode(axi_stream_ready_mode_e mode,
                                      int unsigned percent      = 50,
                                      int unsigned ready_cycles = 1,
                                      int unsigned stall_cycles = 1,
                                      int unsigned burst_beats  = 4,
                                      int unsigned delay_min    = 0,
                                      int unsigned delay_max    = 4);

  // Convenience: program the source-side bubble window.
  extern function void set_beat_delay(int unsigned min_cycles, int unsigned max_cycles);

  // Describe the link geometry. `data_bytes` is the only mandatory
  // number; a width of 0 turns the matching optional signal off.
  extern function void set_geometry(int unsigned data_bytes,
                                    int unsigned id_width   = 0,
                                    int unsigned dest_width = 0,
                                    int unsigned user_width = 0,
                                    bit          has_tkeep  = 1'b1,
                                    bit          has_tstrb  = 1'b1,
                                    bit          has_tlast  = 1'b1);

  extern virtual function void do_copy(uvm_object rhs);
  extern virtual function string convert2string();

endclass : axi_stream_config

function axi_stream_config::new(string name = "axi_stream_config");
  super.new(name);
endfunction : new

function void axi_stream_config::set_ready_mode(axi_stream_ready_mode_e mode,
                                                int unsigned percent      = 50,
                                                int unsigned ready_cycles = 1,
                                                int unsigned stall_cycles = 1,
                                                int unsigned burst_beats  = 4,
                                                int unsigned delay_min    = 0,
                                                int unsigned delay_max    = 4);
  axi_stream_default_ready_policy policy;
  policy = axi_stream_default_ready_policy::type_id::create("ready_policy");
  policy.mode          = mode;
  policy.ready_percent = percent;
  policy.ready_cycles  = ready_cycles;
  policy.stall_cycles  = stall_cycles;
  policy.burst_beats   = burst_beats;
  policy.delay_min     = delay_min;
  policy.delay_max     = delay_max;
  ready_policy         = policy;
endfunction : set_ready_mode

function void axi_stream_config::set_beat_delay(int unsigned min_cycles, int unsigned max_cycles);
  min_beat_delay = min_cycles;
  max_beat_delay = (max_cycles < min_cycles) ? min_cycles : max_cycles;
endfunction : set_beat_delay

function void axi_stream_config::set_geometry(int unsigned data_bytes,
                                              int unsigned id_width   = 0,
                                              int unsigned dest_width = 0,
                                              int unsigned user_width = 0,
                                              bit          has_tkeep  = 1'b1,
                                              bit          has_tstrb  = 1'b1,
                                              bit          has_tlast  = 1'b1);
  this.data_bytes = data_bytes;
  this.id_width   = id_width;
  this.dest_width = dest_width;
  this.user_width = user_width;
  this.has_tkeep  = has_tkeep;
  this.has_tstrb  = has_tstrb;
  this.has_tlast  = has_tlast;
  this.has_tid    = (id_width   > 0);
  this.has_tdest  = (dest_width > 0);
  this.has_tuser  = (user_width > 0);
endfunction : set_geometry

function void axi_stream_config::do_copy(uvm_object rhs);
  axi_stream_config rhs_;
  if (rhs == null)
    `uvm_fatal("DO_COPY", "rhs argument is null")
  if (!$cast(rhs_, rhs))
    `uvm_fatal("DO_COPY", "cast of rhs to axi_stream_config failed")
  super.do_copy(rhs);
  role                   = rhs_.role;
  is_active              = rhs_.is_active;
  data_bytes             = rhs_.data_bytes;
  id_width               = rhs_.id_width;
  dest_width             = rhs_.dest_width;
  user_width             = rhs_.user_width;
  has_tkeep              = rhs_.has_tkeep;
  has_tstrb              = rhs_.has_tstrb;
  has_tlast              = rhs_.has_tlast;
  has_tid                = rhs_.has_tid;
  has_tdest              = rhs_.has_tdest;
  has_tuser              = rhs_.has_tuser;
  min_beat_delay         = rhs_.min_beat_delay;
  max_beat_delay         = rhs_.max_beat_delay;
  ready_policy           = rhs_.ready_policy;
  protocol_checks_enable = rhs_.protocol_checks_enable;
  coverage_enable        = rhs_.coverage_enable;
  stall_timeout_cycles   = rhs_.stall_timeout_cycles;
endfunction : do_copy

function string axi_stream_config::convert2string();
  string signals;
  signals = {has_tkeep ? "TKEEP " : "",
             has_tstrb ? "TSTRB " : "",
             has_tlast ? "TLAST " : "",
             has_tid   ? "TID "   : "",
             has_tdest ? "TDEST " : "",
             has_tuser ? "TUSER"  : ""};
  return $sformatf(
      "%s %s: TDATA=%0dB (%0db) TID=%0db TDEST=%0db TUSER=%0db | optional: %s | delay=%0d..%0d | ready=%s",
      role.name(), is_active.name(), data_bytes, 8 * data_bytes,
      id_width, dest_width, user_width, signals == "" ? "(none)" : signals,
      min_beat_delay, max_beat_delay,
      (ready_policy == null) ? "(default)" : ready_policy.convert2string());
endfunction : convert2string
