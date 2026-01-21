interface fa_if(input logic clk);
  logic [3:0] a,b;
  logic cin;
  logic valid;
  logic ready;
  logic [3:0] sum;
  logic cout;
endinterface


class trans;
  rand bit [3:0] a,b;
  rand bit cin;
  int id;
  bit [4:0] expected;
  bit [4:0] actual;

  function new(int i);
    id = i;
  endfunction

  function void compute();
    bit [4:0] tmp;
    tmp = a + b + cin;
    expected = tmp;
  endfunction

  function string show();
    return $sformatf("id=%0d a=%0h b=%0h cin=%0b exp=%0h",id,a,b,cin,expected);
  endfunction
endclass

class generator;
  mailbox #(trans) to_drv;
  int N;

  function new(mailbox #(trans) m, int n);
    to_drv = m;
    N = n;
  endfunction

  task run();
    trans t;
    for(int i=0;i<N;i++) begin
      t = new(i);
      assert(t.randomize());
      t.compute();
      to_drv.put(t);
      $display("[%0t] GEN: %s", $time, t.show());
      #($urandom_range(1,3)*10);
    end
    $display("[%0t] GEN DONE (%0d items)", $time, N);
  endtask
endclass



class driver;
  virtual fa_if vif;
  mailbox #(trans) gen2drv;
  mailbox #(trans) exp_mbox;
  int sent = 0;

  function new(virtual fa_if v, mailbox #(trans) g, mailbox #(trans) e);
    vif = v;
    gen2drv = g;
    exp_mbox = e;
  endfunction

  task run();
    trans t;
    forever begin
      gen2drv.get(t);

      @(negedge vif.clk);
      vif.a = t.a;
      vif.b = t.b;
      vif.cin = t.cin;
      vif.valid = 1;
      exp_mbox.put(t);
      sent++;

      @(posedge vif.clk);
      @(negedge vif.clk);
      vif.valid = 0;
    end
  endtask
endclass



class monitor;
  virtual fa_if vif;
  mailbox #(trans) act_mbox;

  function new(virtual fa_if v, mailbox #(trans) a);
    vif = v;
    act_mbox = a;
  endfunction

  task run();
    trans t;
    forever begin
      @(posedge vif.clk);
      if(vif.valid) begin
        t = new(-1);
        t.a = vif.a;
        t.b = vif.b;
        t.cin = vif.cin;
        t.actual = {vif.cout, vif.sum};
        act_mbox.put(t);
      end
    end
  endtask
endclass



class scoreboard;
  mailbox #(trans) exp_mbox;
  mailbox #(trans) act_mbox;

  int errors = 0;
  int total = 0;

  function new(mailbox #(trans) e, mailbox #(trans) a);
    exp_mbox = e;
    act_mbox = a;
  endfunction

  task run();
    trans ex,ac;
    forever begin
      exp_mbox.get(ex);
      act_mbox.get(ac);
      total++;

      if(ex.expected !== ac.actual) begin
        $display("ERR id=%0d exp=%0h act=%0h", ex.id, ex.expected, ac.actual);
        errors++;
      end else begin
        $display("OK id=%0d matched %0h", ex.id, ex.expected);
      end
    end
  endtask

  function void report();
    $display("---- SCOREBOARD ----");
    $display("total   = %0d", total);
    $display("errors  = %0d", errors);
    $display("result  = %s", (errors==0)?"PASS":"FAIL");
    $display("---------------------");
  endfunction
endclass


module tb;

  logic clk;
  initial clk=0;
  always #5 clk = ~clk;

  fa_if ff(clk);

  full_adder dut(
    .a(ff.a), .b(ff.b), .cin(ff.cin),
    .sum(ff.sum), .cout(ff.cout)
  );

  initial begin
    ff.a=0;
    ff.b=0;
    ff.cin=0;
    ff.valid=0;
    ff.ready=0;
  end

  mailbox #(trans) gen2drv = new();
  mailbox #(trans) exp_mbox = new();
  mailbox #(trans) act_mbox = new();

  generator gen = new(gen2drv, 30);
  driver drv = new(ff, gen2drv, exp_mbox);
  monitor mon = new(ff, act_mbox);
  scoreboard sb = new(exp_mbox, act_mbox);

  initial begin
    $dumpfile("fa.vcd");
    $dumpvars(0,tb);
  end

  initial begin
    fork
      gen.run();
      drv.run();
      mon.run();
      sb.run();
    join_none

    wait(drv.sent == 30);
    #20;
    sb.report();
    $finish;
  end

endmodule
