// Layered testbench for 4 bit up counter (sequential circuit)
// design.sv has the counter, this file has the whole testbench


// ---------- interface ----------
// connects the testbench to the DUT, all the signals are in one place
interface intf (input logic clk);

  // starting values, so DUT gets a reset in the first clock
  logic       rst = 1;
  logic       en  = 0;
  logic [3:0] count;

  // clocking block for monitors
  // #1step takes the value just before the clock edge, same as what the flip flop sees
  // so no race condition between tb and dut
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, en, count;
  endclocking

endinterface


// ---------- transaction (packet) ----------
// one packet = values of one clock cycle
class transaction;

  // inputs of the dut are rand so they get random values
  rand bit rst;
  rand bit en;

  // output, not rand because dut gives this
  // logic (not bit) so x values from the dut are not hidden
  logic [3:0] count;

  // reset should be less, if its too much counter will never reach 15
  // 1 in 25 times reset
  constraint c_rst { rst dist {1 := 1, 0 := 24}; }
  // enable is on most of the time (4 out of 5)
  constraint c_en  { en  dist {1 := 4, 0 := 1 }; }

  // to print the packet, used for debugging
  function void display(string name);
    $display("--------------------------");
    $display(" %s ", name);
    $display("--------------------------");
    $display("rst = %0d, en = %0d", rst, en);
    $display("count = %0d", count);
    $display("--------------------------");
  endfunction

endclass


// ---------- generator ----------
// makes random packets and sends them to the driver using mailbox
class generator;

  transaction trans;       // handle for the packet
  mailbox     gen2drv;     // mailbox to driver
  int         repeat_count;  // number of packets to generate

  function new(mailbox gen2drv);
    this.gen2drv = gen2drv;
  endfunction

  task main();
    repeat (repeat_count) begin
      trans = new();   // new object every time otherwise all packets will be same object
      if (!trans.randomize())
        $fatal("Generator: randomization failed");
      gen2drv.put(trans);
    end
  endtask

endclass


// ---------- driver ----------
// takes packet from mailbox and applies rst and en to the dut pins
class driver;

  virtual intf vif;        // virtual interface, class cant have a real interface
  mailbox      gen2drv;
  int          drv_count = 0;   // counts how many packets are driven

  function new(virtual intf vif, mailbox gen2drv);
    this.vif     = vif;
    this.gen2drv = gen2drv;
  endfunction

  task main();
    transaction trans;
    forever begin
      gen2drv.get(trans);       // waits here till a packet comes
      @(posedge vif.clk);       // wait for clock edge
      vif.rst <= trans.rst;     // used <= so the value changes after the edge
      vif.en  <= trans.en;
      drv_count++;
    end
  endtask

endclass


// ---------- monitor 1 (input monitor) ----------
// only reads the inputs rst and en, sends them to reference model
class monitor_in;

  virtual intf vif;
  mailbox      mon2rm;     // mailbox to reference model

  function new(virtual intf vif, mailbox mon2rm);
    this.vif    = vif;
    this.mon2rm = mon2rm;
  endfunction

  task main();
    transaction trans;
    forever begin
      @(vif.mon_cb);                // every clock edge
      trans     = new();
      trans.rst = vif.mon_cb.rst;
      trans.en  = vif.mon_cb.en;
      mon2rm.put(trans);
    end
  endtask

endclass


// ---------- monitor 2 (output monitor) ----------
// only reads the output count, sends it to scoreboard
class monitor_out;

  virtual intf vif;
  mailbox      mon2scb;    // mailbox to scoreboard

  function new(virtual intf vif, mailbox mon2scb);
    this.vif     = vif;
    this.mon2scb = mon2scb;
  endfunction

  task main();
    transaction trans;
    // the counter output comes one clock after the input is given
    // so skip the first edge here, then both monitors stay matched
    @(vif.mon_cb);
    forever begin
      @(vif.mon_cb);
      trans       = new();
      trans.count = vif.mon_cb.count;
      mon2scb.put(trans);
    end
  endtask

endclass


// ---------- reference model ----------
// our own counter in the testbench, tells what the output should be
class reference_model;

  mailbox   mon2rm;        // inputs come from monitor 1
  mailbox   rm2scb;        // expected output goes to scoreboard
  bit [3:0] exp_count = 0; // remembers the count, this is the memory

  function new(mailbox mon2rm, mailbox rm2scb);
    this.mon2rm = mon2rm;
    this.rm2scb = rm2scb;
  endfunction

  task main();
    transaction in_t, exp_t;
    forever begin
      mon2rm.get(in_t);

      // same rules as the counter
      if (in_t.rst)     exp_count = 0;
      else if (in_t.en) exp_count = exp_count + 1;   // 4 bit so it goes 15 to 0 by itself

      exp_t       = new();
      exp_t.rst   = in_t.rst;
      exp_t.en    = in_t.en;
      exp_t.count = exp_count;
      rm2scb.put(exp_t);
    end
  endtask

endclass


// ---------- scoreboard ----------
// compares expected count (reference model) with actual count (dut)
class scoreboard;

  mailbox rm2scb;          // expected
  mailbox mon2scb;         // actual
  int     pass_count = 0;
  int     fail_count = 0;

  function new(mailbox rm2scb, mailbox mon2scb);
    this.rm2scb  = rm2scb;
    this.mon2scb = mon2scb;
  endfunction

  task main();
    transaction exp_t, act_t;
    forever begin
      rm2scb.get(exp_t);
      mon2scb.get(act_t);

      // used === so x values are also caught
      if (exp_t.count === act_t.count) begin
        pass_count++;
        $display("[SCB] PASS : rst=%0d en=%0d | expected=%0d actual=%0d",
                 exp_t.rst, exp_t.en, exp_t.count, act_t.count);
      end
      else begin
        fail_count++;
        $display("[SCB] FAIL : rst=%0d en=%0d | expected=%0d actual=%0d  <-- MISMATCH",
                 exp_t.rst, exp_t.en, exp_t.count, act_t.count);
      end
    end
  endtask

  // prints final result
  function void report();
    $display("==================================");
    $display(" TEST SUMMARY: %0d passed, %0d failed", pass_count, fail_count);
    if (fail_count == 0) $display(" RESULT: TEST PASSED");
    else                 $display(" RESULT: TEST FAILED");
    $display("==================================");
  endfunction

endclass


// ---------- environment ----------
// creates all the classes and mailboxes and connects them
class environment;

  generator       gen;
  driver          driv;
  monitor_in      mon1;
  monitor_out     mon2;
  reference_model rm;
  scoreboard      scb;

  mailbox gen2drv;   // generator to driver
  mailbox mon2rm;    // monitor 1 to reference model
  mailbox rm2scb;    // reference model to scoreboard
  mailbox mon2scb;   // monitor 2 to scoreboard

  virtual intf vif;

  function new(virtual intf vif);
    this.vif = vif;

    // making the mailboxes
    gen2drv = new();
    mon2rm  = new();
    rm2scb  = new();
    mon2scb = new();

    // making the objects and passing mailboxes / interface
    gen  = new(gen2drv);
    driv = new(vif, gen2drv);
    mon1 = new(vif, mon2rm);
    mon2 = new(vif, mon2scb);
    rm   = new(mon2rm, rm2scb);
    scb  = new(rm2scb, mon2scb);
  endfunction

  // run everything at the same time
  task test();
    fork
      gen.main();
      driv.main();
      mon1.main();
      mon2.main();
      rm.main();
      scb.main();
    join_none
  endtask

  task run();
    test();
    wait (driv.drv_count == gen.repeat_count);  // wait till all packets are driven
    repeat (5) @(posedge vif.clk);              // few extra clocks for the last result
    scb.report();
    $finish;
  endtask

endclass


// ---------- test ----------
// decides how many packets to run
program test (intf vif);

  environment env;

  initial begin
    env = new(vif);
    env.gen.repeat_count = 300;   // can change this number
    env.run();
  end

endprogram


// ---------- top module ----------
// clock, interface, dut and test are connected here
module testbench_top;

  bit clk;
  always #5 clk = ~clk;      // clock period is 10

  intf vif (clk);            // interface

  counter dut (              // dut
    .clk   (vif.clk),
    .rst   (vif.rst),
    .en    (vif.en),
    .count (vif.count)
  );

  test t1 (vif);             // test

endmodule
