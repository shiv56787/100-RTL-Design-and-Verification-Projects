interface sr_if(input logic clk);
  logic rst;    
  logic S;
  logic R;
  logic Q;
  logic valid;
  logic ready;
  logic [31:0] tx_id; 
endinterface

class trans;
  rand bit S;
  rand bit R;
  int id;
  bit prev_q;
  bit expected_q;
  bit actual_q;

  function new(int i = -1);
    begin
    id = i;
    end
  endfunction

  function automatic void compute();
    begin
    if (S) expected_q = 1'b1;
    else if (R) expected_q = 1'b0;
    else expected_q = prev_q;
    end
  endfunction

  function automatic string show();
    begin
    return $sformatf("id=%0d S=%b R=%b prev=%b exp=%b", id, S, R, prev_q, expected_q);
    end
  endfunction
endclass

class generator;
  mailbox #(trans) to_drv;
  int N;
  virtual sr_if vif; 
  
  function new(mailbox #(trans) m, int n, virtual sr_if v = null);
    to_drv = m;
    N = n;
    vif = v;
  endfunction

  task automatic run();
    trans t;
    if (vif != null) begin
      wait (vif.rst == 0);
      
      @(negedge vif.clk);
    end
    for (int i = 0; i < N; i++) begin
      t = new(i);
      assert(t.randomize()); 
      
      to_drv.put(t);
      $display("[%0t] GEN: %s", $time, t.show());
      #($urandom_range(1,3) * 10);
    end
    $display("[%0t] GEN DONE (%0d items)", $time, N);
  endtask
endclass

class driver;
  virtual sr_if vif;
  mailbox #(trans) gen2drv;
  mailbox #(trans) exp_mbox;
  mailbox #(trans) act_mbox;
  int sent = 0;

  function new(virtual sr_if v, mailbox #(trans) g, mailbox #(trans) e);
    vif = v;
    gen2drv = g;
    exp_mbox = e;
  endfunction

  task automatic run();
    trans t;
    wait (vif.rst == 0);
    @(negedge vif.clk);

    forever begin
      gen2drv.get(t);          
      @(negedge vif.clk);
      t.prev_q = vif.Q;
      vif.S = t.S;
      vif.R = t.R;
      vif.tx_id = t.id;
      vif.valid = 1;
      t.compute();
      exp_mbox.put(t);
      sent++;
      $display("[%0t] DRV: id=%0d S=%b R=%b prev=%b exp=%b", $time, t.id, t.S, t.R, t.prev_q, t.expected_q);
      @(posedge vif.clk);
      @(negedge vif.clk);
      vif.S = 0;
      vif.R = 0;
      vif.valid = 0;
      vif.tx_id = '0;
    end
  endtask
endclass

class monitor;
  virtual sr_if vif;
  mailbox #(trans) act_mbox;

  function new(virtual sr_if v, mailbox #(trans) a);
    vif = v;
    act_mbox = a;
  endfunction

  task automatic run();
    trans t;
    wait (vif.rst == 0);
    @(negedge vif.clk);

    forever begin
      @(posedge vif.clk);
      #1ns; 
      if (vif.valid) begin
        t = new(vif.tx_id);        
        t.actual_q = vif.Q;
        act_mbox.put(t);
        $display("[%0t] MON: observed id=%0d Q=%b", $time, t.id, t.actual_q);
      end
    end
  endtask
endclass



class scoreboard;
  mailbox #(trans) m_exp_mbox; 
  mailbox #(trans) m_act_mbox;
  int errors = 0;
  int total  = 0;
  function new(mailbox #(trans) e, mailbox #(trans) a);
    begin
    m_exp_mbox = e; 
    m_act_mbox = a; 
    end
  endfunction
  task automatic run();
    trans ex;
    trans ac;
    typedef trans trans_t;
    trans_t exp_mem[string];
    bit found;
    trans_t temp_mem[$]; 

    forever begin
      
      m_exp_mbox.get(ex); 
      exp_mem[$sformatf("%0d", ex.id)] = ex;
            found = 0; 
      temp_mem = {}; 

      while (!found) begin
        m_act_mbox.get(ac); 

        if (ac.id == ex.id) begin
          
          total++;
          if (ex.expected_q !== ac.actual_q) begin
            $display("[%0t] ERR id=%0d | %s | ACT Q=%b", $time, ex.id, ex.show(), ac.actual_q);
            errors++;
          end else begin
            $display("[%0t] OK  id=%0d matched %b", $time, ex.id, ac.actual_q);
          end
          found = 1;
          foreach (temp_mem[i]) begin
            m_act_mbox.put(temp_mem[i]);
          end
        end else begin
          temp_mem.push_back(ac);
        end
      end
    end
  endtask

  function automatic void report();
    begin
    $display("---- SCOREBOARD ----");
    $display("total   = %0d", total);
    $display("errors  = %0d", errors);
    $display("result  = %s", (errors==0) ? "PASS" : "FAIL");
    $display("---------------------");
    end
  endfunction
endclass
module tb;
  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;

  sr_if sif(clk);

  sr_ff dut (
    .clk (clk),
    .rst (sif.rst),
    .S   (sif.S),
    .R   (sif.R),
    .Q   (sif.Q)
  );

  initial begin
    
    sif.rst = 1;
    sif.S = 0;
    sif.R = 0;
    sif.valid = 0;
    sif.ready = 0;
    sif.tx_id = 0;
    #20;
    sif.rst = 0; 
    #10;
  end

 
  mailbox #(trans) gen2drv = new();
  mailbox #(trans) exp_mbox  = new();
  mailbox #(trans) act_mbox  = new();

  generator gen = new(gen2drv, 10, sif); 
  driver drv = new(sif, gen2drv, exp_mbox);
  monitor mon = new(sif, act_mbox);
  scoreboard sb = new(exp_mbox, act_mbox); 

  initial begin
    $dumpfile("sr_ff_fixed.vcd");
    $dumpvars(0, tb);
  end

  initial begin
    fork
      gen.run();
      drv.run();
      mon.run();
      sb.run();
    join_none
    wait (drv.sent == 10); 
    #100;
    sb.report();
    $finish;
  end
endmodule

// design 
module sr_ff (
  input  logic clk,
  input  logic rst,   
  input  logic S,
  input  logic R,
  output logic Q
);
  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      Q <= 1'b0;
    else begin
      case ({S, R})
        2'b10: Q <= 1'b1; 
        2'b01: Q <= 1'b0; 
        2'b00: Q <= Q;    
        2'b11: Q <= 1'b1; 
        default: Q <= Q;
      endcase
    end
  end
endmodule
