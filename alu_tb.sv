`timescale 1ns/1ps

// ---------------- Part 1 opcode enum (as question) ----------------
typedef enum {ADD=0, SUB, MULT, DIV} opcode_e;

// ---------------- Transaction (as question) ----------------
class Transaction;
  rand opcode_e opcode;
  rand logic [31:0] operand1;
  rand logic [31:0] operand2;
endclass

// ---------------- Randomization check ----------------
`define SV_RAND_CHECK(r) \
  do begin if (!(r)) begin \
    $display("%s:%0d: Randomization failed: %s", `__FILE__, `__LINE__, `"r`"); \
    $finish; \
  end end while (0)

// ---------------- DUT (from prompt) ----------------
module alu_32x32x64_signed (
  input  logic signed [31:0] a,
  input  logic signed [31:0] b,
  input  logic [1:0]         op,
  output logic signed [63:0] result
);
  always_comb begin
    case (op)
      2'd0: result = {{32{a[31]}}, a} + {{32{b[31]}}, b};
      2'd1: result = {{32{a[31]}}, a} - {{32{b[31]}}, b};
      2'd2: result = (a * b);
      2'd3: result = (b != 0) ? (a / b) : 64'd0;
      default: result = {{32{a[31]}}, a} + {{32{b[31]}}, b};
    endcase
  end
endmodule

// ---------------- Simple interface (NO clocking block) ----------------
interface alu_if;
  logic clk;
  logic signed [31:0] a, b;
  logic [1:0]         op;
  logic signed [63:0] result;
endinterface

// ---------------- Observed item (monitor -> scoreboard) ----------------
class SampleItem;
  opcode_e            opcode;
  logic signed [31:0] a;
  logic signed [31:0] b;
  logic signed [63:0] result;
endclass

// ---------------- Generator ----------------
class Generator;
  mailbox #(Transaction) gen2drv;
  int unsigned n_txn;

  function new(mailbox #(Transaction) m, int unsigned n=1000);
    gen2drv = m;
    n_txn   = n;
  endfunction

  task run();
    Transaction tr;
    for (int i=0; i<n_txn; i++) begin
      tr = new();
      `SV_RAND_CHECK(tr.randomize());
      gen2drv.put(tr);
    end
  endtask
endclass

// ---------------- Driver (drive on posedge clk) ----------------
class Driver;
  virtual alu_if vif;
  mailbox #(Transaction) gen2drv;
  int unsigned n_txn;

  function new(virtual alu_if v, mailbox #(Transaction) m, int unsigned n=1000);
    vif = v; gen2drv = m; n_txn = n;
  endfunction

  task run();
    Transaction tr;

    // init
    vif.op <= 2'd0;
    vif.a  <= '0;
    vif.b  <= '0;

    for (int i=0; i<n_txn; i++) begin
      gen2drv.get(tr);
      @(posedge vif.clk);
      vif.op <= logic'(tr.opcode);         // enum -> 2-bit
      vif.a  <= $signed(tr.operand1);
      vif.b  <= $signed(tr.operand2);
    end
  endtask
endclass

// ---------------- Scoreboard ----------------
class Scoreboard;
  mailbox #(SampleItem) mon2scb;
  int unsigned n_txn;

  function new(mailbox #(SampleItem) m, int unsigned n=1000);
    mon2scb = m;
    n_txn   = n;
  endfunction

  function automatic logic signed [63:0] ref_model(opcode_e op, logic signed [31:0] a, logic signed [31:0] b);
    logic signed [63:0] aa, bb;
    aa = {{32{a[31]}}, a};
    bb = {{32{b[31]}}, b};
    case (op)
      ADD : ref_model = aa + bb;
      SUB : ref_model = aa - bb;
      MULT: ref_model = a * b;
      DIV : ref_model = (b != 0) ? (a / b) : 64'sd0;
      default: ref_model = aa + bb;
    endcase
  endfunction

  task run();
    int pass=0, fail=0;
    SampleItem it;
    logic signed [63:0] exp;

    for (int i=0; i<n_txn; i++) begin
      mon2scb.get(it);
      exp = ref_model(it.opcode, it.a, it.b);

      if (it.result !== exp) begin
        fail++;
        $display("FAIL @%0t op=%0d a=%0d b=%0d got=%0d exp=%0d",
                 $time, it.opcode, it.a, it.b, it.result, exp);
      end else begin
        pass++;
      end
    end

    $display("PART1 SUMMARY: PASS=%0d FAIL=%0d", pass, fail);
    if (fail==0) $display("? PART1 OK");
    else         $display("? PART1 FAIL");
  endtask
endclass

// ---------------- Monitor + Part2 Coverage ----------------
class Monitor;
  virtual alu_if vif;
  mailbox #(SampleItem) mon2scb;
  int unsigned n_txn;

  // covergroup auto-sampled on posedge clk
  covergroup cg @(posedge vif.clk);

    // a) all opcodes
    opcodes_cp: coverpoint vif.op {
      bins add  = {2'd0};
      bins sub  = {2'd1};
      bins mult = {2'd2};
      bins div  = {2'd3};
    }

    // b) operand1 special values (signed)
    operand1_cp: coverpoint $signed(vif.a) {
      bins max_neg = {32'sh8000_0000};
      bins zero    = {32'sd0};
      bins max_pos = {32'sh7FFF_FFFF};
      bins other   = default;
    }

    // c) advanced opcode bins
    opcodes_adv_cp: coverpoint vif.op {
      bins add_or_sub   = {2'd0, 2'd1};
      bins add_then_sub = (2'd0 => 2'd1);
    }

    // d) extra useful point: div by zero
    div_by_zero_cp: coverpoint ((vif.op==2'd3) && (vif.b==0)) {
      bins hit = {1};
    }

    // extra cross
    op_x_operand1_cp: cross opcodes_cp, operand1_cp;

  endgroup

  function new(virtual alu_if v, mailbox #(SampleItem) m, int unsigned n=1000);
    vif = v; mon2scb = m; n_txn = n;
    cg = new();
  endfunction

  task run();
    SampleItem it;

    for (int i=0; i<n_txn; i++) begin
      @(posedge vif.clk);
      #0; // let comb/NBA settle for result

      it = new();
      it.opcode = opcode_e'(vif.op);
      it.a      = vif.a;
      it.b      = vif.b;
      it.result = vif.result;
      mon2scb.put(it);
    end

    $display("---- FUNCTIONAL COVERAGE ----");
    $display("TOTAL CG = %0.2f%%", cg.get_inst_coverage());
    $display("opcodes_cp = %0.2f%%", cg.opcodes_cp.get_inst_coverage());
    $display("operand1_cp = %0.2f%%", cg.operand1_cp.get_inst_coverage());
    $display("opcodes_adv_cp = %0.2f%%", cg.opcodes_adv_cp.get_inst_coverage());
    $display("div_by_zero_cp = %0.2f%%", cg.div_by_zero_cp.get_inst_coverage());
    $display("op_x_operand1_cp = %0.2f%%", cg.op_x_operand1_cp.get_inst_coverage());
  endtask
endclass

// ---------------- Environment ----------------
class Environment;
  Generator  gen;
  Driver     drv;
  Monitor    mon;
  Scoreboard scb;

  mailbox #(Transaction) gen2drv;
  mailbox #(SampleItem)  mon2scb;

  virtual alu_if vif;
  int unsigned n_txn;

  function new(virtual alu_if v, int unsigned n=1000);
    vif = v; n_txn = n;
  endfunction

  function void build();
    gen2drv = new();
    mon2scb = new();

    gen = new(gen2drv, n_txn);
    drv = new(vif, gen2drv, n_txn);
    mon = new(vif, mon2scb, n_txn);
    scb = new(mon2scb, n_txn);
  endfunction

  task run();
    fork
      gen.run();
      drv.run();
      mon.run();
      scb.run();
    join
  endtask
endclass

// ---------------- TB Top (1GHz clock) ----------------
module tb_top;
  alu_if ifc();

  // 1GHz clock => 1ns period
  initial begin
    ifc.clk = 0;
    forever #0.5 ifc.clk = ~ifc.clk;
  end

  alu_32x32x64_signed dut (
    .a(ifc.a), .b(ifc.b), .op(ifc.op), .result(ifc.result)
  );

  initial begin
    Environment env;
    env = new(ifc, 1000);
    env.build();
    env.run();
    $finish;
  end
endmodule
