///////////////////////////////////////////////////////////////////
// Filename: axi_stream_ready_policy.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-30
// Purpose : Programmable backpressure models for the AXI4-Stream slave
//           driver: a base policy class defining the one-call-per-cycle
//           TREADY contract, and a default implementation covering the
//           common always/never/random/duty/burst/delay shapes.
///////////////////////////////////////////////////////////////////
//
// The slave driver calls next_ready() exactly once per ACLK edge and
// drives whatever it returns for the following cycle. Deciding TREADY
// one cycle ahead is what keeps the model honest: it cannot peek at the
// TVALID it is about to answer, so no policy -- not even a user's -- can
// accidentally create the combinational TREADY-from-TVALID path that
// makes a testbench pass a design that would deadlock in silicon.
//
// TREADY has no protocol restrictions of its own: a slave may assert,
// deassert, or hold it at any time, so every policy here is legal by
// construction. Only the *master* side has stability rules to obey.
//
// To build a model these do not cover -- replaying a trace, following a
// credit counter, backpressuring only packets with a given TDEST --
// extend axi_stream_ready_policy, override next_ready(), and assign it
// to axi_stream_config::ready_policy. The policy is deliberately not
// parameterized by interface width, so one custom model works against
// every link in the testbench.

virtual class axi_stream_ready_policy extends uvm_object;

  extern function new(string name = "axi_stream_ready_policy");

  // Decide the TREADY value for the *next* cycle.
  //   tvalid        - TVALID sampled at this edge
  //   tlast         - TLAST  sampled at this edge
  //   beat_accepted - a transfer completed at this edge (TVALID && TREADY)
  pure virtual function bit next_ready(bit tvalid, bit tlast, bit beat_accepted);

  // Called whenever ARESETn asserts, so a stateful policy can restart
  // from a known point rather than resuming mid-pattern.
  extern virtual function void reset();

endclass : axi_stream_ready_policy

function axi_stream_ready_policy::new(string name = "axi_stream_ready_policy");
  super.new(name);
endfunction : new

function void axi_stream_ready_policy::reset();
  // Nothing to do for a stateless policy.
endfunction : reset


///////////////////////////////////////////////////////////////////
// The built-in models. All knobs are rand, so a test can randomize a
// whole backpressure profile in one go:
//
//   assert (pol.randomize() with { mode inside {AXIS_READY_RANDOM,
//                                               AXIS_READY_BURST};
//                                  ready_percent inside {[20:80]}; });
///////////////////////////////////////////////////////////////////
class axi_stream_default_ready_policy extends axi_stream_ready_policy;

  rand axi_stream_ready_mode_e mode;

  // AXIS_READY_RANDOM: chance, in percent, that TREADY is high in any
  // given cycle. 100 degenerates to ALWAYS, 0 to NEVER.
  rand int unsigned ready_percent;

  // AXIS_READY_DUTY: ready_cycles high then stall_cycles low, forever.
  // AXIS_READY_BURST reuses stall_cycles as the length of its stall.
  rand int unsigned ready_cycles;
  rand int unsigned stall_cycles;

  // AXIS_READY_BURST: transfers accepted before stalling.
  rand int unsigned burst_beats;

  // AXIS_READY_DELAY: cycles to hold TREADY low after TVALID appears,
  // re-drawn for every transfer.
  rand int unsigned delay_min;
  rand int unsigned delay_max;

  constraint c_percent { ready_percent inside {[0:100]}; }
  constraint c_cycles  { ready_cycles inside {[1:16]};
                         stall_cycles inside {[1:16]}; }
  constraint c_burst   { burst_beats  inside {[1:32]}; }
  constraint c_delay   { delay_min <= delay_max;
                         delay_max inside {[0:16]}; }

  `uvm_object_utils(axi_stream_default_ready_policy)

  // Pattern state.
  local bit          m_phase_ready;    // AXIS_READY_DUTY: in the high phase?
  local int unsigned m_phase_count;    // cycles spent in the current phase
  local int unsigned m_beats;          // AXIS_READY_BURST: beats this burst
  local bit          m_stalling;       // AXIS_READY_BURST: in the stall
  local bit          m_armed;          // AXIS_READY_DELAY: target drawn?
  local int unsigned m_delay_target;   // AXIS_READY_DELAY: cycles to wait
  local int unsigned m_delay_count;

  extern function new(string name = "axi_stream_default_ready_policy");
  extern virtual function bit next_ready(bit tvalid, bit tlast, bit beat_accepted);
  extern virtual function void reset();
  extern virtual function string convert2string();

  extern local function bit next_duty();
  extern local function bit next_burst(bit beat_accepted);
  extern local function bit next_delay(bit tvalid, bit beat_accepted);

endclass : axi_stream_default_ready_policy

function axi_stream_default_ready_policy::new(string name = "axi_stream_default_ready_policy");
  super.new(name);
  // Defaults chosen so a freshly constructed policy applies no
  // backpressure: a UVC that has not been told to throttle should not
  // silently start throttling.
  mode          = AXIS_READY_ALWAYS;
  ready_percent = 50;
  ready_cycles  = 1;
  stall_cycles  = 1;
  burst_beats   = 4;
  delay_min     = 0;
  delay_max     = 4;
  reset();
endfunction : new

function void axi_stream_default_ready_policy::reset();
  m_phase_ready  = 1'b1;
  m_phase_count  = 0;
  m_beats        = 0;
  m_stalling     = 1'b0;
  m_armed        = 1'b0;
  m_delay_target = 0;
  m_delay_count  = 0;
endfunction : reset

function bit axi_stream_default_ready_policy::next_ready(bit tvalid, bit tlast, bit beat_accepted);
  case (mode)
    AXIS_READY_ALWAYS : return 1'b1;
    AXIS_READY_NEVER  : return 1'b0;
    AXIS_READY_RANDOM : return ($urandom_range(99, 0) < ready_percent);
    AXIS_READY_DUTY   : return next_duty();
    AXIS_READY_BURST  : return next_burst(beat_accepted);
    AXIS_READY_DELAY  : return next_delay(tvalid, beat_accepted);
    default           : return 1'b1;
  endcase
endfunction : next_ready

// A free-running square wave, independent of traffic: ready_cycles high,
// stall_cycles low. Useful for reproducing a fixed-rate sink (a 1-in-N
// downstream clock crossing, say) exactly the same way on every seed.
function bit axi_stream_default_ready_policy::next_duty();
  bit value = m_phase_ready;
  m_phase_count++;
  if (m_phase_ready && (m_phase_count >= ready_cycles)) begin
    m_phase_ready = 1'b0;
    m_phase_count = 0;
  end
  else if (!m_phase_ready && (m_phase_count >= stall_cycles)) begin
    m_phase_ready = 1'b1;
    m_phase_count = 0;
  end
  return value;
endfunction : next_duty

// Traffic-driven rather than time-driven: count *accepted transfers*,
// not cycles, then shut the port for stall_cycles. This is the model
// that finds FIFO-full bugs, because the stall always lands after a
// known number of beats no matter how the source paced them.
function bit axi_stream_default_ready_policy::next_burst(bit beat_accepted);
  if (beat_accepted)
    m_beats++;

  if (m_stalling) begin
    m_phase_count++;
    if (m_phase_count >= stall_cycles) begin
      m_stalling    = 1'b0;
      m_phase_count = 0;
      m_beats       = 0;
      return 1'b1;
    end
    return 1'b0;
  end

  if (m_beats >= burst_beats) begin
    m_stalling    = 1'b1;
    m_phase_count = 0;
    return 1'b0;
  end
  return 1'b1;
endfunction : next_burst

// Hold TREADY low for a freshly drawn delay every time a transfer is
// offered, which exercises the "TVALID before TREADY" handshake ordering
// that a master must tolerate. The counter only advances while TVALID is
// asserted, so the delay measures real stall, not idle time.
function bit axi_stream_default_ready_policy::next_delay(bit tvalid, bit beat_accepted);
  if (beat_accepted)
    m_armed = 1'b0;

  if (!m_armed) begin
    m_delay_target = $urandom_range(delay_max, delay_min);
    m_delay_count  = 0;
    m_armed        = 1'b1;
  end

  if (!tvalid)
    return (m_delay_target == 0);

  if (m_delay_count >= m_delay_target)
    return 1'b1;

  m_delay_count++;
  return 1'b0;
endfunction : next_delay

function string axi_stream_default_ready_policy::convert2string();
  case (mode)
    AXIS_READY_RANDOM : return $sformatf("%s(%0d%%)", mode.name(), ready_percent);
    AXIS_READY_DUTY   : return $sformatf("%s(%0d on/%0d off)", mode.name(), ready_cycles, stall_cycles);
    AXIS_READY_BURST  : return $sformatf("%s(%0d beats/%0d stall)", mode.name(), burst_beats, stall_cycles);
    AXIS_READY_DELAY  : return $sformatf("%s(%0d..%0d)", mode.name(), delay_min, delay_max);
    default           : return mode.name();
  endcase
endfunction : convert2string
