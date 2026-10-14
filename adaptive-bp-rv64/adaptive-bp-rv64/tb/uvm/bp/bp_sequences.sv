// -----------------------------------------------------------------------------
// Sequences: directed scenarios + constrained-random program model
//   Every sequence produces a *coherent* correct-path stream: item[n+1].pc equals the
//   actual next-PC of item[n]. The driver turns that stream into fetch/resolve traffic
//   (including wrong-path fetches after a misprediction).
// -----------------------------------------------------------------------------
class bp_base_seq extends uvm_sequence #(bp_item);
  `uvm_object_utils(bp_base_seq)
  bit [63:0] cur_pc;
  bp_cfg     cfg;

  function new(string name = "bp_base_seq");
    super.new(name);
  endfunction

  task pre_start();
    if (!uvm_config_db#(bp_cfg)::get(m_sequencer, "", "cfg", cfg)) cfg = bp_cfg::type_id::create("cfg");
    cur_pc = cfg.code_base;
  endtask

  protected task emit(bp_kind_e k, bit taken, bit [63:0] tgt);
    bp_item it = bp_item::type_id::create("it");
    start_item(it);
    it.pc = cur_pc; it.kind = k; it.taken = taken; it.target = tgt;
    finish_item(it);
    cur_pc = taken ? tgt : cur_pc + 4;
  endtask

  protected task do_none();                          emit(K_NONE, 0, 0);      endtask
  protected task do_cond(bit taken, bit [63:0] t);   emit(K_COND, taken, t);  endtask
  protected task do_jal(bit [63:0] t);               emit(K_JAL, 1, t);       endtask
  protected task do_call(bit [63:0] t);              emit(K_CALL, 1, t);      endtask
  protected task do_ret(bit [63:0] t);               emit(K_RET, 1, t);       endtask
  protected task do_jalr(bit [63:0] t);              emit(K_JALR, 1, t);      endtask
  protected task do_icall(bit [63:0] t);             emit(K_ICALL, 1, t);     endtask
endclass

// ---- directed: counted loop (taken N-1 times, then exits) ------------------------------
class bp_loop_seq extends bp_base_seq;
  `uvm_object_utils(bp_loop_seq)
  rand int unsigned trip = 8;
  rand int unsigned reps = 20;
  constraint c_trip { trip inside {[2:40]}; reps inside {[5:40]}; }
  function new(string name = "bp_loop_seq"); super.new(name); endfunction
  task body();
    bit [63:0] top = cfg.code_base;
    repeat (reps) begin
      for (int i = 0; i < trip; i++) begin
        cur_pc = top;
        do_none(); do_none();
        do_cond(i < trip - 1, top);                 // backward loop branch @ top+8
      end
      do_none();                                     // top+12
      do_jal(top);
    end
  endtask
endclass

// ---- directed: periodic outcome pattern (needs global history) -------------------------
class bp_pattern_seq extends bp_base_seq;
  `uvm_object_utils(bp_pattern_seq)
  rand bit [15:0]   pattern;
  rand int unsigned plen = 4;
  rand int unsigned iters = 300;
  constraint c_len { plen inside {[2:12]}; iters inside {[100:400]}; }
  constraint c_nontrivial { (pattern & ((1 << plen) - 1)) != 0; (pattern & ((1 << plen) - 1)) != ((1 << plen) - 1); }
  function new(string name = "bp_pattern_seq"); super.new(name); endfunction
  task body();
    bit [63:0] top = cfg.code_base + 64'h200;
    for (int i = 0; i < iters; i++) begin
      cur_pc = top;
      do_none();
      do_cond(pattern[i % plen], top + 16);          // forward branch @ top+4
      while (cur_pc < top + 16) do_none();
      do_jal(top);
    end
  endtask
endclass

// ---- directed: call/return nesting deeper than the RAS ------------------------------------
class bp_callret_seq extends bp_base_seq;
  `uvm_object_utils(bp_callret_seq)
  rand int unsigned depth = 6;
  rand int unsigned reps  = 6;
  constraint c_depth { depth inside {[1:14]}; reps inside {[3:10]}; }
  function new(string name = "bp_callret_seq"); super.new(name); endfunction

  protected task nest(int unsigned d, bit [63:0] ret_to, bit [63:0] func);
    do_none();                                        // func
    if (d > 1) begin
      bit [63:0] rp = cur_pc + 4;
      do_call(func);                                  // func+4  (recursive call site)
      nest(d - 1, rp, func);
    end
    do_ret(ret_to);                                   // func+8
  endtask

  task body();
    bit [63:0] main_pc = cfg.code_base + 64'h400;
    bit [63:0] func    = cfg.code_base + 64'h500;
    repeat (reps) begin
      cur_pc = main_pc;
      do_none();
      begin
        bit [63:0] rp = cur_pc + 4;
        do_call(func);                                // main+4
        nest(depth, rp, func);
      end
      do_none();
      do_jal(main_pc);
    end
  endtask
endclass

// ---- directed: two taken branches that alias in the BTB ---------------------------------------
class bp_alias_seq extends bp_base_seq;
  `uvm_object_utils(bp_alias_seq)
  rand int unsigned iters = 200;
  constraint c_it { iters inside {[50:300]}; }
  function new(string name = "bp_alias_seq"); super.new(name); endfunction
  task body();
    bit [63:0] a = cfg.code_base + 64'h100;
    bit [63:0] stride = 64'd4 << cfg.btb_w;           // same BTB index, different tag
    bit [63:0] b = a + stride;
    repeat (iters) begin
      cur_pc = a;  do_jal(b);
      do_cond(1'b1, a);                               // @ b : always taken
    end
  endtask
endclass

// ---- constrained-random synthetic program --------------------------------------------------
typedef enum {M_BIASED, M_PERIODIC, M_LOOP, M_RANDOM} bp_mode_e;

class bp_site;                                        // static properties of one PC
  rand bp_kind_e   kind;
  rand bp_mode_e   mode;
  rand int unsigned bias_pct;
  rand bit [15:0]  pattern;
  rand int unsigned plen;
  rand int unsigned trip;
  rand bit [63:0]  target;
  rand bit [63:0]  itargets[4];
  int unsigned     cnt = 0;

  bit [63:0] base;
  int unsigned words;
  int unsigned w_none = 55, w_cond = 28, w_jal = 5, w_call = 5, w_ret = 5, w_jalr = 2;

  constraint c_kind {
    kind dist { K_NONE := w_none, K_COND := w_cond, K_JAL := w_jal, K_CALL := w_call,
                K_RET := w_ret, K_JALR := w_jalr };
  }
  constraint c_mode  { mode dist { M_BIASED := 40, M_PERIODIC := 30, M_LOOP := 20, M_RANDOM := 10 }; }
  constraint c_bias  { bias_pct inside {[0:100]}; bias_pct dist { [0:10] :/ 25, [90:100] :/ 40, [11:89] :/ 35 }; }
  constraint c_plen  { plen inside {[2:10]}; }
  constraint c_trip  { trip inside {[2:24]}; }
  constraint c_tgt   { target >= base; target < base + words * 4; target[1:0] == 0; }
  constraint c_itgt  { foreach (itargets[i]) { itargets[i] >= base; itargets[i] < base + words * 4; itargets[i][1:0] == 0; } }

  function new(bit [63:0] base, int unsigned words);
    this.base = base; this.words = words;
  endfunction

  function bit outcome();
    bit t;
    case (mode)
      M_BIASED:   t = ($urandom_range(99) < bias_pct);
      M_PERIODIC: t = pattern[cnt % plen];
      M_LOOP:     t = ((cnt % trip) != trip - 1);
      default:    t = $urandom_range(1);
    endcase
    cnt++;
    return t;
  endfunction
endclass

class bp_random_seq extends bp_base_seq;
  `uvm_object_utils(bp_random_seq)
  rand int unsigned n_items = 3000;
  int unsigned      mix_cond_pct = 28;            // knob: branch density
  bp_site           sites[bit [63:0]];
  bit [63:0]        ret_stack[$];

  constraint c_n { soft n_items inside {[1000:6000]}; }
  function new(string name = "bp_random_seq"); super.new(name); endfunction

  protected function bp_site site_at(bit [63:0] pc);
    if (!sites.exists(pc)) begin
      bp_site s = new(cfg.code_base, cfg.code_words);
      s.w_cond = mix_cond_pct;
      if (!s.randomize()) `uvm_fatal("SEQ", "site randomization failed")
      sites[pc] = s;
    end
    return sites[pc];
  endfunction

  task body();
    bit [63:0] end_pc = cfg.code_base + cfg.code_words * 4;
    cur_pc = cfg.code_base;
    for (int i = 0; i < n_items; i++) begin
      bp_site s = site_at(cur_pc);
      bit [63:0] fall = (cur_pc + 4 >= end_pc) ? cfg.code_base : cur_pc + 4;
      case (s.kind)
        K_NONE: begin
          // wrap at the end of the code region with an unconditional jump
          if (cur_pc + 4 >= end_pc) do_jal(cfg.code_base); else do_none();
        end
        K_COND: begin
          bit t = s.outcome();
          if (!t && cur_pc + 4 >= end_pc) t = 1;      // keep the PC inside the region
          if (t) do_cond(1, s.target); else do_cond(0, s.target);
        end
        K_JAL:  do_jal(s.target);
        K_CALL: begin ret_stack.push_back(fall); do_call(s.target); end
        K_RET: begin
          if (ret_stack.size() > 0) do_ret(ret_stack.pop_back());
          else                      do_ret(s.target);           // "wild" return, RAS cannot know
        end
        K_JALR: begin
          if ($urandom_range(3) == 0) begin ret_stack.push_back(fall); do_icall(s.itargets[$urandom_range(3)]); end
          else                         do_jalr(s.itargets[$urandom_range(3)]);
        end
        default: do_none();
      endcase
      if (ret_stack.size() > 32) void'(ret_stack.pop_front());
    end
  endtask
endclass

// ---- everything back-to-back (used by the regression test) ------------------------------------
class bp_directed_all_seq extends bp_base_seq;
  `uvm_object_utils(bp_directed_all_seq)
  function new(string name = "bp_directed_all_seq"); super.new(name); endfunction
  task body();
    bp_loop_seq    l = bp_loop_seq::type_id::create("l");
    bp_pattern_seq p = bp_pattern_seq::type_id::create("p");
    bp_callret_seq c = bp_callret_seq::type_id::create("c");
    bp_alias_seq   a = bp_alias_seq::type_id::create("a");
    if (!l.randomize()) `uvm_fatal("SEQ", "randomize") l.start(m_sequencer);
    if (!p.randomize()) `uvm_fatal("SEQ", "randomize") p.start(m_sequencer);
    if (!c.randomize()) `uvm_fatal("SEQ", "randomize") c.start(m_sequencer);
    if (!a.randomize()) `uvm_fatal("SEQ", "randomize") a.start(m_sequencer);
  endtask
endclass
