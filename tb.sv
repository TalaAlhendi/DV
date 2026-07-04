`timescale 1ns/1ps

module tb;

  // ==================================================
  // Parameters
  // ==================================================
  localparam int  ADDR_WIDTH = 8;
  localparam int  DATA_WIDTH = 24;
  localparam int  DEPTH      = 1 << ADDR_WIDTH;
  localparam logic [DATA_WIDTH-1:0] RESET_VAL = 24'h123456;

  localparam int MAX_READY_CYCLES = 20;     // for assertion / timeout
  localparam int N_RESET_READS    = 400;    // phase A
  localparam int N_MAIN_TRANS     = 6000;   // phase B
  localparam int N_FINAL_READS    = 400;    // phase C

  // ==================================================
  // Clock & Reset
  // ==================================================
  logic clk;
  logic rstn;

  initial clk = 0;
  always #0.5 clk = ~clk;

  initial begin
    rstn = 0;
    repeat (5) @(posedge clk);
    rstn = 1;
  end

  // ==================================================
  // DUT Signals
  // ==================================================
  logic [ADDR_WIDTH-1:0] addr;
  logic                  sel;
  logic                  wr;
  logic                  acc;    // 1-bit
  logic                  func;   // 1-bit
  logic [DATA_WIDTH-1:0] wdata;
  logic [DATA_WIDTH-1:0] rdata;
  logic                  ready;

  // ==================================================
  // DUT Instance (Black Box)
  // ==================================================
  reg_ctrl #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(DEPTH),
    .RESET_VAL(RESET_VAL)
  ) dut (
    .clk   (clk),
    .rstn  (rstn),
    .addr  (addr),
    .sel   (sel),
    .wr    (wr),
    .acc   (acc),
    .func  (func),
    .wdata (wdata),
    .rdata (rdata),
    .ready (ready)
  );

  // ==================================================
  // Assertions on READY 
  // ==================================================
  // ready should not assert when sel is low (protocol sanity)
  property p_ready_implies_sel;
    @(posedge clk) disable iff (!rstn)
      ready |-> sel;
  endproperty
  a_ready_implies_sel: assert property (p_ready_implies_sel)
    else $error("[%0t] ASSERT FAIL: ready high while sel low", $time);

  // when we start a transaction (sel rises), ready should come within MAX_READY_CYCLES
  property p_ready_timeout;
    @(posedge clk) disable iff (!rstn)
      $rose(sel) |-> ##[1:MAX_READY_CYCLES] ready;
  endproperty
  a_ready_timeout: assert property (p_ready_timeout)
    else $error("[%0t] ASSERT FAIL: ready timeout (> %0d cycles)", $time, MAX_READY_CYCLES);

  // ==================================================
  // Transaction 
  // ==================================================
  class reg_tr;
    rand bit [ADDR_WIDTH-1:0] addr;
    rand bit                  wr;
    rand bit                  acc;
    rand bit                  func;
    rand bit [DATA_WIDTH-1:0] wdata;

    // Observed
    bit  [DATA_WIDTH-1:0] rdata;
    bit                   ready;

    // ---- CRT constraints (pseudo-random, weighted) ----
    // Keep as CRT, but biased to hit bins frequently.
    constraint c_wr_dist {
      wr dist { 1 := 55, 0 := 45 };  // balanced-ish
    }

    constraint c_addr_dist {
      addr dist {
        // one-hot (8 bins)
        8'h01 := 4, 8'h02 := 4, 8'h04 := 4, 8'h08 := 4,
        8'h10 := 4, 8'h20 := 4, 8'h40 := 4, 8'h80 := 4,

        // edges (min/min+1/max/max-1)
        8'h00 := 4, 8'hFF := 4, 8'hFE := 4,

        // alternating
        8'h55 := 4, 8'hAA := 4,

        // middle +-1 (0x7e,0x7f,0x80,0x81)
        8'h7E := 4, 8'h7F := 4, 8'h80 := 4, 8'h81 := 4,

        // all others
        [8'h00:8'hFF] := 1
      };
    }

    // wdata bins (similar to addr bins expanded to 24-bit) + one-byte-set
    constraint c_wdata_dist {
      wdata dist {
        // edges
        24'h000000 := 5,
        24'h000001 := 3,
        24'hFFFFFF := 5,
        24'hFFFFFE := 3,

        // alternating patterns
        24'h555555 := 4,
        24'hAAAAAA := 4,

        // mid +-1 around 24-bit boundary
        24'h7FFFFE := 3,
        24'h7FFFFF := 4,
        24'h800000 := 4,
        24'h800001 := 3,

        // one-byte-set (explicit requirement)
        24'h0000FF := 6,
        24'h00FF00 := 6,
        24'hFF0000 := 6,

        // some one-hot 24-bit examples (helps hit "similar to addr bins" idea)
        24'h000001 := 3,
        24'h000002 := 3,
        24'h000004 := 3,
        24'h000080 := 3,
        24'h000100 := 3,
        24'h010000 := 3,
        24'h800000 := 3,

        // all others
        [24'h000000:24'hFFFFFF] := 1
      };
    }
  endclass

  // ==================================================
  // Mailboxes
  // ==================================================
  mailbox #(reg_tr) gen2drv = new();
  mailbox #(reg_tr) mon2chk = new();

  // ==================================================
  // Coverage Component
  // ==================================================
  class cov_comp;

    covergroup cg with function sample(reg_tr t);

      // cp1: addr (18 bins)
      cp1_addr: coverpoint t.addr {
        // 8 one-hot bins
        bins onehot[] = {8'h01,8'h02,8'h04,8'h08,8'h10,8'h20,8'h40,8'h80};

        // min, min+1, max, max-1
        bins min    = {8'h00};
        bins min_p1 = {8'h01};   // note: overlaps onehot(01) but kept for assignment wording
        bins max    = {8'hFF};
        bins max_m1 = {8'hFE};

        // alternating
        bins alt1 = {8'h55};
        bins alt2 = {8'hAA};

        // middle +-1
        bins mid_m1 = {8'h7E};
        bins mid_0  = {8'h7F};
        bins mid_p0 = {8'h80};
        bins mid_p1 = {8'h81};
      }

      // cp2: wr
      cp2_wr: coverpoint t.wr;

      // cp4 acc, cp5 func
      cp4_acc:  coverpoint t.acc;
      cp5_func: coverpoint t.func;

      // cp3: wdata sampled when wr=1
      cp3_wdata: coverpoint t.wdata iff (t.wr) {
        // edges
        bins min    = {24'h000000};
        bins min_p1 = {24'h000001};
        bins max    = {24'hFFFFFF};
        bins max_m1 = {24'hFFFFFE};

        // alternating
        bins alt1 = {24'h555555};
        bins alt2 = {24'hAAAAAA};

        // mid +-1
        bins mid_m1 = {24'h7FFFFE};
        bins mid_0  = {24'h7FFFFF};
        bins mid_p0 = {24'h800000};
        bins mid_p1 = {24'h800001};

        // one-byte-set
        bins one_byte[] = {24'h0000FF,24'h00FF00,24'hFF0000};

        // some "one-hot like" bins (representative)
        bins onehot24[] = {24'h000001,24'h000002,24'h000004,24'h000080,
                           24'h000100,24'h010000,24'h800000};
      }

      // cp6: rdata sampled when wr=0
      cp6_rdata: coverpoint t.rdata iff (!t.wr) {
        bins min    = {24'h000000};
        bins min_p1 = {24'h000001};
        bins max    = {24'hFFFFFF};
        bins max_m1 = {24'hFFFFFE};

        bins alt1 = {24'h555555};
        bins alt2 = {24'hAAAAAA};

        bins mid_m1 = {24'h7FFFFE};
        bins mid_0  = {24'h7FFFFF};
        bins mid_p0 = {24'h800000};
        bins mid_p1 = {24'h800001};

        bins one_byte[] = {24'h0000FF,24'h00FF00,24'hFF0000};
      }

      // cp7 cross (example suitable cross required)
      cp7_cross: cross cp1_addr, cp2_wr, cp4_acc, cp5_func, cp3_wdata;

    endgroup

    function new();
      cg = new();
    endfunction

    function void sample_tr(reg_tr t);
      cg.sample(t);
    endfunction
  endclass

  cov_comp cov = new();

  // ==================================================
  // Scoreboard / Checker
  // - Keeps a reference model of memory
  // - Checks reset reads, main reads, final reads
  // ==================================================
  class checker;
    mailbox #(reg_tr) mbx;

    bit [DATA_WIDTH-1:0] mem_model [0:DEPTH-1];

    int checks;
    int errors;

    function new(mailbox #(reg_tr) m);
      mbx = m;
      checks = 0;
      errors = 0;
    endfunction

    task init_model_after_reset();
      for (int i = 0; i < DEPTH; i++) begin
        mem_model[i] = RESET_VAL;
      end
    endtask

    function automatic bit [DATA_WIDTH-1:0] do_accumulate(
      input bit [DATA_WIDTH-1:0] oldv,
      input bit [DATA_WIDTH-1:0] newv,
      input bit acc_i,
      input bit func_i
    );
      bit [DATA_WIDTH-1:0] res;
      if (!acc_i) begin
        res = newv;
      end else begin
        if (!func_i) res = oldv + newv;   // accumulate add
        else         res = oldv * newv;   // accumulate multiply
      end
      return res; // wraps naturally in DATA_WIDTH bits
    endfunction

    task run();
      reg_tr t;
      init_model_after_reset();

      forever begin
        mbx.get(t);
        checks++;

        // Always check ready observed is 1 at handshake
        if (t.ready !== 1'b1) begin
          errors++;
          $error("[%0t] CHECK FAIL: ready not 1 at handshake", $time);
        end

        if (t.wr) begin
          // update model on writes
          mem_model[t.addr] = do_accumulate(mem_model[t.addr], t.wdata, t.acc, t.func);
        end else begin
          // check reads
          bit [DATA_WIDTH-1:0] exp;
          exp = mem_model[t.addr];

          if (t.rdata !== exp) begin
            errors++;
            $error("[%0t] READ MISMATCH addr=%0h exp=%0h got=%0h (acc=%0b func=%0b)",
                   $time, t.addr, exp, t.rdata, t.acc, t.func);
          end
        end
      end
    endtask
  endclass

  // ==================================================
  // Generator 
  // - Only uses randomized objects (randomize + constraints)
  // ==================================================
  class generator;
    mailbox #(reg_tr) mbx;

    function new(mailbox #(reg_tr) m);
      mbx = m;
    endfunction

    task send_tr(bit force_wr, bit do_force_wr);
      reg_tr t = new();

      // Randomize with optional forcing wr for phases
      if (do_force_wr) begin
        if (!t.randomize() with { wr == force_wr; }) begin
          $fatal("Randomize failed (forced wr)");
        end
      end else begin
        if (!t.randomize()) begin
          $fatal("Randomize failed");
        end
      end

      mbx.put(t);
    endtask

    task run();
      // Phase A: After reset -> many READs to check reset value
      for (int i = 0; i < N_RESET_READS; i++) begin
        send_tr(0, 1); // force wr=0
      end

      // Phase B: Main randomized transactions (reads+writes)
      for (int i = 0; i < N_MAIN_TRANS; i++) begin
        send_tr(0, 0); // no forcing, wr is randomized by dist constraint
      end

      // Phase C: Final -> many READs to check final values
      for (int i = 0; i < N_FINAL_READS; i++) begin
        send_tr(0, 1); // force wr=0
      end
    endtask
  endclass

  // ==================================================
  // Driver
  // - Drives DUT using transactions only
  // - Keeps sel high until ready
  // ==================================================
  class driver;
    mailbox #(reg_tr) mbx;

    function new(mailbox #(reg_tr) m);
      mbx = m;
    endfunction

    task run();
      // default idle
      addr  <= '0;
      sel   <= 1'b0;
      wr    <= 1'b0;
      acc   <= 1'b0;
      func  <= 1'b0;
      wdata <= '0;

      wait (rstn);

      forever begin
        reg_tr t;
        mbx.get(t);

        // Drive at posedge
        @(posedge clk);
        addr  <= t.addr;
        wr    <= t.wr;
        acc   <= t.acc;
        func  <= t.func;
        wdata <= t.wdata;
        sel   <= 1'b1;

        // Wait for ready with a hard timeout too (extra safety)
        int cyc = 0;
        while (!ready) begin
          @(posedge clk);
          cyc++;
          if (cyc > MAX_READY_CYCLES) begin
            $error("[%0t] DRIVER TIMEOUT waiting ready (>%0d cycles)", $time, MAX_READY_CYCLES);
            break;
          end
        end

        // Deassert sel next cycle
        @(posedge clk);
        sel <= 1'b0;
      end
    endtask
  endclass

  // ==================================================
  // Monitor
  // - Captures completed handshakes and sends to checker
  // - Updates coverage 
  // ==================================================
  class monitor;
    mailbox #(reg_tr) mbx;

    function new(mailbox #(reg_tr) m);
      mbx = m;
    endfunction

    task run();
      wait (rstn);
      forever begin
        @(posedge clk);
        if (sel && ready) begin
          reg_tr t = new();
          t.addr  = addr;
          t.wr    = wr;
          t.acc   = acc;
          t.func  = func;
          t.wdata = wdata;
          t.rdata = rdata;
          t.ready = ready;

          // coverage sample
          cov.sample_tr(t);

          // checker
          mbx.put(t);
        end
      end
    endtask
  endclass

  // ==================================================
  // TB Control
  // ==================================================
  generator gen;
  driver    drv;
  monitor   mon;
  checker   chk;

  initial begin
    gen = new(gen2drv);
    drv = new(gen2drv);
    mon = new(mon2chk);
    chk = new(mon2chk);

    fork
      gen.run();
      drv.run();
      mon.run();
      chk.run();
    join_none

    // Run long enough for all phases to complete
    // rough upper bound: each transaction <= (MAX_READY_CYCLES+3) cycles
    int total_tr = N_RESET_READS + N_MAIN_TRANS + N_FINAL_READS;
    int max_cycles = total_tr * (MAX_READY_CYCLES + 3) + 200;
    repeat (max_cycles) @(posedge clk);

    $display("\n=== Checker Report ===");
    $display("Total checks : %0d", chk.checks);
    $display("Errors       : %0d", chk.errors);
    if (chk.errors == 0) $display("*** TEST PASSED ***");
    else                 $display("*** TEST FAILED ***");

    $finish;
  end

endmodule
