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

  example_agent_t    master_agent;   // drives the DUT's slave port
  example_agent_t    slave_agent;    // backpressures the DUT's master port
  example_scoreboard scoreboard;

  axi_stream_config master_config;
  axi_stream_config slave_config;

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
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "master_config", master_config))
    `uvm_fatal("NOCFG", "no 'master_config' in the config DB")
  if (!uvm_config_db#(axi_stream_config)::get(this, "", "slave_config", slave_config))
    `uvm_fatal("NOCFG", "no 'slave_config' in the config DB")

  // ---------------------------------------------------------------------
  // STEP 2 -- give each agent its own config and its own end of the
  //           link. Each agent expects exactly two things under its own
  //           instance name: "agent_config" and "vif".
  //
  // The agent cross-checks the config's widths against its own type
  // parameters at build time, so a config that disagrees is reported
  // rather than silently truncating payloads.
  // ---------------------------------------------------------------------
  uvm_config_db#(axi_stream_config)::set(this, "master_agent", "agent_config", master_config);
  uvm_config_db#(axi_stream_config)::set(this, "slave_agent", "agent_config", slave_config);
  uvm_config_db#(example_vif_t)::set(this, "master_agent", "vif", vif_in);
  uvm_config_db#(example_vif_t)::set(this, "slave_agent", "vif", vif_out);

  // ---------------------------------------------------------------------
  // STEP 3 -- build the agents and the scoreboard.
  // ---------------------------------------------------------------------
  master_agent = example_agent_t::type_id::create("master_agent", this);
  slave_agent = example_agent_t::type_id::create("slave_agent", this);
  scoreboard      = example_scoreboard::type_id::create("scoreboard", this);
endfunction : build_phase

function void example_env::connect_phase(uvm_phase phase);
  super.connect_phase(phase);

  // ---------------------------------------------------------------------
  // STEP 4 -- subscribe to the monitors. Use packet_analysis_port for frames or beat_analysis_port for
  //           individual beats; see example_scoreboard.sv for which to
  //           pick. Both monitors publish regardless of role, so a
  //           passive agent still feeds checks and coverage.
  // ---------------------------------------------------------------------
  master_agent.monitor.packet_analysis_port.connect(scoreboard.in_packet_export);
  slave_agent.monitor.packet_analysis_port.connect(scoreboard.out_packet_export);

  // The scoreboard only needs this for its clock.
  scoreboard.vif = vif_in;
endfunction : connect_phase
