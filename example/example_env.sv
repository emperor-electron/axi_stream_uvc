///////////////////////////////////////////////////////////////////
// Filename: example_env.sv
// Author  : Benjamin Tamayo
// Date    : 2026-08-31
// Purpose : Example environment: a master agent driving the DUT's slave
//           port, a slave agent backpressuring its master port, and a
//           scoreboard between them.
///////////////////////////////////////////////////////////////////
//
// Two agents of the same type, differing only in the `role` field of the
// config each is given. That is the whole difference between "sources
// transfers" and "sources TREADY" -- the agent instantiates the driver
// its role calls for and leaves the other one out.
//
// This env is not parameterized: it names example_agent_t from
// example_tb_pkg, which has the widths baked in. That is the right shape
// when your testbench has one link geometry. If you need several widths
// live at once, tb/axi_stream_env.sv shows the pattern -- an
// unparameterized base class holding everything a test touches, plus a
// parameterized subclass that adds the agents.

class example_env extends uvm_env;

  `uvm_component_utils(example_env)

  example_agent_t    mst_agt;   // drives the DUT's slave port
  example_agent_t    slv_agt;   // backpressures the DUT's master port
  example_scoreboard sb;

  axi_stream_config mst_cfg;
  axi_stream_config slv_cfg;

  example_vif_t vif_in;
  example_vif_t vif_out;

  extern function new(string name = "example_env", uvm_component parent = null);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);

endclass : example_env

function example_env::new(string name = "example_env", uvm_component parent = null);
  super.new(name, parent);
endfunction : new

function void example_env::build_phase(uvm_phase phase);
  super.build_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 1 -- collect the interfaces the top module published, and the
  //           configs the test built. The field names match what
  //           example_tb_top.sv and example_base_test.sv set.
  // ---------------------------------------------------------------------
  if (!uvm_config_db#(example_vif_t)::get(this, "", "vif_in", vif_in))
    `uvm_fatal("NOVIF", {"no 'vif_in' in the config DB -- check that the type parameters ",
                         "in example_tb_top's set() match example_vif_t exactly"})
  if (!uvm_config_db#(example_vif_t)::get(this, "", "vif_out", vif_out))
    `uvm_fatal("NOVIF", {"no 'vif_out' in the config DB -- check that the type parameters ",
                         "in example_tb_top's set() match example_vif_t exactly"})
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "mst_cfg", mst_cfg))
    `uvm_fatal("NOCFG", "no 'mst_cfg' in the config DB")
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "slv_cfg", slv_cfg))
    `uvm_fatal("NOCFG", "no 'slv_cfg' in the config DB")

  // ---------------------------------------------------------------------
  // STEP 2 -- give each agent its own config and its own end of the
  //           link. Each agent expects exactly two things under its own
  //           instance name: "cfg" and "vif".
  //
  // The agent cross-checks the config's widths against its own type
  // parameters at build time, so a config that disagrees is reported
  // rather than silently truncating payloads.
  // ---------------------------------------------------------------------
  uvm_config_db#(axi_stream_config)::set(this, "mst_agt", "cfg", mst_cfg);
  uvm_config_db#(axi_stream_config)::set(this, "slv_agt", "cfg", slv_cfg);
  uvm_config_db#(example_vif_t)::set(this, "mst_agt", "vif", vif_in);
  uvm_config_db#(example_vif_t)::set(this, "slv_agt", "vif", vif_out);

  // ---------------------------------------------------------------------
  // STEP 3 -- build the agents and the scoreboard.
  // ---------------------------------------------------------------------
  mst_agt = example_agent_t::type_id::create("mst_agt", this);
  slv_agt = example_agent_t::type_id::create("slv_agt", this);
  sb      = example_scoreboard::type_id::create("sb", this);
endfunction : build_phase

function void example_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 4 -- subscribe to the monitors. Use pkt_ap for frames or ap for
  //           individual beats; see example_scoreboard.sv for which to
  //           pick. Both monitors publish regardless of role, so a
  //           passive agent still feeds checks and coverage.
  // ---------------------------------------------------------------------
  mst_agt.mon.pkt_ap.connect(sb.in_pkt_export);
  slv_agt.mon.pkt_ap.connect(sb.out_pkt_export);

  // The scoreboard only needs this for its clock.
  sb.vif = vif_in;
endfunction : connect_phase
